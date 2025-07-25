use std::borrow::Cow;
use std::fs::Metadata;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

use bytes_cast::BytesCast;

use super::on_disk;
use super::on_disk::DirstateV2ParseError;
use super::owning::OwningDirstateMap;
use super::path_with_basename::WithBasename;
use super::status::DirstateStatus;
use super::status::StatusError;
use super::status::StatusOptions;
use super::DirstateError;
use super::DirstateMapError;
use crate::dirstate::entry::DirstateEntry;
use crate::dirstate::entry::DirstateV2Data;
use crate::dirstate::entry::ParentFileData;
use crate::dirstate::entry::TruncatedTimestamp;
use crate::dirstate::parsers::pack_entry;
use crate::dirstate::parsers::packed_entry_size;
use crate::dirstate::parsers::parse_dirstate_entries;
use crate::dirstate::CopyMapIter;
use crate::dirstate::StateMapIter;
use crate::matchers::Matcher;
use crate::utils::filter_map_results;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::warnings::HgWarningContext;
use crate::DirstateParents;
use crate::FastHashbrownMap as FastHashMap;

/// Append to an existing data file if the amount of unreachable data (not used
/// anymore) is less than this fraction of the total amount of existing data.
const ACCEPTABLE_UNREACHABLE_BYTES_RATIO: f32 = 0.5;

#[derive(Debug, PartialEq, Eq)]
/// Version of the on-disk format
pub enum DirstateVersion {
    V1,
    V2,
}

#[derive(Debug, PartialEq, Eq)]
pub enum DirstateMapWriteMode {
    Auto,
    ForceNewDataFile,
    ForceAppend,
}

/// Used to detect out-of-process changes in the dirstate
#[derive(Debug, Copy, Clone)]
pub struct DirstateIdentity {
    pub mode: u32,
    pub dev: u64,
    pub ino: u64,
    pub nlink: u64,
    pub uid: u32,
    pub gid: u32,
    pub size: u64,
    pub mtime: i64,
    pub mtime_nsec: i64,
    pub ctime: i64,
    pub ctime_nsec: i64,
}

impl From<Metadata> for DirstateIdentity {
    fn from(value: Metadata) -> Self {
        Self {
            mode: value.mode(),
            dev: value.dev(),
            ino: value.ino(),
            nlink: value.nlink(),
            uid: value.uid(),
            gid: value.gid(),
            size: value.size(),
            mtime: value.mtime(),
            mtime_nsec: value.mtime_nsec(),
            ctime: value.ctime(),
            ctime_nsec: value.ctime_nsec(),
        }
    }
}

impl PartialEq for DirstateIdentity {
    fn eq(&self, other: &Self) -> bool {
        // Some platforms return 0 when they have no support for nanos.
        // This shouldn't be a problem in practice because of how highly
        // unlikely it is that we actually get exactly 0 nanos, and worst
        // case scenario, we don't write out the dirstate in a non-wlocked
        // situation like status.
        let mtime_nanos_equal = (self.mtime_nsec == 0 || other.mtime_nsec == 0)
            || self.mtime_nsec == other.mtime_nsec;
        let ctime_nanos_equal = (self.ctime_nsec == 0 || other.ctime_nsec == 0)
            || self.ctime_nsec == other.ctime_nsec;

        self.mode == other.mode
            && self.dev == other.dev
            && self.ino == other.ino
            && self.nlink == other.nlink
            && self.uid == other.uid
            && self.gid == other.gid
            && self.size == other.size
            && self.mtime == other.mtime
            && mtime_nanos_equal
            && self.ctime == other.ctime
            && ctime_nanos_equal
    }
}

#[derive(Debug)]
pub struct DirstateMap<'on_disk> {
    /// Contents of the `.hg/dirstate` file
    pub(super) on_disk: &'on_disk [u8],

    pub(super) root: ChildNodes<'on_disk>,

    /// Number of nodes anywhere in the tree that have `.entry.is_some()`.
    pub(super) nodes_with_entry_count: u32,

    /// Number of nodes anywhere in the tree that have
    /// `.copy_source.is_some()`.
    pub(super) nodes_with_copy_source_count: u32,

    /// See on_disk::Header
    pub(super) ignore_patterns_hash: on_disk::IgnorePatternsHash,

    /// How many bytes of `on_disk` are not used anymore
    pub(super) unreachable_bytes: u32,

    /// Size of the data used to first load this `DirstateMap`. Used in case
    /// we need to write some new metadata, but no new data on disk,
    /// as well as to detect writes that have happened in another process
    /// since first read.
    pub(super) old_data_size: usize,

    /// UUID used when first loading this `DirstateMap`. Used to check if
    /// the UUID has been changed by another process since first read.
    /// Can be `None` if using dirstate v1 or if it's a brand new dirstate.
    pub(super) old_uuid: Option<Vec<u8>>,

    /// Identity of the dirstate file (for dirstate-v1) or the docket file
    /// (v2). Used to detect if the file has changed from another process.
    /// Since it's always written atomically, we can compare the inode to
    /// check the file identity.
    ///
    /// TODO On non-Unix systems, something like hashing is a possibility?
    pub(super) identity: Option<DirstateIdentity>,

    pub(super) dirstate_version: DirstateVersion,

    /// Controlled by config option `devel.dirstate.v2.data_update_mode`
    pub(super) write_mode: DirstateMapWriteMode,

    /// Controlled by config option `format.use-dirstate-tracked-hint`
    pub(super) use_tracked_hint: bool,
}

/// Using a plain `HgPathBuf` of the full path from the repository root as a
/// map key would also work: all paths in a given map have the same parent
/// path, so comparing full paths gives the same result as comparing base
/// names. However `HashMap` would waste time always re-hashing the same
/// string prefix.
pub(super) type NodeKey<'on_disk> = WithBasename<Cow<'on_disk, HgPath>>;

/// Similar to `&'tree Cow<'on_disk, HgPath>`, but can also be returned
/// for on-disk nodes that don’t actually have a `Cow` to borrow.
#[derive(Debug)]
pub(super) enum BorrowedPath<'tree, 'on_disk> {
    InMemory(&'tree HgPathBuf),
    OnDisk(&'on_disk HgPath),
}

#[derive(Debug)]
pub(super) enum ChildNodes<'on_disk> {
    InMemory(FastHashMap<NodeKey<'on_disk>, Node<'on_disk>>),
    OnDisk(&'on_disk [on_disk::Node]),
}

#[derive(Debug)]
pub(super) enum ChildNodesRef<'tree, 'on_disk> {
    InMemory(&'tree FastHashMap<NodeKey<'on_disk>, Node<'on_disk>>),
    OnDisk(&'on_disk [on_disk::Node]),
}

#[derive(Debug)]
pub(super) enum NodeRef<'tree, 'on_disk> {
    InMemory(&'tree NodeKey<'on_disk>, &'tree Node<'on_disk>),
    OnDisk(&'on_disk on_disk::Node),
}

impl<'on_disk> BorrowedPath<'_, 'on_disk> {
    pub fn detach_from_tree(&self) -> Cow<'on_disk, HgPath> {
        match *self {
            BorrowedPath::InMemory(in_memory) => Cow::Owned(in_memory.clone()),
            BorrowedPath::OnDisk(on_disk) => Cow::Borrowed(on_disk),
        }
    }
}

impl std::ops::Deref for BorrowedPath<'_, '_> {
    type Target = HgPath;

    fn deref(&self) -> &HgPath {
        match *self {
            BorrowedPath::InMemory(in_memory) => in_memory,
            BorrowedPath::OnDisk(on_disk) => on_disk,
        }
    }
}

impl Default for ChildNodes<'_> {
    fn default() -> Self {
        ChildNodes::InMemory(Default::default())
    }
}

impl<'on_disk> ChildNodes<'on_disk> {
    pub(super) fn as_ref<'tree>(&'tree self) -> ChildNodesRef<'tree, 'on_disk> {
        match self {
            ChildNodes::InMemory(nodes) => ChildNodesRef::InMemory(nodes),
            ChildNodes::OnDisk(nodes) => ChildNodesRef::OnDisk(nodes),
        }
    }

    pub(super) fn is_empty(&self) -> bool {
        match self {
            ChildNodes::InMemory(nodes) => nodes.is_empty(),
            ChildNodes::OnDisk(nodes) => nodes.is_empty(),
        }
    }

    fn make_mut(
        &mut self,
        on_disk: &'on_disk [u8],
        unreachable_bytes: &mut u32,
    ) -> Result<
        &mut FastHashMap<NodeKey<'on_disk>, Node<'on_disk>>,
        DirstateV2ParseError,
    > {
        match self {
            ChildNodes::InMemory(nodes) => Ok(nodes),
            ChildNodes::OnDisk(nodes) => {
                *unreachable_bytes +=
                    std::mem::size_of_val::<[on_disk::Node]>(*nodes) as u32;
                let nodes = nodes
                    .iter()
                    .map(|node| {
                        Ok((
                            node.path(on_disk)?,
                            node.to_in_memory_node(on_disk)?,
                        ))
                    })
                    .collect::<Result<_, _>>()?;
                *self = ChildNodes::InMemory(nodes);
                match self {
                    ChildNodes::InMemory(nodes) => Ok(nodes),
                    ChildNodes::OnDisk(_) => unreachable!(),
                }
            }
        }
    }
}

impl<'tree, 'on_disk> ChildNodesRef<'tree, 'on_disk> {
    pub(super) fn get(
        &self,
        base_name: &HgPath,
        on_disk: &'on_disk [u8],
    ) -> Result<Option<NodeRef<'tree, 'on_disk>>, DirstateV2ParseError> {
        match self {
            ChildNodesRef::InMemory(nodes) => Ok(nodes
                .get_key_value(base_name)
                .map(|(k, v)| NodeRef::InMemory(k, v))),
            ChildNodesRef::OnDisk(nodes) => {
                let mut parse_result = Ok(());
                let search_result = nodes.binary_search_by(|node| {
                    match node.base_name(on_disk) {
                        Ok(node_base_name) => node_base_name.cmp(base_name),
                        Err(e) => {
                            parse_result = Err(e);
                            // Dummy comparison result, `search_result` won’t
                            // be used since `parse_result` is an error
                            std::cmp::Ordering::Equal
                        }
                    }
                });
                parse_result.map(|()| {
                    search_result.ok().map(|i| NodeRef::OnDisk(&nodes[i]))
                })
            }
        }
    }

    /// Iterate in undefined order
    pub(super) fn iter(
        &self,
    ) -> impl Iterator<Item = NodeRef<'tree, 'on_disk>> {
        match self {
            ChildNodesRef::InMemory(nodes) => itertools::Either::Left(
                nodes.iter().map(|(k, v)| NodeRef::InMemory(k, v)),
            ),
            ChildNodesRef::OnDisk(nodes) => {
                itertools::Either::Right(nodes.iter().map(NodeRef::OnDisk))
            }
        }
    }

    /// Iterate in parallel in undefined order
    pub(super) fn par_iter(
        &self,
    ) -> impl rayon::iter::ParallelIterator<Item = NodeRef<'tree, 'on_disk>>
    {
        use rayon::prelude::*;
        match self {
            ChildNodesRef::InMemory(nodes) => rayon::iter::Either::Left(
                nodes.par_iter().map(|(k, v)| NodeRef::InMemory(k, v)),
            ),
            ChildNodesRef::OnDisk(nodes) => rayon::iter::Either::Right(
                nodes.par_iter().map(NodeRef::OnDisk),
            ),
        }
    }

    pub(super) fn sorted(&self) -> Vec<NodeRef<'tree, 'on_disk>> {
        match self {
            ChildNodesRef::InMemory(nodes) => {
                let mut vec: Vec<_> = nodes
                    .iter()
                    .map(|(k, v)| NodeRef::InMemory(k, v))
                    .collect();
                fn sort_key<'a>(node: &'a NodeRef) -> &'a HgPath {
                    match node {
                        NodeRef::InMemory(path, _node) => path.base_name(),
                        NodeRef::OnDisk(_) => unreachable!(),
                    }
                }
                // `sort_unstable_by_key` doesn’t allow keys borrowing from the
                // value: https://github.com/rust-lang/rust/issues/34162
                vec.sort_unstable_by(|a, b| sort_key(a).cmp(sort_key(b)));
                vec
            }
            ChildNodesRef::OnDisk(nodes) => {
                // Nodes on disk are already sorted
                nodes.iter().map(NodeRef::OnDisk).collect()
            }
        }
    }
}

impl<'tree, 'on_disk> NodeRef<'tree, 'on_disk> {
    pub(super) fn full_path(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<&'tree HgPath, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(path, _node) => Ok(path.full_path()),
            NodeRef::OnDisk(node) => node.full_path(on_disk),
        }
    }

    /// Returns a `BorrowedPath`, which can be turned into a `Cow<'on_disk,
    /// HgPath>` detached from `'tree`
    pub(super) fn full_path_borrowed(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<BorrowedPath<'tree, 'on_disk>, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(path, _node) => match path.full_path() {
                Cow::Borrowed(on_disk) => Ok(BorrowedPath::OnDisk(on_disk)),
                Cow::Owned(in_memory) => Ok(BorrowedPath::InMemory(in_memory)),
            },
            NodeRef::OnDisk(node) => {
                Ok(BorrowedPath::OnDisk(node.full_path(on_disk)?))
            }
        }
    }

    pub(super) fn base_name(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<&'tree HgPath, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(path, _node) => Ok(path.base_name()),
            NodeRef::OnDisk(node) => node.base_name(on_disk),
        }
    }

    pub(super) fn children(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<ChildNodesRef<'tree, 'on_disk>, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(_path, node) => Ok(node.children.as_ref()),
            NodeRef::OnDisk(node) => {
                Ok(ChildNodesRef::OnDisk(node.children(on_disk)?))
            }
        }
    }

    pub(super) fn has_copy_source(&self) -> bool {
        match self {
            NodeRef::InMemory(_path, node) => node.copy_source.is_some(),
            NodeRef::OnDisk(node) => node.has_copy_source(),
        }
    }

    pub(super) fn copy_source(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<Option<&'tree HgPath>, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(_path, node) => Ok(node.copy_source.as_deref()),
            NodeRef::OnDisk(node) => node.copy_source(on_disk),
        }
    }
    /// Returns a `BorrowedPath`, which can be turned into a `Cow<'on_disk,
    /// HgPath>` detached from `'tree`
    pub(super) fn copy_source_borrowed(
        &self,
        on_disk: &'on_disk [u8],
    ) -> Result<Option<BorrowedPath<'tree, 'on_disk>>, DirstateV2ParseError>
    {
        Ok(match self {
            NodeRef::InMemory(_path, node) => {
                node.copy_source.as_ref().map(|source| match source {
                    Cow::Borrowed(on_disk) => BorrowedPath::OnDisk(on_disk),
                    Cow::Owned(in_memory) => BorrowedPath::InMemory(in_memory),
                })
            }
            NodeRef::OnDisk(node) => {
                node.copy_source(on_disk)?.map(BorrowedPath::OnDisk)
            }
        })
    }

    pub(super) fn entry(
        &self,
    ) -> Result<Option<DirstateEntry>, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(_path, node) => Ok(node.data.as_entry().copied()),
            NodeRef::OnDisk(node) => node.entry(),
        }
    }

    pub(super) fn cached_directory_mtime(
        &self,
    ) -> Result<Option<TruncatedTimestamp>, DirstateV2ParseError> {
        match self {
            NodeRef::InMemory(_path, node) => Ok(match node.data {
                NodeData::CachedDirectory { mtime } => Some(mtime),
                _ => None,
            }),
            NodeRef::OnDisk(node) => node.cached_directory_mtime(),
        }
    }

    pub(super) fn descendants_with_entry_count(&self) -> u32 {
        match self {
            NodeRef::InMemory(_path, node) => node.descendants_with_entry_count,
            NodeRef::OnDisk(node) => node.descendants_with_entry_count.get(),
        }
    }

    pub(super) fn tracked_descendants_count(&self) -> u32 {
        match self {
            NodeRef::InMemory(_path, node) => node.tracked_descendants_count,
            NodeRef::OnDisk(node) => node.tracked_descendants_count.get(),
        }
    }
}

/// Represents a file or a directory
#[derive(Default, Debug)]
pub(super) struct Node<'on_disk> {
    pub(super) data: NodeData,

    pub(super) copy_source: Option<Cow<'on_disk, HgPath>>,

    pub(super) children: ChildNodes<'on_disk>,

    /// How many (non-inclusive) descendants of this node have an entry.
    pub(super) descendants_with_entry_count: u32,

    /// How many (non-inclusive) descendants of this node have an entry whose
    /// state is "tracked".
    pub(super) tracked_descendants_count: u32,
}

#[derive(Debug, Default)]
pub(super) enum NodeData {
    Entry(DirstateEntry),
    CachedDirectory {
        mtime: TruncatedTimestamp,
    },
    #[default]
    None,
}

impl NodeData {
    fn has_entry(&self) -> bool {
        matches!(self, NodeData::Entry(_))
    }

    fn as_entry(&self) -> Option<&DirstateEntry> {
        match self {
            NodeData::Entry(entry) => Some(entry),
            _ => None,
        }
    }

    fn as_entry_mut(&mut self) -> Option<&mut DirstateEntry> {
        match self {
            NodeData::Entry(entry) => Some(entry),
            _ => None,
        }
    }
}

impl<'on_disk> DirstateMap<'on_disk> {
    pub(super) fn empty(on_disk: &'on_disk [u8]) -> Self {
        Self {
            on_disk,
            root: ChildNodes::default(),
            nodes_with_entry_count: 0,
            nodes_with_copy_source_count: 0,
            ignore_patterns_hash: [0; on_disk::IGNORE_PATTERNS_HASH_LEN],
            unreachable_bytes: 0,
            old_data_size: 0,
            old_uuid: None,
            identity: None,
            dirstate_version: DirstateVersion::V1,
            write_mode: DirstateMapWriteMode::Auto,
            use_tracked_hint: false,
        }
    }

    #[tracing::instrument(level = "debug", skip_all)]
    pub fn new_v2(
        on_disk: &'on_disk [u8],
        data_size: usize,
        metadata: &[u8],
        uuid: Vec<u8>,
        identity: Option<DirstateIdentity>,
    ) -> Result<Self, DirstateError> {
        if let Some(data) = on_disk.get(..data_size) {
            Ok(on_disk::read(data, metadata, uuid, identity)?)
        } else {
            Err(DirstateV2ParseError::new("not enough bytes on disk").into())
        }
    }

    #[tracing::instrument(level = "debug", skip_all)]
    pub fn new_v1(
        on_disk: &'on_disk [u8],
        identity: Option<DirstateIdentity>,
    ) -> Result<(Self, Option<DirstateParents>), DirstateError> {
        let mut map = Self::empty(on_disk);
        map.identity = identity;

        if map.on_disk.is_empty() {
            return Ok((map, None));
        }

        let parents =
            parse_dirstate_entries(map.on_disk, |path, entry, copy_source| {
                let tracked = entry.tracked();
                let node = Self::get_or_insert_node_inner(
                    map.on_disk,
                    &mut map.unreachable_bytes,
                    &mut map.root,
                    path,
                    WithBasename::to_cow_borrowed,
                    |ancestor| {
                        if tracked {
                            ancestor.tracked_descendants_count += 1
                        }
                        ancestor.descendants_with_entry_count += 1
                    },
                )?;
                assert!(
                    !node.data.has_entry(),
                    "duplicate dirstate entry in read"
                );
                assert!(
                    node.copy_source.is_none(),
                    "duplicate dirstate entry in read"
                );
                node.data = NodeData::Entry(*entry);
                node.copy_source = copy_source.map(Cow::Borrowed);
                map.nodes_with_entry_count += 1;
                if copy_source.is_some() {
                    map.nodes_with_copy_source_count += 1
                }
                Ok(())
            })?;
        let parents = Some(*parents);

        Ok((map, parents))
    }

    /// Assuming dirstate-v2 format, returns whether the next write should
    /// append to the existing data file that contains `self.on_disk` (true),
    /// or create a new data file from scratch (false).
    pub(super) fn write_should_append(&self) -> bool {
        match self.write_mode {
            DirstateMapWriteMode::ForceAppend => true,
            DirstateMapWriteMode::ForceNewDataFile => false,
            DirstateMapWriteMode::Auto => {
                let ratio =
                    self.unreachable_bytes as f32 / self.on_disk.len() as f32;
                ratio < ACCEPTABLE_UNREACHABLE_BYTES_RATIO
            }
        }
    }

    fn get_node<'tree>(
        &'tree self,
        path: &HgPath,
    ) -> Result<Option<NodeRef<'tree, 'on_disk>>, DirstateV2ParseError> {
        let mut children = self.root.as_ref();
        let mut components = path.components();
        let mut component =
            components.next().expect("expected at least one components");
        loop {
            if let Some(child) = children.get(component, self.on_disk)? {
                if let Some(next_component) = components.next() {
                    component = next_component;
                    children = child.children(self.on_disk)?;
                } else {
                    return Ok(Some(child));
                }
            } else {
                return Ok(None);
            }
        }
    }

    pub fn has_node(
        &self,
        path: &HgPath,
    ) -> Result<bool, DirstateV2ParseError> {
        let node = self.get_node(path)?;
        Ok(node.is_some())
    }

    /// Returns a mutable reference to the node at `path` if it exists
    ///
    /// `each_ancestor` is a callback that is called for each ancestor node
    /// when descending the tree. It is used to keep the different counters
    /// of the `DirstateMap` up-to-date.
    fn get_node_mut<'tree>(
        &'tree mut self,
        path: &HgPath,
        each_ancestor: impl FnMut(&mut Node),
    ) -> Result<Option<&'tree mut Node<'on_disk>>, DirstateV2ParseError> {
        Self::get_node_mut_inner(
            self.on_disk,
            &mut self.unreachable_bytes,
            &mut self.root,
            path,
            each_ancestor,
        )
    }

    /// Lower-level version of `get_node_mut`.
    ///
    /// This takes `root` instead of `&mut self` so that callers can mutate
    /// other fields while the returned borrow is still valid.
    ///
    /// `each_ancestor` is a callback that is called for each ancestor node
    /// when descending the tree. It is used to keep the different counters
    /// of the `DirstateMap` up-to-date.
    fn get_node_mut_inner<'tree>(
        on_disk: &'on_disk [u8],
        unreachable_bytes: &mut u32,
        root: &'tree mut ChildNodes<'on_disk>,
        path: &HgPath,
        mut each_ancestor: impl FnMut(&mut Node),
    ) -> Result<Option<&'tree mut Node<'on_disk>>, DirstateV2ParseError> {
        let mut children = root;
        let mut components = path.components();
        let mut component =
            components.next().expect("expected at least one components");
        loop {
            if let Some(child) = children
                .make_mut(on_disk, unreachable_bytes)?
                .get_mut(component)
            {
                if let Some(next_component) = components.next() {
                    each_ancestor(child);
                    component = next_component;
                    children = &mut child.children;
                } else {
                    return Ok(Some(child));
                }
            } else {
                return Ok(None);
            }
        }
    }

    /// Get a mutable reference to the node at `path`, creating it if it does
    /// not exist.
    ///
    /// `each_ancestor` is a callback that is called for each ancestor node
    /// when descending the tree. It is used to keep the different counters
    /// of the `DirstateMap` up-to-date.
    fn get_or_insert_node<'tree, 'path>(
        &'tree mut self,
        path: &'path HgPath,
        each_ancestor: impl FnMut(&mut Node),
    ) -> Result<&'tree mut Node<'on_disk>, DirstateV2ParseError> {
        Self::get_or_insert_node_inner(
            self.on_disk,
            &mut self.unreachable_bytes,
            &mut self.root,
            path,
            WithBasename::to_cow_owned,
            each_ancestor,
        )
    }

    /// Lower-level version of `get_or_insert_node_inner`, which is used when
    /// parsing disk data to remove allocations for new nodes.
    fn get_or_insert_node_inner<'tree, 'path>(
        on_disk: &'on_disk [u8],
        unreachable_bytes: &mut u32,
        root: &'tree mut ChildNodes<'on_disk>,
        path: &'path HgPath,
        to_cow: impl Fn(
            WithBasename<&'path HgPath>,
        ) -> WithBasename<Cow<'on_disk, HgPath>>,
        mut each_ancestor: impl FnMut(&mut Node),
    ) -> Result<&'tree mut Node<'on_disk>, DirstateV2ParseError> {
        let mut child_nodes = root;
        let mut inclusive_ancestor_paths =
            WithBasename::inclusive_ancestors_of(path);
        let mut ancestor_path = inclusive_ancestor_paths
            .next()
            .expect("expected at least one inclusive ancestor");
        loop {
            let (_, child_node) = child_nodes
                .make_mut(on_disk, unreachable_bytes)?
                .raw_entry_mut()
                .from_key(ancestor_path.base_name())
                .or_insert_with(|| (to_cow(ancestor_path), Node::default()));
            if let Some(next) = inclusive_ancestor_paths.next() {
                each_ancestor(child_node);
                ancestor_path = next;
                child_nodes = &mut child_node.children;
            } else {
                return Ok(child_node);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn reset_state(
        &mut self,
        filename: &HgPath,
        old_entry_opt: Option<DirstateEntry>,
        wc_tracked: bool,
        p1_tracked: bool,
        p2_info: bool,
        has_meaningful_mtime: bool,
        parent_file_data_opt: Option<ParentFileData>,
    ) -> Result<(), DirstateError> {
        let (had_entry, was_tracked) = match old_entry_opt {
            Some(old_entry) => (true, old_entry.tracked()),
            None => (false, false),
        };
        let node = self.get_or_insert_node(filename, |ancestor| {
            if !had_entry {
                ancestor.descendants_with_entry_count += 1;
            }
            if was_tracked {
                if !wc_tracked {
                    ancestor.tracked_descendants_count = ancestor
                        .tracked_descendants_count
                        .checked_sub(1)
                        .expect("tracked count to be >= 0");
                }
            } else if wc_tracked {
                ancestor.tracked_descendants_count += 1;
            }
        })?;

        let v2_data = if let Some(parent_file_data) = parent_file_data_opt {
            DirstateV2Data {
                wc_tracked,
                p1_tracked,
                p2_info,
                mode_size: parent_file_data.mode_size,
                mtime: if has_meaningful_mtime {
                    parent_file_data.mtime
                } else {
                    None
                },
                ..Default::default()
            }
        } else {
            DirstateV2Data {
                wc_tracked,
                p1_tracked,
                p2_info,
                ..Default::default()
            }
        };
        node.data = NodeData::Entry(DirstateEntry::from_v2_data(v2_data));
        if !had_entry {
            self.nodes_with_entry_count += 1;
        }
        Ok(())
    }

    fn set_tracked(
        &mut self,
        filename: &HgPath,
        old_entry_opt: Option<DirstateEntry>,
    ) -> Result<bool, DirstateV2ParseError> {
        let was_tracked = old_entry_opt.is_some_and(|e| e.tracked());
        let had_entry = old_entry_opt.is_some();
        let tracked_count_increment = u32::from(!was_tracked);
        let mut new = false;

        let node = self.get_or_insert_node(filename, |ancestor| {
            if !had_entry {
                ancestor.descendants_with_entry_count += 1;
            }

            ancestor.tracked_descendants_count += tracked_count_increment;
        })?;
        if let Some(old_entry) = old_entry_opt {
            let mut e = old_entry;
            if e.tracked() {
                // XXX
                // This is probably overkill for more case, but we need this to
                // fully replace the `normallookup` call with `set_tracked`
                // one. Consider smoothing this in the future.
                e.set_possibly_dirty();
            } else {
                new = true;
                e.set_tracked();
            }
            node.data = NodeData::Entry(e)
        } else {
            node.data = NodeData::Entry(DirstateEntry::new_tracked());
            self.nodes_with_entry_count += 1;
            new = true;
        };
        Ok(new)
    }

    /// Set a node as untracked in the dirstate.
    ///
    /// It is the responsibility of the caller to remove the copy source and/or
    /// the entry itself if appropriate.
    ///
    /// # Panics
    ///
    /// Panics if the node does not exist.
    fn set_untracked(
        &mut self,
        filename: &HgPath,
        old_entry: DirstateEntry,
    ) -> Result<(), DirstateV2ParseError> {
        let node = self
            .get_node_mut(filename, |ancestor| {
                ancestor.tracked_descendants_count = ancestor
                    .tracked_descendants_count
                    .checked_sub(1)
                    .expect("tracked_descendants_count should be >= 0");
            })?
            .expect("node should exist");
        let mut new_entry = old_entry;
        new_entry.set_untracked();
        node.data = NodeData::Entry(new_entry);
        Ok(())
    }

    /// Set a node as clean in the dirstate.
    ///
    /// It is the responsibility of the caller to remove the copy source.
    ///
    /// # Panics
    ///
    /// Panics if the node does not exist.
    fn set_clean(
        &mut self,
        filename: &HgPath,
        old_entry: DirstateEntry,
        mode: u32,
        size: u32,
        mtime: TruncatedTimestamp,
    ) -> Result<(), DirstateError> {
        let node = self
            .get_node_mut(filename, |ancestor| {
                if !old_entry.tracked() {
                    ancestor.tracked_descendants_count += 1;
                }
            })?
            .expect("node should exist");
        let mut new_entry = old_entry;
        new_entry.set_clean(mode, size, mtime);
        node.data = NodeData::Entry(new_entry);
        Ok(())
    }

    /// Set a node as possibly dirty in the dirstate.
    ///
    /// # Panics
    ///
    /// Panics if the node does not exist.
    fn set_possibly_dirty(
        &mut self,
        filename: &HgPath,
    ) -> Result<(), DirstateError> {
        let node = self
            .get_node_mut(filename, |_ancestor| {})?
            .expect("node should exist");
        let entry = node.data.as_entry_mut().expect("entry should exist");
        entry.set_possibly_dirty();
        node.data = NodeData::Entry(*entry);
        Ok(())
    }

    /// Clears the cached mtime for the (potential) folder at `path`.
    pub(super) fn clear_cached_mtime(
        &mut self,
        path: &HgPath,
    ) -> Result<(), DirstateV2ParseError> {
        let node = match self.get_node_mut(path, |_ancestor| {})? {
            Some(node) => node,
            None => return Ok(()),
        };
        if let NodeData::CachedDirectory { .. } = &node.data {
            node.data = NodeData::None
        }
        Ok(())
    }

    /// Sets the cached mtime for the (potential) folder at `path`.
    pub(super) fn set_cached_mtime(
        &mut self,
        path: &HgPath,
        mtime: TruncatedTimestamp,
    ) -> Result<(), DirstateV2ParseError> {
        let node = match self.get_node_mut(path, |_ancestor| {})? {
            Some(node) => node,
            None => return Ok(()),
        };
        match &node.data {
            NodeData::Entry(_) => {} // Don’t overwrite an entry
            NodeData::CachedDirectory { .. } | NodeData::None => {
                node.data = NodeData::CachedDirectory { mtime }
            }
        }
        Ok(())
    }

    fn iter_nodes<'tree>(
        &'tree self,
    ) -> impl Iterator<
        Item = Result<NodeRef<'tree, 'on_disk>, DirstateV2ParseError>,
    > + 'tree {
        // Depth first tree traversal.
        //
        // If we could afford internal iteration and recursion,
        // this would look like:
        //
        // ```
        // fn traverse_children(
        //     children: &ChildNodes,
        //     each: &mut impl FnMut(&Node),
        // ) {
        //     for child in children.values() {
        //         traverse_children(&child.children, each);
        //         each(child);
        //     }
        // }
        // ```
        //
        // However we want an external iterator and therefore can’t use the
        // call stack. Use an explicit stack instead:
        let mut stack = Vec::new();
        let mut iter = self.root.as_ref().iter();
        std::iter::from_fn(move || {
            while let Some(child_node) = iter.next() {
                let children = match child_node.children(self.on_disk) {
                    Ok(children) => children,
                    Err(error) => return Some(Err(error)),
                };
                // Pseudo-recursion
                let new_iter = children.iter();
                let old_iter = std::mem::replace(&mut iter, new_iter);
                stack.push((child_node, old_iter));
            }
            // Found the end of a `children.iter()` iterator.
            if let Some((child_node, next_iter)) = stack.pop() {
                // "Return" from pseudo-recursion by restoring state from the
                // explicit stack
                iter = next_iter;

                Some(Ok(child_node))
            } else {
                // Reached the bottom of the stack, we’re done
                None
            }
        })
    }

    fn count_dropped_path(unreachable_bytes: &mut u32, path: Cow<HgPath>) {
        if let Cow::Borrowed(path) = path {
            *unreachable_bytes += path.len() as u32
        }
    }

    pub(crate) fn set_write_mode(&mut self, write_mode: DirstateMapWriteMode) {
        self.write_mode = write_mode;
    }

    pub(crate) fn set_tracked_hint(&mut self, tracked_hint: bool) {
        self.use_tracked_hint = tracked_hint;
    }
}

/// Sets the parameters for resetting a dirstate entry
pub struct DirstateEntryReset<'a> {
    /// Which entry are we resetting
    pub filename: &'a HgPath,
    /// Whether the entry is tracked in the working copy
    pub wc_tracked: bool,
    /// Whether the entry is tracked in p1
    pub p1_tracked: bool,
    /// Whether the entry has merge information
    pub p2_info: bool,
    /// Whether the entry's mtime should be trusted
    pub has_meaningful_mtime: bool,
    /// Information from the parent file data (from the manifest)
    pub parent_file_data_opt: Option<ParentFileData>,
    /// Set this to `true` if you are *certain* that there is no old entry for
    /// this filename. Yield better performance in cases where we do a lot
    /// of additions to the dirstate.
    pub from_empty: bool,
}

type DebugDirstateTuple<'a> = (&'a HgPath, (u8, i32, i32, i32));

impl OwningDirstateMap {
    pub fn clear(&mut self) {
        self.with_dmap_mut(|map| {
            map.root = Default::default();
            map.nodes_with_entry_count = 0;
            map.nodes_with_copy_source_count = 0;
            map.unreachable_bytes = map.on_disk.len() as u32;
        });
    }

    pub fn set_tracked(
        &mut self,
        filename: &HgPath,
    ) -> Result<bool, DirstateV2ParseError> {
        let old_entry_opt = self.get(filename)?;
        self.with_dmap_mut(|map| map.set_tracked(filename, old_entry_opt))
    }

    pub fn set_untracked(
        &mut self,
        filename: &HgPath,
    ) -> Result<bool, DirstateError> {
        let old_entry_opt = self.get(filename)?;
        match old_entry_opt {
            None => Ok(false),
            Some(old_entry) => {
                if !old_entry.tracked() {
                    // `DirstateMap::set_untracked` is not a noop if
                    // already not tracked as it will decrement the
                    // tracked counters while going down.
                    return Ok(true);
                }
                if old_entry.added() {
                    // Untracking an "added" entry will just result in a
                    // worthless entry (and other parts of the code will
                    // complain about it), just drop it entirely.
                    self.drop_entry_and_copy_source(filename)?;
                    return Ok(true);
                }
                if !old_entry.p2_info() {
                    self.copy_map_remove(filename)?;
                }

                self.with_dmap_mut(|map| {
                    map.set_untracked(filename, old_entry)?;
                    Ok(true)
                })
            }
        }
    }

    pub fn set_clean(
        &mut self,
        filename: &HgPath,
        mode: u32,
        size: u32,
        mtime: TruncatedTimestamp,
    ) -> Result<(), DirstateError> {
        let old_entry = match self.get(filename)? {
            None => {
                return Err(
                    DirstateMapError::PathNotFound(filename.into()).into()
                )
            }
            Some(e) => e,
        };
        self.copy_map_remove(filename)?;
        self.with_dmap_mut(|map| {
            map.set_clean(filename, old_entry, mode, size, mtime)
        })
    }

    pub fn set_possibly_dirty(
        &mut self,
        filename: &HgPath,
    ) -> Result<(), DirstateError> {
        if self.get(filename)?.is_none() {
            return Err(DirstateMapError::PathNotFound(filename.into()).into());
        }
        self.with_dmap_mut(|map| map.set_possibly_dirty(filename))
    }

    pub fn reset_state(
        &mut self,
        reset: DirstateEntryReset,
    ) -> Result<bool, DirstateError> {
        if !(reset.p1_tracked || reset.p2_info || reset.wc_tracked) {
            self.drop_entry_and_copy_source(reset.filename)?;
            return Ok(false);
        }
        if !reset.from_empty {
            self.copy_map_remove(reset.filename)?;
        }

        let old_entry_opt = if reset.from_empty {
            None
        } else {
            self.get(reset.filename)?
        };

        self.with_dmap_mut(|map| {
            map.reset_state(
                reset.filename,
                old_entry_opt,
                reset.wc_tracked,
                reset.p1_tracked,
                reset.p2_info,
                reset.has_meaningful_mtime,
                reset.parent_file_data_opt,
            )?;
            Ok(old_entry_opt.is_none())
        })
    }

    pub fn drop_entry_and_copy_source(
        &mut self,
        filename: &HgPath,
    ) -> Result<(), DirstateError> {
        let was_tracked = self.get(filename)?.is_some_and(|e| e.tracked());
        struct Dropped {
            was_tracked: bool,
            had_entry: bool,
            had_copy_source: bool,
        }

        /// If this returns `Ok(Some((dropped, removed)))`, then
        ///
        /// * `dropped` is about the leaf node that was at `filename`
        /// * `removed` is whether this particular level of recursion just
        ///   removed a node in `nodes`.
        fn recur<'on_disk>(
            on_disk: &'on_disk [u8],
            unreachable_bytes: &mut u32,
            nodes: &mut ChildNodes<'on_disk>,
            path: &HgPath,
        ) -> Result<Option<(Dropped, bool)>, DirstateV2ParseError> {
            let (first_path_component, rest_of_path) =
                path.split_first_component();
            let nodes = nodes.make_mut(on_disk, unreachable_bytes)?;
            let node = if let Some(node) = nodes.get_mut(first_path_component) {
                node
            } else {
                return Ok(None);
            };
            let dropped;
            if let Some(rest) = rest_of_path {
                if let Some((d, removed)) =
                    recur(on_disk, unreachable_bytes, &mut node.children, rest)?
                {
                    dropped = d;
                    if dropped.had_entry {
                        node.descendants_with_entry_count = node
                            .descendants_with_entry_count
                            .checked_sub(1)
                            .expect(
                                "descendants_with_entry_count should be >= 0",
                            );
                    }
                    if dropped.was_tracked {
                        node.tracked_descendants_count = node
                            .tracked_descendants_count
                            .checked_sub(1)
                            .expect("tracked_descendants_count should be >= 0");
                    }

                    // Directory caches must be invalidated when removing a
                    // child node
                    if removed {
                        if let NodeData::CachedDirectory { .. } = &node.data {
                            node.data = NodeData::None
                        }
                    }
                } else {
                    return Ok(None);
                }
            } else {
                let entry = node.data.as_entry();
                let was_tracked = entry.is_some_and(|entry| entry.tracked());
                let had_entry = entry.is_some();
                if had_entry {
                    node.data = NodeData::None
                }
                let mut had_copy_source = false;
                if let Some(source) = &node.copy_source {
                    DirstateMap::count_dropped_path(
                        unreachable_bytes,
                        Cow::Borrowed(source),
                    );
                    had_copy_source = true;
                    node.copy_source = None
                }
                dropped = Dropped { was_tracked, had_entry, had_copy_source };
            }
            // After recursion, for both leaf (rest_of_path is None) nodes and
            // parent nodes, remove a node if it just became empty.
            let remove = !node.data.has_entry()
                && node.copy_source.is_none()
                && node.children.is_empty();
            if remove {
                let (key, _) =
                    nodes.remove_entry(first_path_component).unwrap();
                DirstateMap::count_dropped_path(
                    unreachable_bytes,
                    Cow::Borrowed(key.full_path()),
                )
            }
            Ok(Some((dropped, remove)))
        }

        self.with_dmap_mut(|map| {
            if let Some((dropped, _removed)) = recur(
                map.on_disk,
                &mut map.unreachable_bytes,
                &mut map.root,
                filename,
            )? {
                if dropped.had_entry {
                    map.nodes_with_entry_count = map
                        .nodes_with_entry_count
                        .checked_sub(1)
                        .expect("nodes_with_entry_count should be >= 0");
                }
                if dropped.had_copy_source {
                    map.nodes_with_copy_source_count = map
                        .nodes_with_copy_source_count
                        .checked_sub(1)
                        .expect("nodes_with_copy_source_count should be >= 0");
                }
            } else {
                debug_assert!(!was_tracked);
            }
            Ok(())
        })
    }

    pub fn has_tracked_dir(
        &mut self,
        directory: &HgPath,
    ) -> Result<bool, DirstateError> {
        self.with_dmap_mut(|map| {
            if let Some(node) = map.get_node(directory)? {
                // A node without a `DirstateEntry` was created to hold child
                // nodes, and is therefore a directory.
                let is_dir = node.entry()?.is_none();
                Ok(is_dir && node.tracked_descendants_count() > 0)
            } else {
                Ok(false)
            }
        })
    }

    pub fn has_dir(
        &mut self,
        directory: &HgPath,
    ) -> Result<bool, DirstateError> {
        self.with_dmap_mut(|map| {
            if let Some(node) = map.get_node(directory)? {
                // A node without a `DirstateEntry` was created to hold child
                // nodes, and is therefore a directory.
                let is_dir = node.entry()?.is_none();
                Ok(is_dir && node.descendants_with_entry_count() > 0)
            } else {
                Ok(false)
            }
        })
    }

    #[tracing::instrument(level = "debug", skip_all)]
    pub fn pack_v1(
        &self,
        parents: DirstateParents,
    ) -> Result<Vec<u8>, DirstateError> {
        let map = self.get_map();
        // Optizimation (to be measured?): pre-compute size to avoid `Vec`
        // reallocations
        let mut size = parents.as_bytes().len();
        for node in map.iter_nodes() {
            let node = node?;
            if node.entry()?.is_some() {
                size += packed_entry_size(
                    node.full_path(map.on_disk)?,
                    node.copy_source(map.on_disk)?,
                );
            }
        }

        let mut packed = Vec::with_capacity(size);
        packed.extend(parents.as_bytes());

        for node in map.iter_nodes() {
            let node = node?;
            if let Some(entry) = node.entry()? {
                pack_entry(
                    node.full_path(map.on_disk)?,
                    &entry,
                    node.copy_source(map.on_disk)?,
                    &mut packed,
                );
            }
        }
        Ok(packed)
    }

    /// Returns new data and metadata together with whether that data should be
    /// appended to the existing data file whose content is at
    /// `map.on_disk` (true), instead of written to a new data file
    /// (false), and the previous size of data on disk.
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn pack_v2(
        &self,
        write_mode: DirstateMapWriteMode,
    ) -> Result<(Vec<u8>, on_disk::TreeMetadata, bool, usize), DirstateError>
    {
        let map = self.get_map();
        on_disk::write(map, write_mode)
    }

    /// `callback` allows the caller to process and do something with the
    /// results of the status. This is needed to do so efficiently (i.e.
    /// without cloning the `DirstateStatus` object with its paths) because
    /// we need to borrow from `Self`.
    pub fn with_status<R, C>(
        &mut self,
        matcher: &impl Matcher,
        root_dir: PathBuf,
        ignore_files: Vec<PathBuf>,
        options: StatusOptions,
        callback: C,
    ) -> R
    where
        C: for<'r> FnOnce(
            Result<DirstateStatus<'r>, StatusError>,
            HgWarningContext,
        ) -> R,
    {
        self.with_dmap_mut(|map| {
            let warnings = HgWarningContext::new();
            callback(
                super::status::status(
                    map,
                    matcher,
                    root_dir,
                    ignore_files,
                    options,
                    warnings.sender(),
                ),
                warnings,
            )
        })
    }

    pub fn copy_map_len(&self) -> usize {
        let map = self.get_map();
        map.nodes_with_copy_source_count as usize
    }

    pub fn copy_map_iter(&self) -> CopyMapIter<'_> {
        let map = self.get_map();
        Box::new(filter_map_results(map.iter_nodes(), move |node| {
            Ok(if let Some(source) = node.copy_source(map.on_disk)? {
                Some((node.full_path(map.on_disk)?, source))
            } else {
                None
            })
        }))
    }

    pub fn copy_map_contains_key(
        &self,
        key: &HgPath,
    ) -> Result<bool, DirstateV2ParseError> {
        let map = self.get_map();
        Ok(if let Some(node) = map.get_node(key)? {
            node.has_copy_source()
        } else {
            false
        })
    }

    pub fn copy_map_get(
        &self,
        key: &HgPath,
    ) -> Result<Option<&HgPath>, DirstateV2ParseError> {
        let map = self.get_map();
        if let Some(node) = map.get_node(key)? {
            if let Some(source) = node.copy_source(map.on_disk)? {
                return Ok(Some(source));
            }
        }
        Ok(None)
    }

    pub fn copy_map_remove(
        &mut self,
        key: &HgPath,
    ) -> Result<Option<HgPathBuf>, DirstateV2ParseError> {
        self.with_dmap_mut(|map| {
            let count = &mut map.nodes_with_copy_source_count;
            let unreachable_bytes = &mut map.unreachable_bytes;
            Ok(DirstateMap::get_node_mut_inner(
                map.on_disk,
                unreachable_bytes,
                &mut map.root,
                key,
                |_ancestor| {},
            )?
            .and_then(|node| {
                if let Some(source) = &node.copy_source {
                    *count = count
                        .checked_sub(1)
                        .expect("nodes_with_copy_source_count should be >= 0");
                    DirstateMap::count_dropped_path(
                        unreachable_bytes,
                        Cow::Borrowed(source),
                    );
                }
                node.copy_source.take().map(Cow::into_owned)
            }))
        })
    }

    pub fn copy_map_insert(
        &mut self,
        key: &HgPath,
        value: &HgPath,
    ) -> Result<Option<HgPathBuf>, DirstateV2ParseError> {
        self.with_dmap_mut(|map| {
            let node = map.get_or_insert_node(key, |_ancestor| {})?;
            let had_copy_source = node.copy_source.is_none();
            let old = node
                .copy_source
                .replace(value.to_owned().into())
                .map(Cow::into_owned);
            if had_copy_source {
                map.nodes_with_copy_source_count += 1
            }
            Ok(old)
        })
    }

    pub fn len(&self) -> usize {
        let map = self.get_map();
        map.nodes_with_entry_count as usize
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn contains_key(
        &self,
        key: &HgPath,
    ) -> Result<bool, DirstateV2ParseError> {
        Ok(self.get(key)?.is_some())
    }

    pub fn get(
        &self,
        key: &HgPath,
    ) -> Result<Option<DirstateEntry>, DirstateV2ParseError> {
        let map = self.get_map();
        Ok(if let Some(node) = map.get_node(key)? {
            node.entry()?
        } else {
            None
        })
    }

    pub fn iter(&self) -> StateMapIter<'_> {
        let map = self.get_map();
        Box::new(filter_map_results(map.iter_nodes(), move |node| {
            Ok(if let Some(entry) = node.entry()? {
                Some((node.full_path(map.on_disk)?, entry))
            } else {
                None
            })
        }))
    }

    pub fn iter_tracked_dirs(
        &mut self,
    ) -> Result<
        Box<
            dyn Iterator<Item = Result<&HgPath, DirstateV2ParseError>>
                + Send
                + '_,
        >,
        DirstateError,
    > {
        let map = self.get_map();
        let on_disk = map.on_disk;
        Ok(Box::new(filter_map_results(map.iter_nodes(), move |node| {
            Ok(if node.tracked_descendants_count() > 0 {
                Some(node.full_path(on_disk)?)
            } else {
                None
            })
        })))
    }

    /// Only public because it needs to be exposed to the Python layer.
    /// It is not the full `setparents` logic, only the parts that mutate the
    /// entries.
    pub fn setparents_fixup(
        &mut self,
    ) -> Result<Vec<(HgPathBuf, HgPathBuf)>, DirstateV2ParseError> {
        // XXX
        // All the copying and re-querying is quite inefficient, but this is
        // still a lot better than doing it from Python.
        //
        // The better solution is to develop a mechanism for `iter_mut`,
        // which will be a lot more involved: we're dealing with a lazy,
        // append-mostly, tree-like data structure. This will do for now.
        let mut copies = vec![];
        let mut files_with_p2_info = vec![];
        for res in self.iter() {
            let (path, entry) = res?;
            if entry.p2_info() {
                files_with_p2_info.push(path.to_owned())
            }
        }
        self.with_dmap_mut(|map| {
            for path in files_with_p2_info.iter() {
                let node = map.get_or_insert_node(path, |_| {})?;
                let entry =
                    node.data.as_entry_mut().expect("entry should exist");
                entry.drop_merge_data();
                if let Some(source) = node.copy_source.take().as_deref() {
                    copies.push((path.to_owned(), source.to_owned()));
                }
            }
            Ok(copies)
        })
    }

    pub fn debug_iter(
        &self,
        all: bool,
    ) -> Box<
        dyn Iterator<Item = Result<DebugDirstateTuple, DirstateV2ParseError>>
            + Send
            + '_,
    > {
        let map = self.get_map();
        Box::new(filter_map_results(map.iter_nodes(), move |node| {
            let debug_tuple = if let Some(entry) = node.entry()? {
                entry.debug_tuple()
            } else if !all {
                return Ok(None);
            } else if let Some(mtime) = node.cached_directory_mtime()? {
                (b' ', 0, -1, mtime.truncated_seconds() as i32)
            } else {
                (b' ', 0, -1, -1)
            };
            Ok(Some((node.full_path(map.on_disk)?, debug_tuple)))
        }))
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    /// Shortcut to return tracked descendants of a path.
    /// Panics if the path does not exist.
    fn tracked_descendants(map: &OwningDirstateMap, path: &[u8]) -> u32 {
        let path = dbg!(HgPath::new(path));
        let node = map.get_map().get_node(path);
        node.unwrap().unwrap().tracked_descendants_count()
    }

    /// Shortcut to return descendants with an entry.
    /// Panics if the path does not exist.
    fn descendants_with_an_entry(map: &OwningDirstateMap, path: &[u8]) -> u32 {
        let path = dbg!(HgPath::new(path));
        let node = map.get_map().get_node(path);
        node.unwrap().unwrap().descendants_with_entry_count()
    }

    fn assert_does_not_exist(map: &OwningDirstateMap, path: &[u8]) {
        let path = dbg!(HgPath::new(path));
        let node = map.get_map().get_node(path);
        assert!(node.unwrap().is_none());
    }

    /// Shortcut for path creation in tests
    fn p(b: &[u8]) -> &HgPath {
        HgPath::new(b)
    }

    /// Test the very simple case a single tracked file
    #[test]
    fn test_tracked_descendants_simple() -> Result<(), DirstateError> {
        let mut map = OwningDirstateMap::new_empty(vec![], None);
        assert_eq!(map.len(), 0);

        map.set_tracked(p(b"some/nested/path"))?;

        assert_eq!(map.len(), 1);
        assert_eq!(tracked_descendants(&map, b"some"), 1);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/nested/path"), 0);

        map.set_untracked(p(b"some/nested/path"))?;
        assert_eq!(map.len(), 0);
        assert!(map.get_map().get_node(p(b"some"))?.is_none());

        Ok(())
    }

    /// Test the simple case of all tracked, but multiple files
    #[test]
    fn test_tracked_descendants_multiple() -> Result<(), DirstateError> {
        let mut map = OwningDirstateMap::new_empty(vec![], None);

        map.set_tracked(p(b"some/nested/path"))?;
        map.set_tracked(p(b"some/nested/file"))?;
        // one layer without any files to test deletion cascade
        map.set_tracked(p(b"some/other/nested/path"))?;
        map.set_tracked(p(b"root_file"))?;
        map.set_tracked(p(b"some/file"))?;
        map.set_tracked(p(b"some/file2"))?;
        map.set_tracked(p(b"some/file3"))?;

        assert_eq!(map.len(), 7);
        assert_eq!(tracked_descendants(&map, b"some"), 6);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 2);
        assert_eq!(tracked_descendants(&map, b"some/other"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/nested/path"), 0);

        map.set_untracked(p(b"some/nested/path"))?;
        assert_eq!(map.len(), 6);
        assert_eq!(tracked_descendants(&map, b"some"), 5);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other/nested"), 1);

        map.set_untracked(p(b"some/nested/file"))?;
        assert_eq!(map.len(), 5);
        assert_eq!(tracked_descendants(&map, b"some"), 4);
        assert_eq!(tracked_descendants(&map, b"some/other"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other/nested"), 1);
        assert_does_not_exist(&map, b"some_nested");

        map.set_untracked(p(b"some/other/nested/path"))?;
        assert_eq!(map.len(), 4);
        assert_eq!(tracked_descendants(&map, b"some"), 3);
        assert_does_not_exist(&map, b"some/other");

        map.set_untracked(p(b"root_file"))?;
        assert_eq!(map.len(), 3);
        assert_eq!(tracked_descendants(&map, b"some"), 3);
        assert_does_not_exist(&map, b"root_file");

        map.set_untracked(p(b"some/file"))?;
        assert_eq!(map.len(), 2);
        assert_eq!(tracked_descendants(&map, b"some"), 2);
        assert_does_not_exist(&map, b"some/file");

        map.set_untracked(p(b"some/file2"))?;
        assert_eq!(map.len(), 1);
        assert_eq!(tracked_descendants(&map, b"some"), 1);
        assert_does_not_exist(&map, b"some/file2");

        map.set_untracked(p(b"some/file3"))?;
        assert_eq!(map.len(), 0);
        assert_does_not_exist(&map, b"some/file3");

        Ok(())
    }

    /// Check with a mix of tracked and non-tracked items
    #[test]
    fn test_tracked_descendants_different() -> Result<(), DirstateError> {
        let mut map = OwningDirstateMap::new_empty(vec![], None);

        // A file that was just added
        map.set_tracked(p(b"some/nested/path"))?;
        // This has no information, the dirstate should ignore it
        let reset = DirstateEntryReset {
            filename: p(b"some/file"),
            wc_tracked: false,
            p1_tracked: false,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert_does_not_exist(&map, b"some/file");

        // A file that was removed
        let reset = DirstateEntryReset {
            filename: p(b"some/nested/file"),
            wc_tracked: false,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert!(!map.get(p(b"some/nested/file"))?.unwrap().tracked());
        // Only present in p2
        let reset = DirstateEntryReset {
            filename: p(b"some/file3"),
            wc_tracked: false,
            p1_tracked: false,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert!(!map.get(p(b"some/file3"))?.unwrap().tracked());
        // A file that was merged
        let reset = DirstateEntryReset {
            filename: p(b"root_file"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert!(map.get(p(b"root_file"))?.unwrap().tracked());
        // A file that is added, with info from p2
        // XXX is that actually possible?
        let reset = DirstateEntryReset {
            filename: p(b"some/file2"),
            wc_tracked: true,
            p1_tracked: false,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert!(map.get(p(b"some/file2"))?.unwrap().tracked());
        // A clean file
        // One layer without any files to test deletion cascade
        let reset = DirstateEntryReset {
            filename: p(b"some/other/nested/path"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        assert!(map.get(p(b"some/other/nested/path"))?.unwrap().tracked());

        assert_eq!(map.len(), 6);
        assert_eq!(tracked_descendants(&map, b"some"), 3);
        assert_eq!(descendants_with_an_entry(&map, b"some"), 5);
        assert_eq!(tracked_descendants(&map, b"some/other/nested"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/other/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other/nested/path"), 0);
        assert_eq!(
            descendants_with_an_entry(&map, b"some/other/nested/path"),
            0
        );
        assert_eq!(tracked_descendants(&map, b"some/nested"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/nested"), 2);

        // might as well check this
        map.set_untracked(p(b"path/does/not/exist"))?;
        assert_eq!(map.len(), 6);

        map.set_untracked(p(b"some/other/nested/path"))?;
        // It is set untracked but not deleted since it held other information
        assert_eq!(map.len(), 6);
        assert_eq!(tracked_descendants(&map, b"some"), 2);
        assert_eq!(descendants_with_an_entry(&map, b"some"), 5);
        assert_eq!(descendants_with_an_entry(&map, b"some/other"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/other/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/nested"), 2);

        map.set_untracked(p(b"some/nested/path"))?;
        // It is set untracked *and* deleted since it was only added
        assert_eq!(map.len(), 5);
        assert_eq!(tracked_descendants(&map, b"some"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some"), 4);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 0);
        assert_eq!(descendants_with_an_entry(&map, b"some/nested"), 1);
        assert_does_not_exist(&map, b"some/nested/path");

        map.set_untracked(p(b"root_file"))?;
        // Untracked but not deleted
        assert_eq!(map.len(), 5);
        assert!(map.get(p(b"root_file"))?.is_some());

        map.set_untracked(p(b"some/file2"))?;
        assert_eq!(map.len(), 5);
        assert_eq!(tracked_descendants(&map, b"some"), 0);
        assert!(map.get(p(b"some/file2"))?.is_some());

        map.set_untracked(p(b"some/file3"))?;
        assert_eq!(map.len(), 5);
        assert_eq!(tracked_descendants(&map, b"some"), 0);
        assert!(map.get(p(b"some/file3"))?.is_some());

        Ok(())
    }

    /// Check that copies counter is correctly updated
    #[test]
    fn test_copy_source() -> Result<(), DirstateError> {
        let mut map = OwningDirstateMap::new_empty(vec![], None);

        // Clean file
        let reset = DirstateEntryReset {
            filename: p(b"files/clean"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // Merged file
        let reset = DirstateEntryReset {
            filename: p(b"files/from_p2"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // Removed file
        let reset = DirstateEntryReset {
            filename: p(b"removed"),
            wc_tracked: false,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // Added file
        let reset = DirstateEntryReset {
            filename: p(b"files/added"),
            wc_tracked: true,
            p1_tracked: false,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // Add copy
        map.copy_map_insert(p(b"files/clean"), p(b"clean_copy_source"))?;
        assert_eq!(map.copy_map_len(), 1);

        // Copy override
        map.copy_map_insert(p(b"files/clean"), p(b"other_clean_copy_source"))?;
        assert_eq!(map.copy_map_len(), 1);

        // Multiple copies
        map.copy_map_insert(p(b"removed"), p(b"removed_copy_source"))?;
        assert_eq!(map.copy_map_len(), 2);

        map.copy_map_insert(p(b"files/added"), p(b"added_copy_source"))?;
        assert_eq!(map.copy_map_len(), 3);

        // Added, so the entry is completely removed
        map.set_untracked(p(b"files/added"))?;
        assert_does_not_exist(&map, b"files/added");
        assert_eq!(map.copy_map_len(), 2);

        // Removed, so the entry is kept around, so is its copy
        map.set_untracked(p(b"removed"))?;
        assert!(map.get(p(b"removed"))?.is_some());
        assert_eq!(map.copy_map_len(), 2);

        // Clean, so the entry is kept around, but not its copy
        map.set_untracked(p(b"files/clean"))?;
        assert!(map.get(p(b"files/clean"))?.is_some());
        assert_eq!(map.copy_map_len(), 1);

        map.copy_map_insert(p(b"files/from_p2"), p(b"from_p2_copy_source"))?;
        assert_eq!(map.copy_map_len(), 2);

        // Info from p2, so its copy source info is kept around
        map.set_untracked(p(b"files/from_p2"))?;
        assert!(map.get(p(b"files/from_p2"))?.is_some());
        assert_eq!(map.copy_map_len(), 2);

        Ok(())
    }

    /// Test with "on disk" data. For the sake of this test, the "on disk" data
    /// does not actually come from the disk, but it's opaque to the code being
    /// tested.
    #[test]
    fn test_on_disk() -> Result<(), DirstateError> {
        // First let's create some data to put "on disk"
        let mut map = OwningDirstateMap::new_empty(vec![], None);

        // A file that was just added
        map.set_tracked(p(b"some/nested/added"))?;
        map.copy_map_insert(p(b"some/nested/added"), p(b"added_copy_source"))?;

        // A file that was removed
        let reset = DirstateEntryReset {
            filename: p(b"some/nested/removed"),
            wc_tracked: false,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // Only present in p2
        let reset = DirstateEntryReset {
            filename: p(b"other/p2_info_only"),
            wc_tracked: false,
            p1_tracked: false,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        map.copy_map_insert(
            p(b"other/p2_info_only"),
            p(b"other/p2_info_copy_source"),
        )?;
        // A file that was merged
        let reset = DirstateEntryReset {
            filename: p(b"merged"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // A file that is added, with info from p2
        // XXX is that actually possible?
        let reset = DirstateEntryReset {
            filename: p(b"other/added_with_p2"),
            wc_tracked: true,
            p1_tracked: false,
            p2_info: true,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;
        // One layer without any files to test deletion cascade
        // A clean file
        let reset = DirstateEntryReset {
            filename: p(b"some/other/nested/clean"),
            wc_tracked: true,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime: false,
            parent_file_data_opt: None,
            from_empty: false,
        };
        map.reset_state(reset)?;

        let (packed, metadata, _should_append, _old_data_size) =
            map.pack_v2(DirstateMapWriteMode::ForceNewDataFile)?;
        let packed_len = packed.len();
        assert!(packed_len > 0);

        // Recreate "from disk"
        let mut map = OwningDirstateMap::new_v2(
            packed,
            packed_len,
            metadata.as_bytes(),
            vec![],
            None,
        )?;

        // Check that everything is accounted for
        assert!(map.contains_key(p(b"some/nested/added"))?);
        assert!(map.contains_key(p(b"some/nested/removed"))?);
        assert!(map.contains_key(p(b"merged"))?);
        assert!(map.contains_key(p(b"other/p2_info_only"))?);
        assert!(map.contains_key(p(b"other/added_with_p2"))?);
        assert!(map.contains_key(p(b"some/other/nested/clean"))?);
        assert_eq!(
            map.copy_map_get(p(b"some/nested/added"))?,
            Some(p(b"added_copy_source"))
        );
        assert_eq!(
            map.copy_map_get(p(b"other/p2_info_only"))?,
            Some(p(b"other/p2_info_copy_source"))
        );
        assert_eq!(tracked_descendants(&map, b"some"), 2);
        assert_eq!(descendants_with_an_entry(&map, b"some"), 3);
        assert_eq!(tracked_descendants(&map, b"other"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"other"), 2);
        assert_eq!(tracked_descendants(&map, b"some/other"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/other"), 1);
        assert_eq!(tracked_descendants(&map, b"some/other/nested"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/other/nested"), 1);
        assert_eq!(tracked_descendants(&map, b"some/nested"), 1);
        assert_eq!(descendants_with_an_entry(&map, b"some/nested"), 2);
        assert_eq!(map.len(), 6);
        assert_eq!(map.get_map().unreachable_bytes, 0);
        assert_eq!(map.copy_map_len(), 2);

        // Shouldn't change anything since it's already not tracked
        map.set_untracked(p(b"some/nested/removed"))?;
        assert_eq!(map.get_map().unreachable_bytes, 0);

        if let ChildNodes::InMemory(_) = map.get_map().root {
            panic!("root should not have been mutated")
        }
        // We haven't mutated enough (nothing, actually), we should still be in
        // the append strategy
        assert!(map.get_map().write_should_append());

        // But this mutates the structure, so there should be unreachable_bytes
        assert!(map.set_untracked(p(b"some/nested/added"))?);
        let unreachable_bytes = map.get_map().unreachable_bytes;
        assert!(unreachable_bytes > 0);

        if let ChildNodes::OnDisk(_) = map.get_map().root {
            panic!("root should have been mutated")
        }

        // This should not mutate the structure either, since `root` has
        // already been mutated along with its direct children.
        map.set_untracked(p(b"merged"))?;
        assert_eq!(map.get_map().unreachable_bytes, unreachable_bytes);

        if let NodeRef::InMemory(_, _) =
            map.get_map().get_node(p(b"other/added_with_p2"))?.unwrap()
        {
            panic!("'other/added_with_p2' should not have been mutated")
        }
        // But this should, since it's in a different path
        // than `<root>some/nested/add`
        map.set_untracked(p(b"other/added_with_p2"))?;
        assert!(map.get_map().unreachable_bytes > unreachable_bytes);

        if let NodeRef::OnDisk(_) =
            map.get_map().get_node(p(b"other/added_with_p2"))?.unwrap()
        {
            panic!("'other/added_with_p2' should have been mutated")
        }

        // We have rewritten most of the tree, we should create a new file
        assert!(!map.get_map().write_should_append());

        Ok(())
    }
}
