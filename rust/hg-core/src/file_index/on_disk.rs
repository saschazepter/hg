//! This module presents a read-only view of the file index from its on-disk
//! representation, which consists of four files:
//!
//! * `.hg/store/fileindex`: the docket file
//! * `.hg/store/fileindex-list.{ID1}`: the list file
//! * `.hg/store/fileindex-meta.{ID2}`: the meta file
//! * `.hg/store/fileindex-tree.{ID3}`: the tree file
//!
//! See `mercurial/helptext/internals/file-index.txt` for more details.

use std::ops::Deref;
use std::path::Path;
use std::path::PathBuf;

use bitflags::bitflags;
use bytes_cast::unaligned::U16Be;
use bytes_cast::unaligned::U32Be;
use bytes_cast::BytesCast;
use self_cell::self_cell;

use super::FileToken;
use crate::utils::docket::FileUid;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::SliceExt as _;
use crate::utils::u16_u;
use crate::utils::u32_u;
use crate::utils::u_u16;
use crate::utils::u_u32;

/// Error type for file index corruption.
#[derive(Debug, PartialEq)]
pub enum Error {
    BadFormatMarker,
    DocketFileEof,
    DataFileTooSmall,
    BadMetaFilesize,
    EmptySpan,
    ListFileOutOfBounds,
    TreeFileOutOfBounds,
    TreeFileEof,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::BadFormatMarker => {
                write!(f, "unrecognized format marker in docket")
            }
            Error::DocketFileEof => {
                write!(f, "unexpected EOF while reading docket file")
            }
            Error::DataFileTooSmall => {
                write!(f, "file is smaller than its 'used size' docket field")
            }
            Error::BadMetaFilesize => {
                write!(f, "meta file 'used size' is not a multiple of the record size")
            }
            Error::EmptySpan => {
                write!(f, "reference to substring of list file has zero length")
            }
            Error::ListFileOutOfBounds => {
                write!(f, "list file access out of bounds")
            }
            Error::TreeFileOutOfBounds => {
                write!(f, "tree file access out of bounds")
            }
            Error::TreeFileEof => {
                write!(f, "unexpected EOF while parsing tree file")
            }
        }
    }
}

impl From<Error> for crate::errors::HgError {
    fn from(err: Error) -> Self {
        Self::corrupted(format!("corrupted fileindex: {err}"))
    }
}

/// The contents of the docket file.
pub struct Docket {
    pub header: DocketHeader,
    pub garbage_entries: Vec<GarbageEntry>,
}

impl Docket {
    /// Reads a [`Docket`] from bytes.
    pub fn read(on_disk: &[u8]) -> Result<Self, Error> {
        let (header, rest) =
            DocketHeader::from_bytes(on_disk).or(Err(Error::DocketFileEof))?;
        if header.marker != *FORMAT_MARKER {
            return Err(Error::BadFormatMarker);
        }
        let (garbage_entries, _rest) = parse_garbage_list(rest)?;
        Ok(Docket { header: header.clone(), garbage_entries })
    }

    /// Serializes the docket to bytes.
    pub fn serialize(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(self.header.as_bytes());
        serialize_garbage_list(&self.garbage_entries, &mut bytes);
        bytes
    }

    /// Returns the path to the docket, relative to the store.
    pub fn path() -> &'static Path {
        Path::new("fileindex")
    }

    /// Returns the path to the pending docket, relative to the store.
    pub fn pending_path() -> &'static Path {
        Path::new("fileindex.pending")
    }

    /// Returns the path to the list file, if there is one.
    pub fn list_file_path(&self) -> Option<PathBuf> {
        Self::data_file_path("fileindex-list", self.header.list_file_id)
    }

    /// Returns the path to the meta file, if there is one.
    pub fn meta_file_path(&self) -> Option<PathBuf> {
        Self::data_file_path("fileindex-meta", self.header.meta_file_id)
    }

    /// Returns the path to the tree file, if there is one.
    pub fn tree_file_path(&self) -> Option<PathBuf> {
        Self::data_file_path("fileindex-tree", self.header.tree_file_id)
    }

    fn data_file_path(name: &str, id: FileUid) -> Option<PathBuf> {
        id.none_if_unset().map(|id| format!("{}.{}", name, id.as_str()).into())
    }
}

/// Added at the start of the docket file. This a redundant sanity check more
/// than an actual "magic number" since `.hg/store/requires` already governs
/// which format should be used.
pub(super) const FORMAT_MARKER: &[u8; 12] = b"fileindex-v1";

/// The contents of the docket file.
#[derive(BytesCast, Clone)]
#[repr(C)]
pub struct DocketHeader {
    /// Should contain [`FORMAT_MARKER`].
    pub marker: [u8; FORMAT_MARKER.len()],
    /// Used size of the list file in bytes.
    pub list_file_size: U32Be,
    /// Reserved for future use.
    pub reserved_revlog_size: U32Be,
    /// Used size of the meta file in bytes.
    pub meta_file_size: U32Be,
    /// Used size of tree file in bytes.
    pub tree_file_size: U32Be,
    /// List file path ID.
    pub list_file_id: FileUid,
    /// Reserved for future use.
    pub reserved_revlog_id: FileUid,
    /// Meta file path ID.
    pub meta_file_id: FileUid,
    /// Tree file path ID.
    pub tree_file_id: FileUid,
    /// Pseudo-pointer to the root node in the tree file.
    pub tree_root_pointer: U32Be,
    /// Number of unused bytes within [`Self::tree_file_size`].
    pub tree_unused_bytes: U32Be,
    /// Reserved for future use.
    pub reserved_revlog_unused: U32Be,
    /// Currently unused. Reset to zero when writing the docket.
    pub reserved_flags: [u8; 4],
}

impl Default for Docket {
    fn default() -> Self {
        Self {
            header: DocketHeader {
                marker: *FORMAT_MARKER,
                list_file_size: 0.into(),
                reserved_revlog_size: 0.into(),
                meta_file_size: 0.into(),
                tree_file_size: 0.into(),
                list_file_id: FileUid::unset(),
                reserved_revlog_id: FileUid::unset(),
                meta_file_id: FileUid::unset(),
                tree_file_id: FileUid::unset(),
                tree_root_pointer: 0.into(),
                tree_unused_bytes: 0.into(),
                reserved_revlog_unused: 0.into(),
                reserved_flags: [0; 4],
            },
            garbage_entries: Vec::new(),
        }
    }
}

/// The garbage list parsed from the [`Docket`]. It consists of a
/// [`GarbageListHeader`], an array of [`GarbageIndexEntry`], and a buffer of
/// paths that the index entries point into.
fn parse_garbage_list(
    bytes: &[u8],
) -> Result<(Vec<GarbageEntry>, &[u8]), Error> {
    let (header, rest) =
        GarbageListHeader::from_bytes(bytes).or(Err(Error::DocketFileEof))?;
    let num_entries = u32_u(header.num_entries.get());
    let (index_entries, rest) =
        GarbageIndexEntry::slice_from_bytes(rest, num_entries)
            .or(Err(Error::DocketFileEof))?;
    let (path_buf, rest) = rest
        .split_at_checked(u32_u(header.path_buf_size.get()))
        .ok_or(Error::DocketFileEof)?;
    let entries = index_entries
        .iter()
        .map(|entry| GarbageEntry::from_index(entry, path_buf))
        .collect();
    Ok((entries, rest))
}

/// Serializes garbage entries. Inverse of [`parse_garbage_list`].
fn serialize_garbage_list(entries: &[GarbageEntry], out: &mut Vec<u8>) {
    let mut path_buf = Vec::new();
    for entry in entries {
        let path = entry.path.as_os_str().as_encoded_bytes();
        path_buf.extend_from_slice(path);
        path_buf.push(b'\x00');
    }
    let header = GarbageListHeader {
        num_entries: u_u32(entries.len()).into(),
        path_buf_size: u_u32(path_buf.len()).into(),
    };
    out.extend_from_slice(header.as_bytes());
    let mut offset = 0;
    for entry in entries {
        out.extend_from_slice(entry.to_index(offset).as_bytes());
        offset += u_u32(entry.path.as_os_str().len()) + 1;
    }
    out.extend_from_slice(&path_buf);
}

/// Header of the garbage list in the [`Docket`].
#[derive(BytesCast)]
#[repr(C)]
struct GarbageListHeader {
    /// Number of entries in the list.
    num_entries: U32Be,
    /// Size of the path buffer that the entries point into.
    path_buf_size: U32Be,
}

/// An entry in the garbage list index in the [`Docket`].
#[derive(BytesCast)]
#[repr(C)]
struct GarbageIndexEntry {
    ttl: U16Be,
    timestamp: U32Be,
    path_offset: U32Be,
    path_length: U16Be,
}

/// An entry parsed from the garbage list in the [`Docket`].
pub struct GarbageEntry {
    /// Time-to-live (TTL), decremented by each transaction.
    /// The file will not be deleted until it reaches zero.
    pub ttl: u16,
    /// Time when this entry was added.
    pub timestamp: u32,
    /// Path to the file to be deleted.
    pub path: PathBuf,
}

impl GarbageEntry {
    /// Creates a [`GarbageEntry`] given its index entry and the path buffer.
    fn from_index(entry: &GarbageIndexEntry, path_buf: &[u8]) -> Self {
        let offset = u32_u(entry.path_offset.get());
        let length = u16_u(entry.path_length.get());
        Self {
            ttl: entry.ttl.get(),
            timestamp: entry.timestamp.get(),
            path: std::str::from_utf8(&path_buf[offset..offset + length])
                .expect("garbage entry path should be valid UTF-8")
                .into(),
        }
    }

    /// Converts this [`GarbageEntry`] back to a [`GarbageIndexEntry`].
    fn to_index(&self, path_offset: u32) -> GarbageIndexEntry {
        GarbageIndexEntry {
            ttl: self.ttl.into(),
            timestamp: self.timestamp.into(),
            path_offset: path_offset.into(),
            path_length: u_u16(self.path.as_os_str().len()).into(),
        }
    }
}

/// Metadata for a token in the meta file.
#[derive(Copy, Clone, BytesCast)]
#[repr(C)]
pub(super) struct Metadata {
    /// Pseudo-pointer to the start of the path in the list file.
    pub(super) offset: U32Be,
    /// Length of the path.
    pub(super) length: U16Be,
    /// Length of the path's dirname prefix, or 0 if there is no slash.
    pub(super) dirname_length: U16Be,
}

impl Metadata {
    /// Creates metadata for `path` stored at `offset` in the list file.
    pub(super) fn new(path: &HgPath, offset: u32) -> Self {
        let path_len: u16 =
            path.len().try_into().expect("path len should fit in u16");
        let dirname_len = path.bytes().rposition(|c| *c == b'/').unwrap_or(0);
        let dirname_len: u16 =
            dirname_len.try_into().expect("dirname len should fit in u16");
        Self {
            offset: offset.into(),
            length: path_len.into(),
            dirname_length: dirname_len.into(),
        }
    }

    /// Returns the token's path as a [`Span`].
    pub(super) fn path(&self) -> Span {
        Span { offset: self.offset.get(), length: self.length.get() }
    }
}

/// Information about a token's path.
/// Parsed from [`Metadata`] and resolved to a pointer into the list file.
pub struct PathInfo<'on_disk> {
    path: &'on_disk [u8],
    dirname_length: usize,
}

impl<'a> PathInfo<'a> {
    /// Returns this token's path.
    pub fn path(&self) -> &'a HgPath {
        HgPath::new(self.path)
    }

    /// Returns the dirname for this token (the prefix up to but not including
    /// the final slash), or None if there is no slash.
    pub fn dirname(&self) -> Option<&'a [u8]> {
        match self.dirname_length {
            0 => None,
            _ => Some(&self.path[..self.dirname_length]),
        }
    }

    /// Returns the basename for this token (the suffix after the final slash,
    /// or the whole path is there is no slash).
    pub fn basename(&self) -> &'a [u8] {
        match self.dirname_length {
            0 => self.path,
            _ => &self.path[self.dirname_length + 1..],
        }
    }
}

/// A reference to a string in the list file.
pub(super) struct Span {
    offset: u32,
    length: u16,
}

/// A node parsed from the tree file.
#[derive(Debug, Copy, Clone)]
pub(super) struct TreeNode<'on_disk> {
    /// Token for this node, if it represents a path in the file index.
    pub(super) token: Option<FileToken>,
    /// Edges pointing to children of this node.
    pub(super) edges: &'on_disk [TreeEdge],
}

impl TreeNode<'_> {
    /// Returns a root node for an empty tree.
    fn empty_root() -> Self {
        Self { token: None, edges: &[] }
    }
}

/// A node header in the tree file.
#[derive(Debug, BytesCast, Copy, Clone)]
#[repr(C)]
pub(super) struct TreeNodeHeader {
    /// Flag byte for [`TreeNodeFlags`].
    flags: u8,
    /// Number of [`TreeEdge`] values that follow.
    pub(super) num_children: u8,
}

impl TreeNodeHeader {
    pub(super) fn new(flags: TreeNodeFlags, num_children: u8) -> Self {
        Self { flags: flags.bits(), num_children }
    }

    pub(super) fn flags(&self) -> TreeNodeFlags {
        TreeNodeFlags::from_bits_truncate(self.flags)
    }
}

bitflags! {
    /// Tree node flags.
    #[derive(Debug, Copy, Clone)]
    #[repr(C)]
    pub(super) struct TreeNodeFlags : u8 {
        /// If set, the [`TreeNodeHeader`] is followed by a [`U32Be`] token.
        const HAS_TOKEN = 1 << 0;
    }
}

/// An edge in the tree file.
#[derive(Debug, BytesCast, Copy, Clone)]
#[repr(C)]
pub(super) struct TreeEdge {
    /// Pseudo-pointer to the start of this edge's label in the list file.
    pub(super) label_offset: U32Be,
    /// Length of this edge's label.
    pub(super) label_length: U16Be,
    /// Pseudo-pointer to the child node in the tree file.
    pub(super) node_pointer: NodePointerBe,
}

/// Pseudo-pointer to a node in the tree file.
pub(super) type NodePointer = u32;
/// Big-endian version of [`NodePointer`].
pub(super) type NodePointerBe = U32Be;

impl TreeEdge {
    /// Returns the edge's label as as [`Span`].
    pub(super) fn label(&self) -> Span {
        Span {
            offset: self.label_offset.get(),
            length: self.label_length.get(),
        }
    }
}

/// Data files for creating a [`FileIndexView`].
struct DataFiles<'on_disk> {
    list_file: &'on_disk [u8],
    meta_file: &'on_disk [u8],
    tree_file: &'on_disk [u8],
}

/// Owned version of [`DataFiles`].
pub(super) struct OwnedDataFiles {
    pub(super) list_file: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    pub(super) meta_file: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    pub(super) tree_file: Box<dyn Deref<Target = [u8]> + Send + Sync>,
}

/// Read-only view of the file index.
#[derive(Copy, Clone)]
pub struct FileIndexView<'on_disk> {
    /// Contents of the list file.
    pub(super) list_file: &'on_disk [u8],
    /// Contents of the meta file, cast to a slice of [`Metadata`].
    pub(super) meta_array: &'on_disk [Metadata],
    /// Contents of the tree file.
    pub(super) tree_file: &'on_disk [u8],
    /// Value of [`DocketHeader::tree_root_pointer`].
    pub(super) tree_root_pointer: NodePointer,
    /// Value of [`DocketHeader::tree_unused_bytes`].
    pub(super) tree_unused_bytes: u32,
    /// Root node of the prefix tree.
    pub(super) root: TreeNode<'on_disk>,
}

self_cell!(
    /// A wrapper around [`FileIndexView`] that owns the data.
    pub(super) struct OwnedFileIndexView {
        owner: OwnedDataFiles,
        #[covariant]
        dependent: FileIndexView,
    }
);

impl OwnedFileIndexView {
    pub fn open(docket: &Docket, files: OwnedDataFiles) -> Result<Self, Error> {
        Self::try_new(files, |files| {
            FileIndexView::open(
                docket,
                DataFiles {
                    list_file: &files.list_file,
                    meta_file: &files.meta_file,
                    tree_file: &files.tree_file,
                },
            )
        })
    }
}

impl<'on_disk> FileIndexView<'on_disk> {
    /// Returns a view of an empty file index.
    pub(super) fn empty() -> Self {
        Self {
            list_file: b"",
            meta_array: &[],
            tree_file: b"",
            tree_root_pointer: 0,
            tree_unused_bytes: 0,
            root: TreeNode::empty_root(),
        }
    }

    /// Creates a file index given a docket and file contents. It will only
    /// read file contents up to the "used sizes" stored in the docket.
    fn open(
        docket: &Docket,
        files: DataFiles<'on_disk>,
    ) -> Result<Self, Error> {
        let limit = |bytes: &'on_disk [u8], size: U32Be| {
            bytes.get(..u32_u(size.get())).ok_or(Error::DataFileTooSmall)
        };
        let list_file = limit(files.list_file, docket.header.list_file_size)?;
        let meta_file = limit(files.meta_file, docket.header.meta_file_size)?;
        let tree_file = limit(files.tree_file, docket.header.tree_file_size)?;
        const META_SIZE: usize = std::mem::size_of::<Metadata>();
        if meta_file.len() % META_SIZE != 0 {
            return Err(Error::BadMetaFilesize);
        }
        let (meta_array, rest) = Metadata::slice_from_bytes(
            meta_file,
            meta_file.len() / META_SIZE,
        )
        .expect(
            "slice_from_bytes check_mul cannot fail since size came from u32",
        );
        // There cannot be extra bytes because we checked the remainder above.
        assert!(rest.is_empty());
        let tree_root_pointer = docket.header.tree_root_pointer.get();
        let tree_unused_bytes = docket.header.tree_unused_bytes.get();
        Ok(Self {
            list_file,
            meta_array,
            tree_file,
            tree_root_pointer,
            tree_unused_bytes,
            root: match tree_file.len() {
                0 => TreeNode::empty_root(),
                _ => Self::read_node_from(tree_file, tree_root_pointer)?,
            },
        })
    }

    /// Returns the number of paths in the file index.
    pub fn len(&self) -> usize {
        self.meta_array.len()
    }

    /// Looks up [`PathInfo`] by token.
    pub fn get_path_info(
        &self,
        token: FileToken,
    ) -> Result<Option<PathInfo<'on_disk>>, Error> {
        match self.meta_array.get(u32_u(token.0)) {
            Some(metadata) => Ok(Some(PathInfo {
                path: self.read_span(metadata.path())?,
                dirname_length: u16_u(metadata.dirname_length.get()),
            })),
            None => Ok(None),
        }
    }

    /// Looks up a path by token.
    pub fn get_path(
        &self,
        token: FileToken,
    ) -> Result<Option<&'on_disk HgPath>, Error> {
        Ok(self.get_path_info(token)?.map(|info| info.path()))
    }

    /// Looks up a token by path.
    /// Returns `None` if the path isn't in the file index.
    pub fn get_token(&self, path: &HgPath) -> Result<Option<FileToken>, Error> {
        let mut node = self.root;
        let mut remainder = path.as_bytes();
        'outer: while !remainder.is_empty() {
            for edge in node.edges {
                let label = self.read_span(edge.label())?;
                if let Some(suffix) = remainder.drop_prefix(label) {
                    remainder = suffix;
                    node = self.read_node(edge.node_pointer.get())?;
                    continue 'outer;
                }
            }
            return Ok(None);
        }
        Ok(node.token)
    }

    /// Returns an iterator over `(path, token)` pairs in the file index.
    pub fn iter(
        &self,
    ) -> impl Iterator<Item = Result<(PathInfo<'on_disk>, FileToken), Error>>
    {
        self.meta_array.iter().enumerate().map(|(i, metadata)| {
            Ok((
                PathInfo {
                    path: self.read_span(metadata.path())?,
                    dirname_length: u16_u(metadata.dirname_length.get()),
                },
                FileToken(u_u32(i)),
            ))
        })
    }

    /// Reads a [`Span`] from the list file.
    pub(super) fn read_span(
        &self,
        span: Span,
    ) -> Result<&'on_disk [u8], Error> {
        let offset = u32_u(span.offset);
        let length = u16_u(span.length);
        if length == 0 {
            return Err(Error::EmptySpan);
        }
        self.list_file
            .get(offset..offset + length)
            .ok_or(Error::ListFileOutOfBounds)
    }

    /// Reads a [`TreeNode`] from the tree file.
    pub(super) fn read_node(
        &self,
        ptr: u32,
    ) -> Result<TreeNode<'on_disk>, Error> {
        Self::read_node_from(self.tree_file, ptr)
    }

    /// Helper for reading a [`TreeNode`] before constructing an instance.
    fn read_node_from(
        tree_file: &'on_disk [u8],
        ptr: u32,
    ) -> Result<TreeNode<'on_disk>, Error> {
        let slice =
            tree_file.get(u32_u(ptr)..).ok_or(Error::TreeFileOutOfBounds)?;
        let (header, rest) =
            TreeNodeHeader::from_bytes(slice).or(Err(Error::TreeFileEof))?;
        let (token, rest) = if header.flags().contains(TreeNodeFlags::HAS_TOKEN)
        {
            let (token, rest) =
                U32Be::from_bytes(rest).or(Err(Error::TreeFileEof))?;
            (Some(FileToken(token.get())), rest)
        } else {
            (None, rest)
        };
        let (edges, _rest) = TreeEdge::slice_from_bytes(
            rest,
            header.num_children as usize,
        )
        .expect(
            "slice_from_bytes check_mul cannot fail since size came from u32",
        );
        Ok(TreeNode { token, edges })
    }

    /// Iterates over tree nodes, for debug output.
    pub fn debug_iter_tree_nodes(&self) -> DebugTreeNodeIter<'on_disk> {
        let stack = match self.tree_file.len() {
            0 => vec![],
            _ => vec![self.tree_root_pointer],
        };
        DebugTreeNodeIter { inner: *self, stack }
    }
}

/// An iterator over the nodes of a [`FileIndexView`].
pub struct DebugTreeNodeIter<'on_disk> {
    inner: FileIndexView<'on_disk>,
    stack: Vec<NodePointer>,
}

/// A debug representation of a file index tree node.
/// Contains pointesr,
pub type DebugTreeNode<'on_disk> =
    (NodePointer, Option<FileToken>, Vec<(&'on_disk [u8], NodePointer)>);

impl<'on_disk> Iterator for DebugTreeNodeIter<'on_disk> {
    type Item = Result<DebugTreeNode<'on_disk>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        let pointer = self.stack.pop()?;
        let node = match self.inner.read_node(pointer) {
            Ok(node) => node,
            Err(err) => return Some(Err(err)),
        };
        let mut edges = Vec::with_capacity(node.edges.len());
        for edge in node.edges {
            let label = match self.inner.read_span(edge.label()) {
                Ok(label) => label,
                Err(err) => return Some(Err(err)),
            };
            edges.push((label, edge.node_pointer.get()));
        }
        // Push to stack in reverse order to match Python which uses recursion.
        for edge in node.edges.iter().rev() {
            self.stack.push(edge.node_pointer.get());
        }
        Some(Ok((pointer, node.token, edges)))
    }
}
