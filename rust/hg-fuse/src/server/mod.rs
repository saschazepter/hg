use std::convert::Infallible;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use std::time::SystemTime;

use dashmap::DashMap;
use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;
use hg::Node;
use hg::errors::HgError;
use hg::errors::IoResultExt;
use hg::revlog::manifest::ManifestFlags;
use hg::utils::RawData;
use hg::warnings::HgWarningContext;

use crate::fuse::COMMITS_INODE;
use crate::fuse::Entry;
use crate::fuse::RootInodeEncoder;
use crate::fuse::path_to_revision_working_copy;
use crate::server::revision::OwnedRevision;
use crate::server::store::BackendMode;
use crate::server::store::Error as StoreError;
use crate::server::store::FileToken;
use crate::server::store::StoreBackend;

pub mod local;
pub mod revision;
pub mod store;

const BLOCK_SIZE: u32 = 4096;
// Fake size that's obvious enough to be grepped in case that's
// a problem.
const FAKE_DIR_SIZE: u64 = 2005;
const MERCURIAL_FIRST_COMMIT_TIMESTAMP: Duration =
    Duration::from_secs(1115154970);

/// Configuration options for the FUSE
#[derive(Debug)]
pub struct Config {
    /// Whether to preload the directory structure by traversing the filesystem
    /// at the mountpoint (useful for debugging outside of the context of an
    /// overlay, which would change the mountpoint).
    preload_structure: bool,
    /// What sort of working copy the VFS should present
    backend_mode: BackendMode,
}

/// Responsible for serving contents from the store to the FUSE layer
pub struct Server<S, T> {
    /// The repo that we're serving for
    /// TODO more than 1 repo at once
    store: S,
    /// Revisions whose tree we've populated
    revisions: DashMap<Node, Arc<OwnedRevision<T>>>,
    /// When this server was started
    start_time: SystemTime,
    /// User ID returned on requests, by default it's the process'.
    uid: u32,
    /// Group ID returned on requests, by default it's the process'.
    gid: u32,
}

impl<S: StoreBackend<T>, T: FileToken> Server<S, T> {
    pub fn new(
        store: S,
        user_id: Option<u32>,
        group_id: Option<u32>,
    ) -> Result<Self, HgError> {
        let process_metadata =
            std::fs::metadata("/proc/self").when_reading_file("/proc/self")?;
        let uid = user_id.unwrap_or_else(|| process_metadata.uid());
        let gid = group_id.unwrap_or_else(|| process_metadata.gid());

        let warnings = HgWarningContext::new();
        let _ = warnings.finish(|warning| -> Result<(), Infallible> {
            // TODO better warnings
            tracing::warn!("narrow warning: {:?}", warning);
            Ok(())
        });

        Ok(Self {
            store,
            revisions: DashMap::default(),
            // Use a constant time, so that restarts don't affect the dirstate.
            start_time: SystemTime::UNIX_EPOCH
                + MERCURIAL_FIRST_COMMIT_TIMESTAMP,
            uid,
            gid,
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
    ) -> Result<Option<Entry>, StoreError<T>> {
        if RootInodeEncoder::is_reserved(parent) {
            if parent == COMMITS_INODE {
                if let Ok(node) = Node::from_hex(name.as_encoded_bytes()) {
                    // Is a syntactically valid node, try to look it up
                    if let Some(revision) = self.revisions.get(&node) {
                        // We've already loaded this revision
                        let root_inode = RootInodeEncoder::revision_inode(
                            self.store.idx_for_node(node)?,
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
    ) -> Result<Option<Entry>, StoreError<T>> {
        let revision_data = OwnedRevision::from_revision(
            &self.store,
            changeset,
            self.start_time,
        )?;
        let revision_arc = Arc::new(revision_data);
        self.revisions.insert(changeset, Arc::clone(&revision_arc));
        tracing::debug!("total revisions loaded: {}", self.revisions.len());

        let preload = self.store.server_config().preload_structure;
        if preload {
            self.spawn_revision_preloading(
                changeset,
                revision_arc,
                mount_point,
            );
        }
        let entry = Entry::dir(
            format!("{:x}", changeset).into(),
            RootInodeEncoder::revision_inode(
                self.store.idx_for_node(changeset)?,
            ),
        );
        Ok(Some(entry))
    }

    /// Spawn a background thread that populates the filesystem kernel caches
    fn spawn_revision_preloading(
        &self,
        changeset: Node,
        revision: Arc<OwnedRevision<T>>,
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
            self.with_revision(ino, |revision| revision.read(ino, &self.store))
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
        func: impl FnOnce(&OwnedRevision<T>) -> R,
    ) -> Option<R> {
        let idx = RootInodeEncoder::ino_to_idx(ino)?;
        let node = self.store.node_for_idx(idx).ok()?;
        let revision = self.revisions.get(&node)?;
        Some(func(&revision))
    }
}

fn permissions_for_file(flags: ManifestFlags) -> u16 {
    if flags.is_exec() {
        0o700
    } else if flags.is_link() {
        // According to https://man7.org/linux/man-pages/man7/symlink.7.html,
        // symlinks should always have 0777 permissions.
        0o120777
    } else {
        0o600
    }
}
