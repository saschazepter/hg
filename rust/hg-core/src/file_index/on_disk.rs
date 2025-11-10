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

use bytes_cast::unaligned::U16Be;
use bytes_cast::unaligned::U32Be;
use bytes_cast::BytesCast;
use self_cell::self_cell;

use super::FileToken;
use crate::utils::docket::FileUid;
use crate::utils::hg_path::HgPath;
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
    MetaFileOutOfBounds,
    TreeFileOutOfBounds,
    TreeFileEof,
    BadRootNode,
    BadSingletonTree,
    BadLeafLabel,
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
            Error::MetaFileOutOfBounds => {
                write!(f, "meta file access out of bounds")
            }
            Error::TreeFileOutOfBounds => {
                write!(f, "tree file access out of bounds")
            }
            Error::TreeFileEof => {
                write!(f, "unexpected EOF while parsing tree file")
            }
            Error::BadRootNode => {
                write!(f, "invalid root node in tree")
            }
            Error::BadSingletonTree => {
                write!(f, "invalid singleton tree")
            }
            Error::BadLeafLabel => {
                write!(f, "invalid label for leaf node")
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
/// It stores a token and, indirectly, a label.
/// The label is a substring of the file path corresponding to the token.
/// The substring start position is implicit by summing parent label lengths.
/// The node also stores the first characters of child labels, for performance.
#[derive(Debug, Copy, Clone)]
pub(super) struct TreeNode<'on_disk> {
    /// A token that contains this node's label.
    pub(super) token: FileToken,
    /// The length of this node's label.
    pub(super) label_length: u8,
    /// First character of each child label. These are all distinct.
    pub(super) child_chars: &'on_disk [u8],
    /// Pointers to this node's children.
    pub(super) child_ptrs: &'on_disk [TaggedNodePointer],
}

impl TreeNode<'_> {
    /// Returns the index of the child whose label starts with `char`,
    /// or `None` is there is no such child.
    fn find_child(&self, char: u8) -> Option<usize> {
        // Not using memchr because `child_chars` is usually very short, and
        // memchr is slightly slower in that case (I measured ~10% slower).
        self.child_chars.iter().position(|&c| c == char)
    }
}

/// A node header in the tree file.
#[derive(Debug, BytesCast, Copy, Clone)]
#[repr(C)]
pub(super) struct TreeNodeHeader {
    /// A token that contains this node's label.
    token: U32Be,
    /// The length of this node's label.
    label_length: u8,
    /// Number of children.
    pub(super) num_children: u8,
}

/// A serialized empty file index tree file, containing a single root node.
// TODO: Construct directly and serialize once bytes_cast provides const fns:
// https://foss.heptapod.net/octobus/rust/bytes-cast/-/merge_requests/2
pub const EMPTY_TREE_BYTES: [u8; std::mem::size_of::<TreeNodeHeader>()] =
    [0xff, 0xff, 0xff, 0xff, 0x00, 0x00];

impl TreeNodeHeader {
    pub(super) fn new(
        token: FileToken,
        label_length: u8,
        num_children: u8,
    ) -> Self {
        Self { token: token.0.into(), label_length, num_children }
    }
}

/// Pseudo-pointer to a node in the tree file.
pub(super) type NodePointer = u32;

/// A node pointer where the high bit acts as a tag.
/// When the bit is 0, it is just a pointer.
/// When the bit is 1, it directly stores a [`FileToken`] instead.
#[derive(Debug, BytesCast, Copy, Clone)]
#[repr(transparent)]
pub(super) struct TaggedNodePointer(U32Be);

/// Expanded version of [`TaggedNodePointer`].
#[derive(Debug, Copy, Clone)]
pub(super) enum PointerOrToken {
    Pointer(NodePointer),
    Token(FileToken),
}

impl TaggedNodePointer {
    pub(super) fn unpack(self) -> PointerOrToken {
        let value = self.0.get();
        let mask = 1 << 31;
        if value & mask == 0 {
            PointerOrToken::Pointer(value)
        } else {
            PointerOrToken::Token(FileToken(value & !mask))
        }
    }
}

impl PointerOrToken {
    pub(super) fn pack(self) -> TaggedNodePointer {
        let mask = 1 << 31;
        let value = match self {
            PointerOrToken::Pointer(ptr) => ptr,
            PointerOrToken::Token(token) => mask | token.0,
        };
        TaggedNodePointer(value.into())
    }
}

/// The position of a node's label within the file path. This is never stored
/// explicitly, but calculated by adding up the [`TreeNode::label_length`]
/// values while descending the tree.
pub(super) type LabelPosition = usize;

/// Data files for creating a [`FileIndexView`].
#[derive(Default)]
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
    /// Value of [`DocketHeader::tree_file_size`].
    /// Usually the same as `self.tree_file.len()`, but for an empty file index
    /// this will be 0 while `self.tree_file` will contain a default.
    pub(super) tree_file_size: u32,
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
        Self::open(&Docket::default(), DataFiles::default())
            .expect("empty file index should be valid")
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
        let tree_file = if tree_file.is_empty() {
            &EMPTY_TREE_BYTES
        } else {
            tree_file
        };
        const META_SIZE: usize = std::mem::size_of::<Metadata>();
        if meta_file.len() % META_SIZE != 0 {
            return Err(Error::BadMetaFilesize);
        }
        let (meta_array, rest) =
            Metadata::slice_from_bytes(meta_file, meta_file.len() / META_SIZE)
                .expect("cannot fail since len comes from actual size");
        // There cannot be extra bytes because we checked the remainder above.
        assert!(rest.is_empty());
        let tree_file_size = docket.header.tree_file_size.get();
        let tree_root_pointer = docket.header.tree_root_pointer.get();
        let tree_unused_bytes = docket.header.tree_unused_bytes.get();
        let root = Self::read_node_from(tree_file, tree_root_pointer)?;
        if root.token != FileToken::root() || root.label_length != 0 {
            return Err(Error::BadRootNode);
        }
        if tree_file_size > 0 && root.child_ptrs.is_empty() {
            return Err(Error::BadSingletonTree);
        }
        Ok(Self {
            list_file,
            meta_array,
            tree_file,
            tree_file_size,
            tree_root_pointer,
            tree_unused_bytes,
            root,
        })
    }

    /// Returns the number of tokens in the file index.
    pub fn token_count(&self) -> usize {
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
        if path.is_empty() {
            return Ok(None);
        }
        let path = path.as_bytes();
        let mut node = self.root;
        let mut position: LabelPosition = 0;
        while let Some(index) = node.find_child(path[position]) {
            let ptr = node.child_ptrs.get(index).ok_or(Error::TreeFileEof)?;
            let (child_node, metadata) =
                self.read_node_metadata(*ptr, position)?;
            let span = Self::label_span(child_node, metadata, position);
            let label = self.read_span(span)?;
            if !path[position..].starts_with(label) {
                break;
            }
            position += label.len();
            if position == path.len() {
                if path.len() == u16_u(metadata.length.get()) {
                    return Ok(Some(child_node.token));
                }
                break;
            }
            node = child_node;
        }
        Ok(None)
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

    /// Reads a [`Metadata`] entry from the meta file by token.
    pub(super) fn read_metadata(
        &self,
        token: FileToken,
    ) -> Result<&'on_disk Metadata, Error> {
        debug_assert!(token.is_valid());
        self.meta_array.get(u32_u(token.0)).ok_or(Error::MetaFileOutOfBounds)
    }

    /// Constructs a label [`Span`] for a node given its metadata and position.
    pub(super) fn label_span(
        node: TreeNode<'_>,
        metadata: &Metadata,
        position: LabelPosition,
    ) -> Span {
        Span {
            offset: metadata.offset.get() + u_u32(position),
            length: node.label_length as u16,
        }
    }

    /// Reads a [`TreeNode`] from the tree file.
    pub(super) fn read_node(
        &self,
        ptr: u32,
    ) -> Result<TreeNode<'on_disk>, Error> {
        Self::read_node_from(self.tree_file, ptr)
    }

    /// Reads [`TreeNode`] and [`Metadata`] for a tagged pointer.
    fn read_node_metadata(
        &self,
        ptr: TaggedNodePointer,
        position: LabelPosition,
    ) -> Result<(TreeNode<'on_disk>, &'on_disk Metadata), Error> {
        match ptr.unpack() {
            PointerOrToken::Pointer(ptr) => {
                let node = self.read_node(ptr)?;
                let metadata = self.read_metadata(node.token)?;
                Ok((node, metadata))
            }
            PointerOrToken::Token(token) => {
                self.read_leaf_node(token, position)
            }
        }
    }

    /// Reads a leaf node by token.
    pub(super) fn read_leaf_node(
        &self,
        token: FileToken,
        position: LabelPosition,
    ) -> Result<(TreeNode<'on_disk>, &'on_disk Metadata), Error> {
        let metadata = self.read_metadata(token)?;
        let label_length = metadata.length.get() - u_u16(position);
        let label_length: u8 =
            label_length.try_into().or(Err(Error::BadLeafLabel))?;
        let node =
            TreeNode { token, label_length, child_chars: &[], child_ptrs: &[] };
        Ok((node, metadata))
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
        let (child_chars, rest) = rest
            .split_at_checked(header.num_children as usize)
            .ok_or(Error::TreeFileEof)?;
        let (child_ptrs, _rest) = TaggedNodePointer::slice_from_bytes(
            rest,
            header.num_children as usize,
        )
        .or(Err(Error::TreeFileEof))?;
        Ok(TreeNode {
            token: FileToken(header.token.get()),
            label_length: header.label_length,
            child_chars,
            child_ptrs,
        })
    }

    /// Iterates over tree nodes, for debug output.
    pub fn debug_iter_tree_nodes(&self) -> DebugTreeNodeIter<'on_disk> {
        let stack = vec![(self.tree_root_pointer, 0)];
        DebugTreeNodeIter { inner: *self, stack }
    }
}

/// An iterator over the nodes of a [`FileIndexView`].
pub struct DebugTreeNodeIter<'on_disk> {
    inner: FileIndexView<'on_disk>,
    stack: Vec<(NodePointer, LabelPosition)>,
}

/// A debug representation of a file index tree node.
pub struct DebugTreeNode<'on_disk> {
    pub pointer: NodePointer,
    pub token: FileToken,
    pub label: &'on_disk [u8],
    // Use `&[u8; 1]` instead of `u8` to simplify PyO3 conversion.
    pub children: Vec<(&'on_disk [u8; 1], DebugTreeChild<'on_disk>)>,
}

/// A debug representation of a file index tree node child.
#[derive(Copy, Clone)]
pub enum DebugTreeChild<'on_disk> {
    Pointer(NodePointer),
    Leaf(&'on_disk [u8], FileToken),
}

impl<'on_disk> Iterator for DebugTreeNodeIter<'on_disk> {
    type Item = Result<DebugTreeNode<'on_disk>, Error>;

    fn next(&mut self) -> Option<Self::Item> {
        let (pointer, position) = self.stack.pop()?;
        Some(self.next_result(pointer, position))
    }
}

impl<'on_disk> DebugTreeNodeIter<'on_disk> {
    fn next_result(
        &mut self,
        pointer: NodePointer,
        position: LabelPosition,
    ) -> Result<DebugTreeNode<'on_disk>, Error> {
        let node = self.inner.read_node(pointer)?;
        let token = node.token;
        let label = if token == FileToken::root() {
            b""
        } else {
            let metadata = self.inner.read_metadata(token)?;
            let span = FileIndexView::label_span(node, metadata, position);
            self.inner.read_span(span)?
        };
        let position = position + node.label_length as usize;
        let mut children = Vec::with_capacity(node.child_chars.len());
        for (char, &ptr) in node.child_chars.iter().zip(node.child_ptrs) {
            let child = match ptr.unpack() {
                PointerOrToken::Pointer(ptr) => DebugTreeChild::Pointer(ptr),
                PointerOrToken::Token(token) => {
                    let (node, metadata) =
                        self.inner.read_leaf_node(token, position)?;
                    let span =
                        FileIndexView::label_span(node, metadata, position);
                    let label = self.inner.read_span(span)?;
                    DebugTreeChild::Leaf(label, token)
                }
            };
            children.push((std::array::from_ref(char), child));
        }
        // Push to stack in reverse order to match Python which uses recursion.
        for &ptr in node.child_ptrs.iter().rev() {
            match ptr.unpack() {
                PointerOrToken::Pointer(ptr) => {
                    self.stack.push((ptr, position));
                }
                PointerOrToken::Token(_) => {}
            }
        }
        Ok(DebugTreeNode { pointer, token, label, children })
    }
}
