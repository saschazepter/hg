use std::collections::HashSet;
use std::convert::Infallible;
use std::ffi::OsStr;
use std::ffi::OsString;
use std::iter::repeat;
use std::ops::Range;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::path::PathBuf;
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
use hg::dirstate::entry::ParentFileData;
use hg::dirstate::entry::TruncatedTimestamp;
use hg::dirstate::on_disk::Docket;
use hg::dirstate::on_disk::write_tracked_key_to;
use hg::dirstate::owning::OwningDirstateMap;
use hg::dirstate::path_with_basename::WithBasename;
use hg::errors::HgError;
use hg::matchers::Matcher;
use hg::narrow;
use hg::operations::ExpandedManifestEntry;
use hg::operations::FilesForRevBorrowed;
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
use hg::utils::hg_path::ZeroPath;
use hg::utils::hg_path::hg_path_to_path_buf;
use hg::utils::u_u32;
use hg::utils::u_u64;
use hg::warnings::HgWarningContext;
use rayon::iter::IndexedParallelIterator;
use rayon::iter::IntoParallelRefIterator;
use rayon::iter::ParallelIterator;

use crate::fuse::Entry;
use crate::fuse::FILES_INODE_NAME;
use crate::fuse::InodeEncoder;
use crate::fuse::RootInodeEncoder;
use crate::server::permissions_for_file;

/// Mapping of inode to a reference in the revision (including reserved ones)
type InoToRef = FastHashMap<INodeNo, RevisionTreeRef>;

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
    /// The revision itself, in a private type to prevent generated `self_cell`
    /// methods like `borrow_dependent` from being accessible from outside of
    /// this module.
    revision: RevisionHolder,
    ino_to_ref: InoToRef,
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
    ) -> Result<(Self, Vec<INodeNo>), HgError> {
        let mut ino_to_ref = FastHashMap::default();
        let changelog_rev = manifest_details.changeset_rev;
        let mut new_inodes = vec![];
        let revision = RevisionHolder::try_new(
            manifest,
            |manifest| -> Result<RevisionTree<'_>, HgError> {
                RevisionTree::from_revision(
                    repo,
                    file_nodeid_to_size,
                    &mut ino_to_ref,
                    &mut new_inodes,
                    manifest,
                    manifest_details,
                    start_time,
                    narrow_matcher,
                )
            },
        )?;
        Ok((Self { revision, ino_to_ref, changelog_rev }, new_inodes))
    }

    /// Preload this revision's filesystem structure into the kernel's caches.
    /// `root` must be the path to the revisions' working copy for this to work,
    /// *not* the root of the FUSE (it is different as of this writing).
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn preload(&self, root: &Path) {
        // TODO figure out if manually doing relative `openat`/`fstatat` calls
        // is worth the trouble, given that we should just be using an in-memory
        // dirstate soon.
        let inner = self.revision.borrow_dependent();

        // reverse the iterator so we load the top-level dirs first
        inner.dirs.par_iter().rev().for_each(|dir| {
            let path = hg_path_to_path_buf(dir.path.full_path());

            if let Ok(path) = path {
                Self::preload_directory(root.join(path));
            }
        });
        inner.files.par_iter().for_each(|file| {
            let path = hg_path_to_path_buf(file.path.full_path());
            if let Ok(path) = path {
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
        let tree_ref = self.ino_to_ref.get(&ino)?;
        let revision = self.revision.borrow_dependent();
        match tree_ref {
            RevisionTreeRef::File(idx) => {
                let file = &revision.files[*idx];
                Some(file.into())
            }
            RevisionTreeRef::Dir(idx) => {
                let dir = &revision.dirs[*idx];
                Some(dir.into())
            }
            RevisionTreeRef::Reserved(_) => {
                let entry = &revision.reserved[&ino];
                Some(entry.entry.clone())
            }
        }
    }

    /// Return the child entry matching `name` for inode `parent`, if both exist
    pub fn lookup(&self, parent: INodeNo, name: &OsStr) -> Option<Entry> {
        let parent_ref = self.ino_to_ref.get(&parent)?;
        let revision = self.revision.borrow_dependent();
        match parent_ref {
            RevisionTreeRef::File(_) => None,
            RevisionTreeRef::Reserved(_) => {
                let maybe_dir = &revision.reserved[&parent];
                maybe_dir.children.iter().find_map(|ino| {
                    let child = &revision.reserved[ino];
                    let entry = &child.entry;
                    if entry.name() == name {
                        Some(entry.clone())
                    } else {
                        None
                    }
                })
            }
            RevisionTreeRef::Dir(idx) => {
                let dir = &revision.dirs[*idx];
                dir.children.iter().find_map(|&c| match c {
                    RevisionTreeRef::File(idx) => {
                        let file = &revision.files[idx];
                        let file_name = file.path.base_name().as_bytes();
                        if file_name == name.as_encoded_bytes() {
                            Some(file.into())
                        } else {
                            None
                        }
                    }
                    RevisionTreeRef::Dir(idx) => {
                        let dir = &revision.dirs[idx];
                        let dir_name = dir.path.base_name().as_bytes();
                        if dir_name == name.as_encoded_bytes() {
                            Some(dir.into())
                        } else {
                            None
                        }
                    }
                    RevisionTreeRef::Reserved(ino) => {
                        let reserved = &revision.reserved[&ino];
                        if reserved.entry.name() == name {
                            Some(reserved.entry.clone())
                        } else {
                            None
                        }
                    }
                })
            }
        }
    }

    /// Return direct children entries for `ino`
    pub fn entries(&self, ino: INodeNo) -> Option<Vec<Entry>> {
        let tree_ref = self.ino_to_ref.get(&ino)?;
        let revision = self.revision.borrow_dependent();
        match tree_ref {
            RevisionTreeRef::File(_) => None,
            RevisionTreeRef::Dir(idx) => {
                let dir = &revision.dirs[*idx];
                let children = dir
                    .children
                    .iter()
                    .map(|child_ref| match child_ref {
                        RevisionTreeRef::File(idx) => {
                            let file = &revision.files[*idx];
                            file.into()
                        }
                        RevisionTreeRef::Dir(idx) => {
                            let dir = &revision.dirs[*idx];
                            dir.into()
                        }
                        RevisionTreeRef::Reserved(ino) => {
                            let reserved = &revision.reserved[ino];
                            reserved.entry.clone()
                        }
                    })
                    .collect();
                Some(children)
            }
            RevisionTreeRef::Reserved(ino) => {
                let reserved = &revision.reserved[ino];
                match reserved.entry {
                    Entry::Dir { .. } => {
                        let children = reserved
                            .children
                            .iter()
                            .map(|child_ref| {
                                let child_ref = &revision.reserved[child_ref];
                                child_ref.entry.clone()
                            })
                            .collect();
                        Some(children)
                    }
                    Entry::File { .. } => None,
                }
            }
        }
    }

    pub fn read(
        &self,
        ino: INodeNo,
        repo: &Repo,
    ) -> Result<Option<RawData>, HgError> {
        let Some(tree_ref) = self.ino_to_ref.get(&ino) else {
            return Ok(None);
        };
        let revision = self.revision.borrow_dependent();
        match tree_ref {
            RevisionTreeRef::File(idx) => {
                let file = &revision.files[*idx];
                let full_path = file.path.full_path();
                let data =
                    repo.filelog(full_path)?.data_for_node(file.file_node)?;
                Ok(Some(data.into_file_data()?))
            }
            RevisionTreeRef::Dir(_) => Ok(None),
            RevisionTreeRef::Reserved(ino) => {
                let reserved = &revision.reserved[ino];
                match &reserved.entry {
                    Entry::Dir { .. } => Ok(None),
                    Entry::File { ino, .. } => {
                        Ok(Some(revision.reserved_contents[ino].clone()))
                    }
                }
            }
        }
    }

    /// Return the changelog [`Revision`] for this [`Self`]
    pub fn changelog_rev(&self) -> Revision {
        self.changelog_rev
    }
}

self_cell::self_cell!(
    /// Keeps a `RevisionTree<'manifest>` next to the `manifest` that it
    /// borrows.
    struct RevisionHolder {
        owner: Manifest,
        #[covariant]
        dependent: RevisionTree,
    }
);

/// Holds the tree representation of a given changelog revision
struct RevisionTree<'manifest> {
    /// Holds all files
    pub files: Vec<RevisionTreeFile<'manifest>>,
    /// Holds all folders
    pub dirs: Vec<RevisionTreeDir<'manifest>>,
    /// Holds all reserved FUSE entries
    pub reserved: FastHashMap<INodeNo, ReservedRevisionEntry>,
    /// Holds all reserved FUSE file contents
    reserved_contents: FastHashMap<INodeNo, RawData>,
}

impl std::fmt::Debug for RevisionTree<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut builder = f.debug_struct("RevisionTree");
        builder
            .field("files", &self.files.len())
            .field("dirs", &self.dirs.len());
        builder.finish()
    }
}

/// Iterator over the size for each filenode
type FilenodeSizeIterator<'a> = &'a mut (dyn Iterator<Item = usize> + 'static);

impl<'manifest> RevisionTree<'manifest> {
    #[allow(clippy::too_many_arguments)]
    pub fn from_revision(
        repo: &Repo,
        file_nodeid_to_size: &DashMap<Node, usize>,
        ino_to_ref: &mut InoToRef,
        new_inodes: &mut Vec<INodeNo>,
        manifest: &'manifest Manifest,
        manifest_details: ManifestRevisionDetails,
        start_time: SystemTime,
        narrow_matcher: &impl Matcher,
    ) -> Result<RevisionTree<'manifest>, HgError> {
        let (temp_map, files_array) = Self::process_manifest_files(
            repo,
            file_nodeid_to_size,
            ino_to_ref,
            new_inodes,
            manifest,
            manifest_details,
            start_time,
            narrow_matcher,
        )?;

        let mut dirs_array = Vec::with_capacity(temp_map.mapping.len());

        // Now that we have all directories, create the actual tree structure
        temp_map.to_tree(
            ino_to_ref,
            new_inodes,
            HgPath::new(b""),
            &mut vec![],
            &mut dirs_array,
        );

        let files_root_ino = temp_map.inode_encoder.files_root_inode;

        // Remember the inodes for reserved entries
        let reserved = temp_map.inode_encoder.reserved_entries;
        for (inode, _) in reserved.iter() {
            // We skip the files root inode since it serves the files
            if *inode != files_root_ino {
                ino_to_ref.insert(*inode, RevisionTreeRef::Reserved(*inode));
            }
            new_inodes.push(*inode);
        }

        dirs_array
            .last_mut()
            .expect("should have at least the root dir")
            .children
            .extend(
                reserved[&files_root_ino]
                    .children
                    .iter()
                    .map(|ino| RevisionTreeRef::Reserved(*ino)),
            );

        let tree = RevisionTree {
            files: files_array,
            dirs: dirs_array,
            reserved,
            reserved_contents: temp_map.inode_encoder.reserved_contents,
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
        ino_to_ref: &mut InoToRef,
        new_inodes: &mut Vec<INodeNo>,
        manifest: &'manifest Manifest,
        manifest_details: ManifestRevisionDetails,
        start_time: SystemTime,
        narrow_matcher: &impl Matcher,
    ) -> Result<(TempMap<'manifest>, Vec<RevisionTreeFile<'manifest>>), HgError>
    {
        let narrow_patterns = narrow::raw_store_patterns(repo)?;
        let files_for_rev = FilesForRevBorrowed::new(manifest, &narrow_matcher);

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

        // Sort the flat files so the children always come before the parents
        let mut zeropath_files = files_for_rev
            .iter()
            .map(|line| {
                let line = line?;
                Ok((ZeroPath::try_from(line.0)?, line))
            })
            .filter(|res| match res {
                // Filter according to the sparse profile
                Ok((_, (path, _, _))) => sparse_matcher.matches(path),
                Err(_) => true, // Errors must be included
            })
            .collect::<Result<Vec<(ZeroPath, ExpandedManifestEntry)>, HgError>>(
            )?;

        zeropath_files.sort_by(|a, b| a.0.cmp(&b.0));
        let number_of_files = zeropath_files.len();

        let cached_file_sizes = file_nodeid_to_size.len();

        // File sizes
        let size_span = tracing::debug_span!("computing sizes").entered();
        let use_fake_file_size =
            repo.config().get_bool(b"fuse", b"fake-file-sizes")?;
        let sizes_vec = if use_fake_file_size {
            vec![]
        } else {
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
            zeropath_files
                .par_iter()
                .map(|(_, (path, file_node, _flags))| {
                    if let Some(size) = file_nodeid_to_size.get(file_node) {
                        // We already know this size
                        return Ok(*size);
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
                    file_nodeid_to_size.insert(*file_node, size);
                    Ok(size)
                })
                .collect::<Result<Vec<_>, hg::revlog::RevlogError>>()?
        };
        drop(size_span);

        // Zip the files with their sizes without allocating useless sizes
        let mut always_zero = repeat(0);
        let mut sizes_iter = sizes_vec.into_iter();
        let manifest_iter = if use_fake_file_size {
            let repeat: FilenodeSizeIterator = &mut always_zero;
            zeropath_files.into_iter().zip(repeat)
        } else {
            let sizes_vec: &mut dyn Iterator<Item = usize> = &mut sizes_iter;
            zeropath_files.into_iter().zip(sizes_vec)
        };

        let available_inode_range = RootInodeEncoder::revision_inode_range(
            manifest_details.changeset_rev,
        );
        let inode_encoder = RevisionInodeEncoder::new(
            available_inode_range,
            repo.store_path().parent().expect("store always has a parent"),
            &manifest_details.branch,
            repo.has_sparse(),
            narrow_patterns,
        );
        // Explicitly set the root inode
        new_inodes.push(inode_encoder.root_ino);

        // Compute temporary mapping of all directories to their children
        let root_path = HgPath::new(b"");

        let mut temp_map = TempMap::new(inode_encoder);
        let mut files_array = Vec::with_capacity(number_of_files);
        let mut current_file_parent = root_path;

        let mut dirstate = OwningDirstateMap::new_empty(&b""[..], None);

        let map_span = tracing::debug_span!("building the map").entered();
        let start_time: TruncatedTimestamp = start_time.into();
        for ((_zeropath, line), size) in manifest_iter {
            Self::add_manifest_file_to_map(
                ino_to_ref,
                new_inodes,
                &mut files_array,
                &mut temp_map,
                &mut current_file_parent,
                (line, size),
                (&mut dirstate, start_time),
            )?;
        }
        let cache_misses = file_nodeid_to_size.len() - cached_file_sizes;
        tracing::debug!("cached {} new filelog node sizes", cache_misses);
        drop(map_span);

        let dirstate_parents = DirstateParents {
            p1: manifest_details.changeset_node,
            p2: NULL_NODE,
        };
        temp_map.inode_encoder.add_dirstate(dirstate, dirstate_parents)?;

        Ok((temp_map, files_array))
    }

    /// Processes a manifest line and adds it to the temporary map.
    ///
    /// * Creates its ancestor (thus directory) nodes
    /// * Computes the size of the file revision it points to
    /// * Assigns it an inode
    /// * Inserts the resulting file information in its parent node
    #[allow(clippy::too_many_arguments)]
    fn add_manifest_file_to_map(
        ino_to_ref: &mut InoToRef,
        new_inodes: &mut Vec<INodeNo>,
        files_array: &mut Vec<RevisionTreeFile<'manifest>>,
        temp_map: &mut TempMap<'manifest>,
        current_file_parent: &mut &'manifest HgPath,
        (line, size): (ExpandedManifestEntry<'manifest>, usize),
        (dirstate, start_time): (&mut OwningDirstateMap, TruncatedTimestamp),
    ) -> Result<(), HgError> {
        let (path, file_node_id, flags) = line;
        let file_parent = path.parent();
        if file_parent != *current_file_parent {
            // We've finished with the current dir
            *current_file_parent = file_parent;
            let mut dir_cursor = file_parent;
            let mut parent_dir = dir_cursor.parent();
            while dir_cursor != parent_dir {
                // Loop over parent dirs to create them if need be
                let dir_ref = TempMapItem::Dir(dir_cursor);
                temp_map
                    .mapping
                    .entry(parent_dir)
                    .and_modify(|s| {
                        // Insert the current level in its parent.
                        // We use a set for simple dedup, but should do
                        // better later.
                        s.insert(dir_ref);
                    })
                    .or_insert_with(|| {
                        let mut set = HashSet::new();
                        set.insert(dir_ref);
                        set
                    });
                dir_cursor = parent_dir;
                parent_dir = dir_cursor.parent();
            }
        }

        let inode = temp_map.inode_encoder.new_inode();

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

        let file_entry = RevisionTreeFile {
            inode,
            file_node: file_node_id,
            flags,
            path: WithBasename::new(path),
            size: u_u64(size),
        };
        files_array.push(file_entry);
        let file_idx = files_array.len() - 1;
        new_inodes.push(inode);
        ino_to_ref.insert(inode, RevisionTreeRef::File(file_idx));

        let file_ref = TempMapItem::File(file_idx);

        // Add it to its temporary parent
        temp_map
            .mapping
            .entry(file_parent)
            .and_modify(|s| {
                s.insert(file_ref);
            })
            .or_insert_with(|| {
                let mut set = HashSet::new();
                set.insert(file_ref);
                set
            });
        Ok(())
    }
}

/// Represents a file in a given manifest revision
pub(super) struct RevisionTreeFile<'manifest> {
    /// The unique inode for this file
    pub inode: INodeNo,
    /// Its full path from the base of the "working directory"
    pub path: WithBasename<&'manifest HgPath>,
    /// Flags for this file (mostly useful for exec or link)
    pub flags: ManifestFlags,
    /// The node for the corresponding filelog
    pub file_node: Node,
    /// The size of its full uncompressed contents
    pub size: u64,
}

impl From<&RevisionTreeFile<'_>> for Entry {
    fn from(file: &RevisionTreeFile) -> Self {
        Self::file(
            OsStr::from_bytes(file.path.base_name().as_bytes()).to_os_string(),
            file.inode,
            file.size,
            file.flags,
        )
    }
}

/// Represents a directory in a given manifest revision
#[derive(Debug)]
pub(super) struct RevisionTreeDir<'manifest> {
    /// The unique inode for this directory
    pub inode: INodeNo,
    /// Its full path from the base of the "working directory"
    pub path: WithBasename<&'manifest HgPath>,
    /// Pointers to its direct children
    pub children: Vec<RevisionTreeRef>,
}

impl From<&RevisionTreeDir<'_>> for Entry {
    fn from(dir: &RevisionTreeDir) -> Self {
        Self::dir(
            OsStr::from_bytes(dir.path.base_name().as_bytes()).to_os_string(),
            dir.inode,
        )
    }
}

/// Represents a pointer to an entry in the [`RevisionTree`]
#[derive(Copy, Clone, Debug)]
pub(super) enum RevisionTreeRef {
    /// Points to a file in the [`RevisionTree`]
    File(usize),
    /// Points to a directory the [`RevisionTree`]
    Dir(usize),
    /// Points to a reserved entry of the [`RevisionTree`]
    Reserved(INodeNo),
}

/// Mapping of path -> children, used in [`TempMap`]
type TempMapping<'manifest> =
    FastHashMap<&'manifest HgPath, HashSet<TempMapItem<'manifest>>>;

/// Temporary struct used to build the tree structure since we need to know
/// all parent -> children edges before being able to build the flat directory
/// vec used in [`RevisionTree`].
struct TempMap<'manifest> {
    mapping: TempMapping<'manifest>,
    /// Responsible for giving out inodes when building this revision
    inode_encoder: RevisionInodeEncoder,
}

impl<'manifest> TempMap<'manifest> {
    fn new(inode_encoder: RevisionInodeEncoder) -> Self {
        Self { mapping: FastHashMap::default(), inode_encoder }
    }

    /// Iterate over the temporary mapping to build the revision tree,
    /// separating directories and files in two vecs.
    fn to_tree(
        &self,
        ino_to_ref: &mut InoToRef,
        new_inodes: &mut Vec<INodeNo>,
        current_path: &'manifest HgPath,
        parent_buffer: &mut Vec<RevisionTreeRef>,
        dirs: &mut Vec<RevisionTreeDir<'manifest>>,
    ) {
        let mut children = vec![];
        for tree_ref in &self.mapping[current_path] {
            match tree_ref {
                TempMapItem::Dir(child_path) => {
                    assert_ne!(*child_path, current_path);
                    self.to_tree(
                        ino_to_ref,
                        new_inodes,
                        child_path,
                        &mut children,
                        dirs,
                    )
                }
                TempMapItem::File(idx) => {
                    children.push(RevisionTreeRef::File(*idx))
                }
            }
        }
        let inode = if current_path.is_empty() {
            self.inode_encoder.files_root_inode
        } else {
            self.inode_encoder.new_inode()
        };
        dirs.push(RevisionTreeDir {
            inode,
            path: WithBasename::new(current_path),
            children,
        });

        new_inodes.push(inode);
        let dir_ref = RevisionTreeRef::Dir(dirs.len() - 1);
        ino_to_ref.insert(inode, dir_ref);
        parent_buffer.push(dir_ref);
    }
}

/// Represents either a finished pointer to a [`RevisionTreeFile`] or a
/// temporary directory used in [`TempMap`].
#[derive(Clone, Copy, Hash, PartialEq, Eq, Debug)]
enum TempMapItem<'manifest> {
    Dir(&'manifest HgPath),
    File(usize),
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

    #[tracing::instrument(level = "debug", skip_all)]
    fn add_dirstate(
        &mut self,
        dirstate: OwningDirstateMap,
        parents: DirstateParents,
    ) -> Result<(), HgError> {
        let (data, metadata, _, _) =
            dirstate.pack_v2(DirstateMapWriteMode::ForceNewDataFile)?;
        let dirstate_size = u_u64(data.len());
        let uuid = Docket::new_uid();

        // Create the data file
        let data_ino =
            self.add_reserved_file(format!("dirstate.{uuid}"), data.into());

        // Create the docket file
        let docket_data = Docket::serialize(
            parents,
            metadata,
            dirstate_size,
            uuid.as_bytes(),
        )
        .expect("dirstate overflow");

        let docket_ino = self.add_reserved_file("dirstate", docket_data.into());

        // Insert them in .hg
        let dot_hg_entry = self
            .reserved_entries
            .get_mut(&self.dot_hg_ino)
            .expect(".hg node should exist");
        dot_hg_entry.children.push(data_ino);
        dot_hg_entry.children.push(docket_ino);

        Ok(())
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
}

impl InodeEncoder for RevisionInodeEncoder {
    fn new_inode(&self) -> INodeNo {
        let new_inode =
            INodeNo(self.current_ino.fetch_add(1, Ordering::Relaxed));
        assert!(self.available_range.contains(&new_inode), "inode overflow");
        new_inode
    }
}
