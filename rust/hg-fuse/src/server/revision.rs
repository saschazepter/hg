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
use hg::dirstate::dirstate_map::DirstateEntryReset;
use hg::dirstate::dirstate_map::DirstateMapWriteMode;
use hg::dirstate::dirstate_map::FuseNodeInfo;
use hg::dirstate::entry::ParentFileData;
use hg::dirstate::entry::TruncatedTimestamp;
use hg::dirstate::on_disk::Docket;
use hg::dirstate::on_disk::WriteNodeVisit;
use hg::dirstate::on_disk::write_tracked_key_to;
use hg::dirstate::owning::OwningDirstateMap;
use hg::narrow;
use hg::requirements::DIRSTATE_TRACKED_HINT_V1;
use hg::requirements::DIRSTATE_V2_REQUIREMENT;
use hg::requirements::SHARED_REQUIREMENT;
use hg::requirements::SHARESAFE_REQUIREMENT;
use hg::requirements::SPARSE_REQUIREMENT;
use hg::revlog::manifest::ManifestFlags;
use hg::utils::RawData;
use hg::utils::files::get_bytes_from_path;
use hg::utils::hg_path::HgPath;
use hg::utils::hg_path::hg_path_to_path_buf;
use hg::utils::u_u64;
use hg::utils::u64_u;
use rayon::iter::ParallelBridge;
use rayon::iter::ParallelIterator;

use crate::fuse::Entry;
use crate::fuse::FILES_INODE_NAME;
use crate::fuse::RootInodeEncoder;
use crate::server::permissions_for_file;
use crate::server::store::ChangesetFiles;
use crate::server::store::Error as StoreError;
use crate::server::store::FileToken;
use crate::server::store::StoreBackend;
use crate::server::store::StoreInfo;

/// Represents a manifest revision
pub(super) struct OwnedRevision<T> {
    revision: RevisionTree<T>,
}

impl<T: FileToken> OwnedRevision<T> {
    /// Return a [`Self`] that represents this manifest, along with the new
    /// inodes.
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn from_revision<S: StoreBackend<T>>(
        store: &S,
        changeset: Node,
        start_time: SystemTime,
    ) -> Result<Self, StoreError<T>> {
        let revision =
            RevisionTree::from_revision(store, changeset, start_time)?;
        Ok(Self { revision })
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

    pub fn read<S: StoreBackend<T>>(
        &self,
        ino: INodeNo,
        store: &S,
    ) -> Result<Option<RawData>, StoreError<T>> {
        let Some(rev_idx) = RootInodeEncoder::ino_to_idx(ino) else {
            return Ok(None);
        };
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

        let changeset = store.node_for_idx(rev_idx)?;
        let token =
            self.revision.ino_to_token.get(&ino).expect("node should exist");
        let data = store.file_data(changeset, info.path, *token)?;
        Ok(Some(data))
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
}

/// Holds the tree representation of a given changelog revision
struct RevisionTree<T> {
    /// The full dirstate for this revision
    dirstate: OwningDirstateMap,
    /// Mapping of inode to file token, so we can answer reads
    ino_to_token: DashMap<INodeNo, T>,
    /// Inode for the "files" folder for this revision
    files_root_ino: INodeNo,
    /// Mapping of all reserved inodes to their FUSE entries
    pub reserved: FastHashMap<INodeNo, ReservedRevisionEntry>,
    /// Mapping of all reserved inodes that have file contents
    reserved_contents: FastHashMap<INodeNo, RawData>,
}

impl<T: FileToken> RevisionTree<T> {
    #[allow(clippy::too_many_arguments)]
    pub fn from_revision<S: StoreBackend<T>>(
        store: &S,
        changeset: Node,
        start_time: SystemTime,
    ) -> Result<RevisionTree<T>, StoreError<T>> {
        let (dirstate, ino_to_file_nodeid, inode_encoder) =
            Self::process_manifest_files(store, changeset, start_time)?;

        // Remember the inodes for reserved entries
        let reserved = inode_encoder.reserved_entries;

        let tree = RevisionTree {
            dirstate,
            ino_to_token: ino_to_file_nodeid,
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
    fn process_manifest_files<S: StoreBackend<T>>(
        store: &S,
        changeset: Node,
        start_time: SystemTime,
    ) -> Result<
        (OwningDirstateMap, DashMap<INodeNo, T>, RevisionInodeEncoder),
        StoreError<T>,
    > {
        let revision_idx = store.idx_for_node(changeset)?;
        let available_inode_range =
            RootInodeEncoder::revision_inode_range(revision_idx);
        let mut inode_encoder = RevisionInodeEncoder::new(
            available_inode_range,
            store.changeset_store_info(changeset)?,
            store.server_config().archive_view,
        );

        let mut dirstate = OwningDirstateMap::new_empty(&b""[..], None);

        let map_span = tracing::debug_span!("building the dirstate").entered();
        let start_time: TruncatedTimestamp = start_time.into();
        let files = store.changeset_files(changeset)?;
        let mut path_to_token = FastHashMap::default();
        path_to_token.reserve(files.len());
        for file_info in files.iter() {
            path_to_token.insert(file_info.path, file_info.token);
            dirstate
                .reset_state(DirstateEntryReset {
                    filename: file_info.path,
                    wc_tracked: true,
                    p1_tracked: true,
                    p2_info: false, // We're never in an active merge
                    has_meaningful_mtime: true,
                    parent_file_data_opt: Some(ParentFileData {
                        mode_size: Some((
                            permissions_for_file(file_info.flags).into(),
                            file_info.size.try_into().expect("file too large"),
                        )),
                        mtime: Some(start_time),
                    }),
                    from_empty: true, // We are starting from scratch
                    set_parents_mtime: true,
                })
                .expect(
                    "insert in brand-new in-memory dirstate should not fail",
                );
        }
        drop(map_span);

        let dirstate_parents = DirstateParents { p1: changeset, p2: NULL_NODE };
        let (dirstate, inode_to_token) = inode_encoder.add_dirstate(
            dirstate,
            dirstate_parents,
            path_to_token,
        )?;

        Ok((dirstate, inode_to_token, inode_encoder))
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
    dot_hg_ino: Option<INodeNo>,
    /// Inode for the root of the revision hierarchy
    root_ino: INodeNo,
    /// Mapping each reserved file's inode to its data
    reserved_contents: FastHashMap<INodeNo, RawData>,
}

impl RevisionInodeEncoder {
    fn new(
        available_range: Range<INodeNo>,
        store_info: Option<StoreInfo>,
        archive_view: bool,
    ) -> Self {
        let mut encoder = Self {
            current_ino: AtomicU64::new(available_range.start.0),
            available_range,
            reserved_entries: FastHashMap::default(),
            // Placeholder value while we generate it
            files_root_inode: INodeNo(0),
            // Will be replaced with an actual inode unless archive_view is true
            dot_hg_ino: None,
            // Placeholder value while we generate it
            root_ino: INodeNo(0),
            reserved_contents: FastHashMap::default(),
        };
        // Must be the first in our current encoding, see `RootInodeEncoder`
        let root_ino = encoder.new_inode();

        // /!\ Keep in sync with `path_to_revision_working_copy`
        // Will be special-cased later to also point to the revision files
        let files_root_ino = if archive_view {
            encoder.add_reserved_directory(FILES_INODE_NAME, &[])
        } else {
            let dot_hg_ino = encoder.add_dot_hg(store_info);
            encoder.dot_hg_ino = Some(dot_hg_ino);
            encoder.add_reserved_directory(FILES_INODE_NAME, &[dot_hg_ino])
        };

        encoder.reserved_entries.insert(
            root_ino,
            ReservedRevisionEntry {
                entry: Entry::Dir { name: "".into(), ino: root_ino },
                children: vec![files_root_ino],
            },
        );

        encoder.files_root_inode = files_root_ino;
        encoder.root_ino = root_ino;
        encoder
    }

    fn add_dot_hg(&mut self, store_info: Option<StoreInfo>) -> INodeNo {
        let mut requirements = vec![
            SHARED_REQUIREMENT,
            SHARESAFE_REQUIREMENT,
            DIRSTATE_V2_REQUIREMENT,
            DIRSTATE_TRACKED_HINT_V1,
        ];
        let mut dot_hg_files = vec![];

        if let Some(info) = store_info {
            if info.has_sparse {
                requirements.push(SPARSE_REQUIREMENT);
            }
            let store_path_bytes = get_bytes_from_path(info.share_source);
            let sharedpath_ino =
                self.add_reserved_file("sharedpath", store_path_bytes.into());
            dot_hg_files.push(sharedpath_ino);

            let branch_ino =
                self.add_reserved_file("branch", info.branch.as_bytes().into());
            dot_hg_files.push(branch_ino);

            if let Some(patterns) = info.narrow_patterns {
                let narrow_dirstate = self.add_reserved_file(
                    narrow::DIRSTATE_FILENAME,
                    patterns.into(),
                );
                dot_hg_files.push(narrow_dirstate);
            }
        }
        let requirements = requirements.join("\n");
        let requires_contents = requirements.as_bytes();
        let requires_ino =
            self.add_reserved_file("requires", requires_contents.into());

        let mut tracked_key = vec![];
        write_tracked_key_to(&mut tracked_key)
            .expect("writing to Vec cannot fail");
        let tracked_key_ino =
            self.add_reserved_file("dirstate-tracked-hint", tracked_key.into());

        dot_hg_files.push(requires_ino);
        dot_hg_files.push(tracked_key_ino);
        self.add_reserved_directory(".hg", &dot_hg_files)
    }

    /// Returns a new unique inode
    fn new_inode(&self) -> INodeNo {
        let new_inode =
            INodeNo(self.current_ino.fetch_add(1, Ordering::Relaxed));
        assert!(self.available_range.contains(&new_inode), "inode overflow");
        new_inode
    }

    #[tracing::instrument(level = "debug", skip_all)]
    fn add_dirstate<T: FileToken>(
        &mut self,
        dirstate: OwningDirstateMap,
        parents: DirstateParents,
        path_to_token: FastHashMap<&HgPath, T>,
    ) -> Result<(OwningDirstateMap, DashMap<INodeNo, T>), StoreError<T>> {
        let ino_to_token = DashMap::with_capacity(dirstate.len());
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

            // Remember the inode to token mapping to answer reads
            let path_to_token_entry = path_to_token.get(path);
            path_to_token_entry.map(|token| ino_to_token.insert(ino, *token));
            latest_ino.store(ino.0, Ordering::Relaxed);
        };

        let packed_res = dirstate
            .pack_v2(DirstateMapWriteMode::ForceNewDataFile, Some(visit));
        let (data, tree_metadata, appending, old_size) = packed_res.expect(
            "in-memory serialization of a brand-new dirstate should not fail",
        );
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
        if let Some(dot_hg_ino) = self.dot_hg_ino.as_ref() {
            let dot_hg_entry = self
                .reserved_entries
                .get_mut(dot_hg_ino)
                .expect(".hg node should exist");
            dot_hg_entry.children.push(data_ino);
            dot_hg_entry.children.push(docket_ino);
        }

        // Return a new dirstate based off the packed data
        let new_dirstate = OwningDirstateMap::new_v2(
            packed_data,
            data_size,
            tree_metadata.as_bytes(),
            uuid.as_bytes().to_vec(),
            None,
        )
        .expect("in-memory creation of a brand-new dirstate should not fail");
        Ok((new_dirstate, ino_to_token))
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
                flags: ManifestFlags::EMPTY,
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
