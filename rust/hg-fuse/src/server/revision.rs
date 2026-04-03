use std::convert::Infallible;
use std::ffi::OsStr;
use std::ffi::OsString;
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;
use std::sync::atomic::Ordering;
use std::time::SystemTime;

use dashmap::DashMap;
use fuser::INodeNo;
use hg::DirstateParents;
use hg::FastHashMap;
use hg::NULL_NODE;
use hg::Node;
use hg::Revision;
use hg::dirstate::dirstate_map::DirstateEntryReset;
use hg::dirstate::dirstate_map::DirstateMapWriteMode;
use hg::dirstate::dirstate_map::FuseNodeInfo;
use hg::dirstate::entry::ParentFileData;
use hg::dirstate::entry::TruncatedTimestamp;
use hg::dirstate::on_disk::Docket;
use hg::dirstate::on_disk::WriteNodeVisit;
use hg::dirstate::on_disk::write_tracked_key_to;
use hg::dirstate::owning::OwningDirstateMap;
use hg::errors::HgError;
use hg::matchers::Matcher;
use hg::narrow;
use hg::operations::FilesForDirstateBorrowed;
use hg::repo::Repo;
use hg::requirements::DIRSTATE_TRACKED_HINT_V1;
use hg::requirements::DIRSTATE_V2_REQUIREMENT;
use hg::requirements::SHARED_REQUIREMENT;
use hg::requirements::SHARESAFE_REQUIREMENT;
use hg::requirements::SPARSE_REQUIREMENT;
use hg::revlog::manifest::Manifest;
use hg::revlog::manifest::ManifestFlags;
use hg::sparse;
use hg::utils::RawData;
use hg::utils::files::get_bytes_from_path;
use hg::utils::hg_path::HgPath;
use hg::utils::hg_path::hg_path_to_path_buf;
use hg::utils::u_u32;
use hg::utils::u_u64;
use hg::utils::u64_u;
use hg::warnings::HgWarningContext;
use rayon::iter::ParallelBridge;
use rayon::iter::ParallelIterator;

use crate::fuse::Entry;
use crate::fuse::FILES_INODE_NAME;
use crate::fuse::RootInodeEncoder;
use crate::server::permissions_for_file;

/// Stores information about a given changelog revision
pub(super) struct ManifestRevisionDetails {
    /// Its changeset nodeid
    changeset_node: Node,
    /// Its changeset revision number
    changeset_rev: Revision,
    /// The branch its changeset is on
    branch: Vec<u8>,
}

impl ManifestRevisionDetails {
    pub fn new(
        changeset_node: Node,
        changeset_rev: Revision,
        branch: Vec<u8>,
    ) -> Self {
        Self { changeset_node, changeset_rev, branch }
    }
}

/// Represents a manifest revision
pub(super) struct OwnedRevision {
    revision: RevisionTree,
    changelog_rev: Revision,
}

impl OwnedRevision {
    /// Return a [`Self`] that represents this manifest, along with the new
    /// inodes.
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn from_revision(
        repo: &Repo,
        file_nodeid_to_size: &DashMap<Node, usize>,
        manifest: Manifest,
        manifest_details: ManifestRevisionDetails,
        start_time: SystemTime,
        narrow_matcher: &impl Matcher,
    ) -> Result<Self, HgError> {
        let changelog_rev = manifest_details.changeset_rev;
        let revision = RevisionTree::from_revision(
            repo,
            file_nodeid_to_size,
            &manifest,
            manifest_details,
            start_time,
            narrow_matcher,
        )?;
        Ok(Self { revision, changelog_rev })
    }

    /// Preload this revision's filesystem structure into the kernel's caches.
    /// `root` must be the path to the revisions' working copy for this to work,
    /// *not* the root of the FUSE (it is different as of this writing).
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn preload(&self, root: &Path) {
        // TODO figure out if manually doing relative `openat`/`fstatat` calls
        // is worth the trouble, given that we should just be using an in-memory
        // dirstate soon.
        let inner = &self.revision;
        // The iterator starts from the root nodes, which is what we want
        inner.dirstate.debug_iter(true).par_bridge().for_each(|entry| {
            let Ok((path, (type_byte, _, _, _))) = entry else {
                return;
            };
            let Ok(path) = hg_path_to_path_buf(path) else {
                return;
            };
            if type_byte == b' ' {
                Self::preload_directory(root.join(path));
            } else {
                _ = std::fs::symlink_metadata(root.join(path));
            }
        });
    }

    /// Preload this directory into kernel filesystem cache
    fn preload_directory(path: PathBuf) {
        // Using `fadvise` works to some extent, but not as well as a full
        // readdir, so we do that instead.
        let dir_fd = match std::fs::read_dir(&path) {
            Ok(read_dir) => read_dir,
            Err(e) => {
                tracing::trace!(
                    "failed to opendir '{}' for preloading: {e}",
                    path.display()
                );
                return;
            }
        };

        // make sure we read all entries
        dir_fd.count();
    }

    pub fn get_entry(&self, ino: INodeNo) -> Option<Entry> {
        let revision = &self.revision;
        if let Some(reserved) = revision.reserved.get(&ino) {
            return Some(reserved.entry.clone());
        }
        let info = self.revision.dirstate.get_map().fuse_node_info(
            RevisionInodeEncoder::ino_to_offset(revision.files_root_ino, ino),
        )?;

        Some(self.entry_for_dirstate_node(info))
    }

    /// Return the child entry matching `name` for inode `parent`, if both exist
    pub fn lookup(&self, parent: INodeNo, name: &OsStr) -> Option<Entry> {
        let revision = &self.revision;
        if let Some(reserved) = revision.reserved.get(&parent) {
            return reserved.children.iter().find_map(|ino| {
                let entry = self.get_entry(*ino)?;
                if entry.name() == name {
                    Some(entry.clone())
                } else {
                    None
                }
            });
        }

        let info = self.revision.dirstate.get_map().fuse_lookup(
            RevisionInodeEncoder::ino_to_offset(
                revision.files_root_ino,
                parent,
            ),
            name.as_bytes(),
        )?;
        Some(self.entry_for_dirstate_node(info))
    }

    /// Return direct children entries for `ino`
    pub fn entries(&self, ino: INodeNo) -> Option<Vec<Entry>> {
        let revision = &self.revision;
        if let Some(reserved) = revision.reserved.get(&ino) {
            return match reserved.entry {
                Entry::Dir { .. } => {
                    let children = reserved
                        .children
                        .iter()
                        .filter_map(|ino| {
                            let entry = self.get_entry(*ino)?;
                            Some(entry.clone())
                        })
                        .collect();
                    Some(children)
                }
                Entry::File { .. } => None,
            };
        }

        let dmap = revision.dirstate.get_map();
        let children = dmap.fuse_children_entries(
            RevisionInodeEncoder::ino_to_offset(revision.files_root_ino, ino),
        )?;
        let entries = children
            .into_iter()
            .map(|info| self.entry_for_dirstate_node(info))
            .collect();
        Some(entries)
    }

    pub fn read(
        &self,
        ino: INodeNo,
        repo: &Repo,
    ) -> Result<Option<RawData>, HgError> {
        let revision = &self.revision;
        if let Some(reserved) = revision.reserved.get(&ino) {
            return match &reserved.entry {
                Entry::Dir { .. } => Ok(None),
                Entry::File { ino, .. } => {
                    Ok(Some(revision.reserved_contents[ino].clone()))
                }
            };
        }

        let Some(info) = self.revision.dirstate.get_map().fuse_node_info(
            RevisionInodeEncoder::ino_to_offset(revision.files_root_ino, ino),
        ) else {
            return Ok(None);
        };
        let file_nodeid = self
            .revision
            .ino_to_file_nodeid
            .get(&ino)
            .expect("node should exist");
        let data = repo.filelog(info.path)?.data_for_node(*file_nodeid)?;
        Ok(Some(data.into_file_data()?))
    }

    fn entry_for_dirstate_node(
        &self,
        FuseNodeInfo { path, size, flags, offset }: FuseNodeInfo,
    ) -> Entry {
        let ino = RevisionInodeEncoder::offset_to_ino(
            self.revision.files_root_ino,
            offset,
        );
        let name = path.split_filename().1.as_bytes();
        let name = OsStr::from_bytes(name).to_os_string();
        if let Some(flags) = flags {
            Entry::File { name, ino, size, flags }
        } else {
            Entry::Dir { name, ino }
        }
    }

    /// Return the changelog [`Revision`] for this [`Self`]
    pub fn changelog_rev(&self) -> Revision {
        self.changelog_rev
    }
}

/// Holds the tree representation of a given changelog revision
struct RevisionTree {
    /// The full dirstate for this revision
    dirstate: OwningDirstateMap,
    /// Mapping of inode to file nodeid, so we can answer reads
    ino_to_file_nodeid: DashMap<INodeNo, Node>,
    /// Inode for the "files" folder for this revision
    files_root_ino: INodeNo,
    /// Mapping of all reserved inodes to their FUSE entries
    pub reserved: FastHashMap<INodeNo, ReservedRevisionEntry>,
    /// Mapping of all reserved inodes that have file contents
    reserved_contents: FastHashMap<INodeNo, RawData>,
}

impl RevisionTree {
    #[allow(clippy::too_many_arguments)]
    pub fn from_revision(
        repo: &Repo,
        file_nodeid_to_size: &DashMap<Node, usize>,
        manifest: &Manifest,
        manifest_details: ManifestRevisionDetails,
        start_time: SystemTime,
        narrow_matcher: &impl Matcher,
    ) -> Result<RevisionTree, HgError> {
        let (dirstate, ino_to_file_nodeid, inode_encoder) =
            Self::process_manifest_files(
                repo,
                file_nodeid_to_size,
                manifest,
                manifest_details,
                start_time,
                narrow_matcher,
            )?;

        // Remember the inodes for reserved entries
        let reserved = inode_encoder.reserved_entries;

        let tree = RevisionTree {
            dirstate,
            ino_to_file_nodeid,
            files_root_ino: inode_encoder.files_root_inode,
            reserved,
            reserved_contents: inode_encoder.reserved_contents,
        };
        Ok(tree)
    }

    /// Returns a temporary mapping of all directories to their children, along
    /// with the array of all files processed into [`RevisionTreeFile`].
    #[tracing::instrument(level = "debug", skip_all)]
    #[allow(clippy::too_many_arguments)]
    fn process_manifest_files(
        repo: &Repo,
        file_nodeid_to_size: &DashMap<Node, usize>,
        manifest: &Manifest,
        manifest_details: ManifestRevisionDetails,
        start_time: SystemTime,
        narrow_matcher: &impl Matcher,
    ) -> Result<
        (OwningDirstateMap, DashMap<INodeNo, Node>, RevisionInodeEncoder),
        HgError,
    > {
        let warnings = HgWarningContext::new();
        let sparse_matcher = sparse::matcher(
            repo,
            Some(vec![manifest_details.changeset_rev]),
            warnings.sender(),
        )?;
        let _ = warnings.finish(|warning| -> Result<(), Infallible> {
            // TODO better warnings
            tracing::warn!("sparse warning: {:?}", warning);
            Ok(())
        });

        let files_for_rev = FilesForDirstateBorrowed::new(
            manifest,
            &narrow_matcher,
            &sparse_matcher,
        );
        let narrow_patterns = narrow::raw_store_patterns(repo)?;

        let cached_file_sizes = file_nodeid_to_size.len();

        // File sizes
        let size_span = tracing::debug_span!("computing sizes").entered();
        let path_to_filenode_id = DashMap::new();
        // Collect all file sizes in parallel
        let store_vfs = &repo.store_vfs();
        let config = repo.config();
        let requirements = repo.requirements();
        // This function being called in a loop can add up, so do it only
        // once since it doesn't change in this context
        let default_revlog_options =
            hg::revlog::options::default_revlog_options(
                config,
                requirements,
                hg::revlog::RevlogType::Filelog,
            )?;
        let files_info = files_for_rev
            .par_iter()
            .map(|res| {
                let (path, file_node, flags) = res?;
                path_to_filenode_id.insert(path, file_node);
                if let Some(size) = file_nodeid_to_size.get(&file_node) {
                    // We already know this size
                    return Ok((path, file_node, flags, *size));
                }
                // Work around `Repo::filelog` creating revlog options and
                // a store VFS every time. TODO just use `Repo::filelog`
                // once that's cached properly.
                let filelog = hg::revlog::filelog::Filelog::open_vfs(
                    store_vfs,
                    path,
                    default_revlog_options,
                )?;
                // TODO keep a persistent NodeTree of filenode_id -> size
                // until we have it in revlogv2?
                let size = filelog.contents_size_for_node(file_node)?;
                file_nodeid_to_size.insert(file_node, size);
                Ok((path, file_node, flags, size))
            })
            .collect::<Result<Vec<_>, hg::revlog::RevlogError>>()?;
        drop(size_span);

        let available_inode_range = RootInodeEncoder::revision_inode_range(
            manifest_details.changeset_rev,
        );
        let mut inode_encoder = RevisionInodeEncoder::new(
            available_inode_range,
            repo.store_path().parent().expect("store always has a parent"),
            &manifest_details.branch,
            repo.has_sparse(),
            narrow_patterns,
        );

        let mut dirstate = OwningDirstateMap::new_empty(&b""[..], None);

        let map_span = tracing::debug_span!("building the dirstate").entered();
        let start_time: TruncatedTimestamp = start_time.into();
        for (path, _file_node_id, flags, size) in files_info {
            dirstate.reset_state(DirstateEntryReset {
                filename: path,
                wc_tracked: true,
                p1_tracked: true,
                p2_info: false, // We're never in an active merge
                has_meaningful_mtime: true,
                parent_file_data_opt: Some(ParentFileData {
                    mode_size: Some((
                        permissions_for_file(flags).into(),
                        u_u32(size),
                    )),
                    mtime: Some(start_time),
                }),
                from_empty: true, // We are starting from scratch
                set_parents_mtime: true,
            })?;
        }
        let cache_misses = file_nodeid_to_size.len() - cached_file_sizes;
        drop(map_span);
        tracing::debug!("cached {} new filelog node sizes", cache_misses);

        let dirstate_parents = DirstateParents {
            p1: manifest_details.changeset_node,
            p2: NULL_NODE,
        };
        let (dirstate, inode_to_file_nodeid) = inode_encoder.add_dirstate(
            dirstate,
            dirstate_parents,
            path_to_filenode_id,
        )?;

        Ok((dirstate, inode_to_file_nodeid, inode_encoder))
    }
}

/// Represents a reserved FUSE entry inside the revision's root dir
#[derive(Debug)]
pub(super) struct ReservedRevisionEntry {
    pub entry: Entry,
    pub children: Vec<INodeNo>,
}

/// Responsible for assigning inodes in the available range for a given
/// changelog revision
struct RevisionInodeEncoder {
    /// The current sequence number for inodes
    current_ino: AtomicU64,
    /// The inode range available to this revision.
    available_range: Range<INodeNo>,
    /// Special FUSE entries in the revision scope, not from Mercurial
    reserved_entries: FastHashMap<INodeNo, ReservedRevisionEntry>,
    /// Inode for the root of the actual revision files
    files_root_inode: INodeNo,
    /// Inode for the root of the .hg in the revision
    dot_hg_ino: INodeNo,
    /// Inode for the root of the revision hierarchy
    root_ino: INodeNo,
    /// Mapping each reserved file's inode to its data
    reserved_contents: FastHashMap<INodeNo, RawData>,
}

impl RevisionInodeEncoder {
    fn new(
        available_range: Range<INodeNo>,
        root_hg_path: &Path,
        branch: &[u8],
        has_sparse: bool,
        narrow_patterns: Option<Vec<u8>>,
    ) -> Self {
        let mut encoder = Self {
            current_ino: AtomicU64::new(available_range.start.0),
            available_range,
            reserved_entries: FastHashMap::default(),
            // Placeholder value while we generate it
            files_root_inode: INodeNo(0),
            // Placeholder value while we generate it
            dot_hg_ino: INodeNo(0),
            // Placeholder value while we generate it
            root_ino: INodeNo(0),
            reserved_contents: FastHashMap::default(),
        };
        // Must be the first in our current encoding, see `RootInodeEncoder`
        let root_ino = encoder.new_inode();

        let mut requirements = vec![
            SHARED_REQUIREMENT,
            SHARESAFE_REQUIREMENT,
            DIRSTATE_V2_REQUIREMENT,
            DIRSTATE_TRACKED_HINT_V1,
        ];
        if has_sparse {
            requirements.push(SPARSE_REQUIREMENT);
        }
        let requirements = requirements.join("\n");
        let requires_contents = requirements.as_bytes();
        let requires_ino =
            encoder.add_reserved_file("requires", requires_contents.into());

        let store_path_bytes = get_bytes_from_path(root_hg_path);
        let sharedpath_ino =
            encoder.add_reserved_file("sharedpath", store_path_bytes.into());

        let branch_ino = encoder.add_reserved_file("branch", branch.into());

        let mut tracked_key = vec![];
        write_tracked_key_to(&mut tracked_key)
            .expect("writing to Vec cannot fail");
        let tracked_key_ino = encoder
            .add_reserved_file("dirstate-tracked-key", tracked_key.into());

        let mut dot_hg_files =
            vec![requires_ino, sharedpath_ino, branch_ino, tracked_key_ino];

        if let Some(patterns) = narrow_patterns {
            let narrow_dirstate = encoder
                .add_reserved_file(narrow::DIRSTATE_FILENAME, patterns.into());
            dot_hg_files.push(narrow_dirstate);
        }

        let dot_hg_ino = encoder.add_reserved_directory(".hg", &dot_hg_files);

        // /!\ Keep in sync with `path_to_revision_working_copy`
        // Will be special-cased later to also point to the revision files
        let files_root_ino =
            encoder.add_reserved_directory(FILES_INODE_NAME, &[dot_hg_ino]);

        encoder.reserved_entries.insert(
            root_ino,
            ReservedRevisionEntry {
                entry: Entry::Dir { name: "".into(), ino: root_ino },
                children: vec![files_root_ino],
            },
        );

        encoder.files_root_inode = files_root_ino;
        encoder.dot_hg_ino = dot_hg_ino;
        encoder.root_ino = root_ino;
        encoder
    }

    /// Returns a new unique inode
    fn new_inode(&self) -> INodeNo {
        let new_inode =
            INodeNo(self.current_ino.fetch_add(1, Ordering::Relaxed));
        assert!(self.available_range.contains(&new_inode), "inode overflow");
        new_inode
    }

    #[tracing::instrument(level = "debug", skip_all)]
    fn add_dirstate(
        &mut self,
        dirstate: OwningDirstateMap,
        parents: DirstateParents,
        path_to_filenode_id: DashMap<&HgPath, Node>,
    ) -> Result<(OwningDirstateMap, DashMap<INodeNo, Node>), HgError> {
        let ino_to_filenode_id = DashMap::with_capacity(dirstate.len());
        let latest_ino = AtomicU64::new(self.files_root_inode.0);
        // Insert them in the files root
        let files_root_entry = self
            .reserved_entries
            .get_mut(&self.files_root_inode)
            .expect("root node should exist");

        // Special case to remember the root nodes since they need to be
        // attached to the files root. The mutex will be uncontended since
        // the dirstate does not support parallel inserts, this is purely so we
        // can satisfy the callback being immutable.
        let root_nodes = Mutex::new(&mut files_root_entry.children);

        // Called on every node, in serialization order, to store the mapping
        // of path -> filenodeid (or nothing for directories).
        let visit: WriteNodeVisit = &|path, is_root_node, offset| {
            let ino = Self::offset_to_ino(self.files_root_inode, u64_u(offset));
            if is_root_node {
                root_nodes.lock().expect("propagate the panic").push(ino);
            }

            // Remember the inode to filenode id mapping to answer reads
            let path_to_filenode_entry = path_to_filenode_id.get(path);
            path_to_filenode_entry
                .map(|node_id| ino_to_filenode_id.insert(ino, *node_id));
            latest_ino.store(ino.0, Ordering::Relaxed);
        };

        let (data, tree_metadata, appending, old_size) = dirstate
            .pack_v2(DirstateMapWriteMode::ForceNewDataFile, Some(visit))?;
        let new_inode = latest_ino
            .load(Ordering::Relaxed)
            .checked_add(1)
            .expect("inode overflow");
        assert!(
            self.available_range.contains(&INodeNo(new_inode)),
            "inode overflow"
        );
        self.current_ino = AtomicU64::new(new_inode);
        // Paranoid checks
        assert!(!appending, "dirstate must be written from scratch");
        assert_eq!(old_size, 0, "dirstate must be written from scratch");
        let data_size = data.len();
        let uuid = Docket::new_uid();

        // Create the data file
        let packed_data: RawData = data.into();
        let data_ino = self
            .add_reserved_file(format!("dirstate.{uuid}"), packed_data.clone());

        // Create the docket file
        let docket_data = Docket::serialize(
            parents,
            tree_metadata,
            u_u64(data_size),
            uuid.as_bytes(),
        )
        .expect("dirstate overflow");

        let docket_data: RawData = docket_data.into();
        let docket_ino = self.add_reserved_file("dirstate", docket_data);

        // Insert them in .hg
        let dot_hg_entry = self
            .reserved_entries
            .get_mut(&self.dot_hg_ino)
            .expect(".hg node should exist");
        dot_hg_entry.children.push(data_ino);
        dot_hg_entry.children.push(docket_ino);

        // Return a new dirstate based off the packed data
        let new_dirstate = OwningDirstateMap::new_v2(
            packed_data,
            data_size,
            tree_metadata.as_bytes(),
            uuid.as_bytes().to_vec(),
            None,
        )?;
        Ok((new_dirstate, ino_to_filenode_id))
    }

    fn add_reserved_directory(
        &mut self,
        name: impl Into<OsString>,
        children: &[INodeNo],
    ) -> INodeNo {
        let ino = self.new_inode();

        self.reserved_entries.insert(
            ino,
            ReservedRevisionEntry {
                entry: Entry::Dir { name: name.into(), ino },
                children: children.to_vec(),
            },
        );
        ino
    }

    fn add_reserved_file(
        &mut self,
        name: impl Into<OsString>,
        contents: RawData,
    ) -> INodeNo {
        let ino = self.new_inode();

        let entry = ReservedRevisionEntry {
            entry: Entry::File {
                name: name.into(),
                ino,
                size: u_u64(contents.len()),
                flags: ManifestFlags::new_empty(),
            },
            children: vec![],
        };
        self.reserved_contents.insert(ino, contents);
        self.reserved_entries.insert(ino, entry);
        ino
    }

    /// Return the offset of the dirstate [`DirstateNode`] inside this
    /// revisions's packed in-memory dirstate, given this inode and the
    /// inode of its "files" folder.
    fn ino_to_offset(files_root_ino: INodeNo, ino: INodeNo) -> usize {
        u64_u(
            ino.0
                .checked_sub(files_root_ino.0)
                .expect("inode underflow")
                .checked_sub(1)
                .expect("inode underflow"),
        )
    }

    /// Return the inode that matches this offset inside this revision's packed
    /// in-memory dirstate, given the inode of its "files" folder.
    fn offset_to_ino(files_root_ino: INodeNo, offset: usize) -> INodeNo {
        INodeNo(
            files_root_ino
                .0
                .checked_add(1)
                .expect("inode overflow")
                .checked_add(u_u64(offset))
                .expect("inode overlow"),
        )
    }
}
