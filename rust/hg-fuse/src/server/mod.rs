use std::convert::Infallible;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Arc;
use std::time::SystemTime;

use dashmap::DashMap;
use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;
use hg::Node;
use hg::errors::HgError;
use hg::errors::IoResultExt;
use hg::matchers::Matcher;
use hg::narrow;
use hg::repo::Repo;
use hg::revlog::manifest::ManifestFlags;
use hg::utils::RawData;
use hg::warnings::HgWarningContext;

use crate::fuse::COMMITS_INODE;
use crate::fuse::Entry;
use crate::fuse::RootInodeEncoder;
use crate::fuse::path_to_revision_working_copy;
use crate::server::revision::ManifestRevisionDetails;
use crate::server::revision::OwnedRevision;

pub mod revision;

const BLOCK_SIZE: u32 = 4096;
// Fake size that's obvious enough to be grepped in case that's
// a problem.
const FAKE_DIR_SIZE: u64 = 2005;

/// Responsible for serving contents from the store to the FUSE layer
pub struct Server {
    /// The repo that we're serving for
    /// TODO more than 1 repo at once
    repo: Repo,
    /// Cache of the size of the uncompressed contents (without metadata) of
    /// each filenode id.
    /// TODO try to pass in a hasher that just uses the nodeid?
    file_nodeid_to_size: DashMap<Node, usize>,
    /// Maps assigned revision inodes to the manifest node they're in.
    ino_to_nodeid: DashMap<INodeNo, Node>,
    /// Revisions whose tree we've populated
    revisions: DashMap<Node, Arc<OwnedRevision>>,
    /// When this server was started
    start_time: SystemTime,
    /// User ID returned on requests, by default it's the process'.
    uid: u32,
    /// Group ID returned on requests, by default it's the process'.
    gid: u32,
    /// The matcher for this repo's narrowspec
    narrow_matcher: Box<dyn Matcher + Send + 'static>,
}

impl Server {
    pub fn new(repo: &Repo, user_id: Option<u32>) -> Result<Self, HgError> {
        // Recreate our owned repo
        let repo = Repo::find(
            repo.config(),
            Some(repo.working_directory_path().to_path_buf()),
        )?;
        let process_metadata =
            std::fs::metadata("/proc/self").when_reading_file("/proc/self")?;
        let uid = user_id.unwrap_or_else(|| process_metadata.uid());
        let gid = user_id.unwrap_or_else(|| process_metadata.gid());

        let warnings = HgWarningContext::new();
        let narrow_matcher = narrow::matcher(&repo, warnings.sender())?;
        let _ = warnings.finish(|warning| -> Result<(), Infallible> {
            // TODO better warnings
            tracing::warn!("narrow warning: {:?}", warning);
            Ok(())
        });

        Ok(Self {
            repo,
            file_nodeid_to_size: DashMap::default(),
            ino_to_nodeid: DashMap::default(),
            revisions: DashMap::default(),
            start_time: SystemTime::now(),
            uid,
            gid,
            narrow_matcher,
        })
    }

    pub fn attributes(&self, ino: INodeNo) -> Option<fuser::FileAttr> {
        let entry = self.get_entry(ino)?;
        Some(self.attributes_for_entry(entry))
    }

    pub fn attributes_for_entry(&self, entry: Entry) -> fuser::FileAttr {
        match entry {
            Entry::Dir { ino, name: _ } => self.attributes_for_directory(ino),
            Entry::File { name: _, ino, size, flags } => {
                self.attributes_for_file(ino, size, flags)
            }
        }
    }

    fn attributes_for_file(
        &self,
        ino: INodeNo,
        size: u64,
        flags: ManifestFlags,
    ) -> FileAttr {
        FileAttr {
            ino,
            size,
            blocks: size.div_ceil(u64::from(BLOCK_SIZE)),
            atime: self.start_time,
            mtime: self.start_time,
            ctime: self.start_time,
            crtime: self.start_time,
            kind: if flags.is_link() {
                FileType::Symlink
            } else {
                FileType::RegularFile
            },
            perm: permissions_for_file(flags),
            nlink: 1,
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            flags: 0,
            blksize: BLOCK_SIZE,
        }
    }

    fn attributes_for_directory(&self, ino: INodeNo) -> FileAttr {
        FileAttr {
            ino,
            size: FAKE_DIR_SIZE,
            blocks: 0,
            atime: self.start_time,
            mtime: self.start_time,
            ctime: self.start_time,
            crtime: self.start_time,
            kind: FileType::Directory,
            perm: 0o700,
            nlink: 1,
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            flags: 0,
            blksize: BLOCK_SIZE,
        }
    }

    /// Return the [`Entry`] that corresponds to `ino`
    pub fn get_entry(&self, ino: fuser::INodeNo) -> Option<Entry> {
        if RootInodeEncoder::is_reserved(ino) {
            return RootInodeEncoder::entry_for_reserved(ino);
        }
        self.with_revision(ino, |revision| revision.get_entry(ino))?
    }

    /// Return the child of `parent` matching this `name`, if any.
    pub fn lookup(
        &self,
        parent: INodeNo,
        name: &std::ffi::OsStr,
        mount_point: &Path,
    ) -> Result<Option<Entry>, HgError> {
        if RootInodeEncoder::is_reserved(parent) {
            if parent == COMMITS_INODE {
                if let Ok(node) = Node::from_hex(name.as_encoded_bytes()) {
                    // Is a syntactically valid node, try to look it up
                    if let Some(revision) = self.revisions.get(&node) {
                        // We've already loaded this revision
                        let root_inode = RootInodeEncoder::revision_inode(
                            revision.changelog_rev(),
                        );
                        let root_entry_opt = revision.get_entry(root_inode);
                        return Ok(root_entry_opt);
                    }
                    // Load the node upon first request
                    return self.load_revision_root(node, mount_point);
                } else {
                    return Ok(None);
                };
            } else {
                return Ok(RootInodeEncoder::lookup_reserved(parent, name));
            }
        }
        let maybe_entry_result = self
            .with_revision(parent, |revision| revision.lookup(parent, name));
        match maybe_entry_result {
            Some(entry) => Ok(entry),
            None => Ok(None),
        }
    }

    /// Return the [`Entry`] for the root of the given node prefix.
    ///
    /// This means building the [`RevisionTree`] and caching it.
    #[tracing::instrument(
        level = "debug",
        skip_all,
        fields(nodeid = format!("{:x}", changeset)),
    )]
    fn load_revision_root(
        &self,
        changeset: Node,
        mount_point: &Path,
    ) -> Result<Option<Entry>, HgError> {
        // Look up the manifest node for this changelog node
        // TODO improve the granularity of this locking
        let changelog = self.repo.changelog()?;
        let changeset_rev = changelog.rev_from_node(changeset.into())?;
        let data = changelog.data_for_node(changeset.into())?;
        let manifest_node = data.manifest_node()?;
        let manifestlog = self.repo.manifestlog()?;
        let changeset_extras =
            changelog.data_for_node(changeset.into())?.extra()?;
        let branch = match changeset_extras.get("branch") {
            Some(branch) => branch.to_vec(),
            None => b"default".to_vec(),
        };

        let manifest = manifestlog.data_for_node(manifest_node.into())?;

        let (revision_data, new_ino_to_nodeid) = OwnedRevision::from_revision(
            &self.repo,
            &self.file_nodeid_to_size,
            manifest,
            ManifestRevisionDetails::new(changeset, changeset_rev, branch),
            self.start_time,
            &self.narrow_matcher,
        )?;
        let revision_arc = Arc::new(revision_data);
        self.revisions.insert(changeset, Arc::clone(&revision_arc));

        // Update the higher-level mapping now that the revision is fully built
        // and stored
        // Note that this implies that `new_ino_to_nodeid` is sorted in a way
        // that the root directory is at the end, otherwise we might race and
        // expose the root's children before they are inserted here.
        for ino in new_ino_to_nodeid {
            self.ino_to_nodeid.insert(ino, changeset);
        }

        let preload = self
            .repo
            .config()
            .get_bool(b"fuse", b"preload-working-copy-structure")?;
        if preload {
            self.spawn_revision_preloading(
                changeset,
                revision_arc,
                mount_point,
            );
        }
        let entry = Entry::dir(
            format!("{:x}", changeset).into(),
            RootInodeEncoder::revision_inode(changeset_rev),
        );
        Ok(Some(entry))
    }

    /// Spawn a background thread that populates the filesystem kernel caches
    fn spawn_revision_preloading(
        &self,
        changeset: Node,
        revision: Arc<OwnedRevision>,
        mount_point: &Path,
    ) {
        let root = mount_point.join(path_to_revision_working_copy(changeset));
        rayon::spawn(move || revision.preload(&root));
    }

    /// Return entries for all direct children of this inode
    pub fn entries(&self, ino: INodeNo) -> Option<Vec<Entry>> {
        if RootInodeEncoder::is_reserved(ino) {
            return RootInodeEncoder::entries_for_reserved(ino);
        }
        self.with_revision(ino, |revision| -> Option<Vec<Entry>> {
            revision.entries(ino)
        })?
    }

    /// Return the contents of the file at this inoode, if it exists.
    pub fn read(&self, ino: INodeNo) -> Result<Option<RawData>, HgError> {
        if RootInodeEncoder::is_reserved(ino) {
            return Ok(RootInodeEncoder::data_for_reserved(ino));
        }
        if let Some(Ok(Some(data))) =
            self.with_revision(ino, |revision| revision.read(ino, &self.repo))
        {
            Ok(Some(data))
        } else {
            Ok(None)
        }
    }

    /// Enables callback-based access to the revision tree for this inode.
    fn with_revision<R>(
        &self,
        ino: INodeNo,
        func: impl FnOnce(&OwnedRevision) -> R,
    ) -> Option<R> {
        let revision_nodeid = self.ino_to_nodeid.get(&ino)?;
        let revision = self.revisions.get(&revision_nodeid)?;
        Some(func(&revision))
    }
}

fn permissions_for_file(flags: ManifestFlags) -> u16 {
    if flags.is_exec() { 0o700 } else { 0o600 }
}
