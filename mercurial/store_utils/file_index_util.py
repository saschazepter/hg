"""Data structures for the file index."""

from __future__ import annotations

import itertools
import struct
import typing
from typing import Iterator, List, Union

from ..thirdparty import attr
from ..interfaces.types import HgPathT
from .. import error, util
from ..interfaces import file_index as int_file_index
from ..utils import docket, stringutil

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

FileTokenT = int_file_index.FileTokenT

NodePointerT = int
"""A pseudo-pointer to a node in the tree file."""

LabelPositionT = int
"""The position of a node's label within the file path."""

ROOT_TOKEN = FileTokenT(0)
"""A special token for the root node."""

V1_FORMAT_MARKER = b"fileindex-v1"


@attr.s(slots=True)
class Docket:
    """Parsed file index docket."""

    STRUCT = struct.Struct(
        "".join(
            [
                ">",
                f"{len(V1_FORMAT_MARKER)}s",
                "4I",  # file sizes
                f"{docket.UID_SIZE}s" * 4,  # file IDs
                "4I",  # other integers
            ]
        )
    )

    # Should contain V1_FORMAT_MARKER.
    marker = attr.ib(type=bytes, default=V1_FORMAT_MARKER)
    # Used size of the list file in bytes.
    list_file_size = attr.ib(type=int, default=0)
    # Reserved for future use.
    reserved_revlog_size = attr.ib(type=int, default=0)
    # Used size of the meta file in bytes.
    meta_file_size = attr.ib(type=int, default=0)
    # Used size of tree file in bytes.
    tree_file_size = attr.ib(type=int, default=0)
    # List file path ID.
    list_file_id = attr.ib(type=bytes, default=docket.UNSET_UID)
    # Reserved for future use.
    reserved_revlog_id = attr.ib(type=bytes, default=docket.UNSET_UID)
    # Meta file path ID.
    meta_file_id = attr.ib(type=bytes, default=docket.UNSET_UID)
    # Tree file path ID.
    tree_file_id = attr.ib(type=bytes, default=docket.UNSET_UID)
    # Pseudo-pointer to the root node in the tree file.
    tree_root_pointer = attr.ib(type=NodePointerT, default=0)
    # Number of unused bytes within tree_file_size.
    tree_unused_bytes = attr.ib(type=int, default=0)
    # Reserved for future use.
    reserved_revlog_unused = attr.ib(type=int, default=0)
    # Currently unused. Reset to zero when writing the docket.
    reserved_flags = attr.ib(type=int, default=0)
    # Paths to old data files to be removed.
    garbage_entries = attr.ib(type=List["GarbageEntry"], factory=list)

    @classmethod
    def parse_from(cls, data: memoryview) -> Docket:
        """Parse a file index docket from bytes."""
        if len(data) < cls.STRUCT.size:
            raise error.CorruptedState("file index docket file too short")
        fields = cls.STRUCT.unpack_from(data)
        garbage_list = GarbageList.parse_from(data[cls.STRUCT.size :])
        docket = cls(*fields, garbage_entries=garbage_list.entries)
        if docket.marker != V1_FORMAT_MARKER:
            raise error.CorruptedState("file index docket has wrong marker")
        docket.reserved_flags = 0
        return docket

    def serialize(self) -> bytes:
        """Serialize the file index docket to bytes."""
        *fields, _garbage_entries = attr.astuple(self, recurse=False)
        fixed = self.STRUCT.pack(*fields)
        garbage = GarbageList(self.garbage_entries).serialize()
        return fixed + garbage


@attr.s(slots=True)
class GarbageList:
    """The garbage list parsed from the docket.

    It consists of a header, an index of fixed size entries, and a buffer of
    paths that the index entries point into.
    """

    entries = attr.ib(type=list["GarbageEntry"])

    @classmethod
    def parse_from(cls, data: memoryview) -> GarbageList:
        header = GarbageListHeader.parse_from(data)
        rest = data[GarbageListHeader.STRUCT.size :]
        num = header.num_entries
        index = itertools.islice(GarbageIndexEntry.iter_parse(rest), num)
        rest = rest[GarbageIndexEntry.STRUCT.size * num :]
        path_buf = rest[: header.path_buf_size]
        return cls(
            [GarbageEntry.from_index(entry, path_buf) for entry in index]
        )

    def serialize(self) -> bytes:
        path_buf = b"".join(entry.path + b"\x00" for entry in self.entries)
        header = GarbageListHeader(
            num_entries=len(self.entries), path_buf_size=len(path_buf)
        )
        result = header.serialize()
        offset = 0
        for entry in self.entries:
            result += entry.to_index(offset).serialize()
            offset += len(entry.path) + 1
        result += path_buf
        return result


@attr.s(slots=True)
class GarbageListHeader:
    """Header of the garbage list in the docket."""

    STRUCT = struct.Struct(">II")

    num_entries = attr.ib(type=int)
    path_buf_size = attr.ib(type=int)

    @classmethod
    def parse_from(cls, data: memoryview) -> GarbageListHeader:
        return cls(*cls.STRUCT.unpack_from(data))

    def serialize(self) -> bytes:
        return self.STRUCT.pack(*attr.astuple(self))


@attr.s(slots=True)
class GarbageIndexEntry:
    """An entry in the garbage list index in the docket."""

    STRUCT = struct.Struct(">HIIH")

    ttl = attr.ib(type=int)
    timestamp = attr.ib(type=int)
    path_offset = attr.ib(type=int)
    path_length = attr.ib(type=int)

    @classmethod
    def iter_parse(cls, data: memoryview) -> Iterator[GarbageIndexEntry]:
        # iter_unpack checks it's a multiple, even though we're not reading all.
        end = len(data) - len(data) % cls.STRUCT.size
        return (cls(*fields) for fields in cls.STRUCT.iter_unpack(data[:end]))

    def serialize(self) -> bytes:
        return self.STRUCT.pack(*attr.astuple(self))


@attr.s(slots=True)
class GarbageEntry:
    """A garbage entry parsed from the docket."""

    ttl = attr.ib(type=int)
    timestamp = attr.ib(type=int)
    path = attr.ib(type=bytes)

    @classmethod
    def from_index(
        cls, entry: GarbageIndexEntry, path_buf: memoryview
    ) -> GarbageEntry:
        return cls(
            ttl=entry.ttl,
            timestamp=entry.timestamp,
            path=path_buf[entry.path_offset :][: entry.path_length],
        )

    def to_index(self, offset: int) -> GarbageIndexEntry:
        return GarbageIndexEntry(
            ttl=self.ttl,
            timestamp=self.timestamp,
            path_offset=offset,
            path_length=len(self.path),
        )


@attr.s(slots=True)
class Metadata:
    """Metadata for a token in the meta file."""

    STRUCT = struct.Struct(">IHH")

    # Pseudo-pointer to the start of the path in the list file.
    offset = attr.ib(type=int)
    # Length of the path.
    length = attr.ib(type=int)
    # Length of the path's dirname prefix, or 0 if there is no slash.
    dirname_length = attr.ib(type=int)

    @staticmethod
    def from_path(path: bytes, offset: int):
        dirname_length = 0
        if b'/' in path:
            dirname_length = path.rindex(b'/')
        return Metadata(
            offset=offset, length=len(path), dirname_length=dirname_length
        )

    @classmethod
    def parse_from(cls, data: memoryview) -> Metadata:
        return cls(*cls.STRUCT.unpack_from(data))

    def serialize(self) -> bytes:
        return self.STRUCT.pack(*attr.astuple(self))


class MetadataArray:
    """An array of Metadata values backed by a file."""

    def __init__(self, data: memoryview):
        self._data = data
        self._len = len(data) // Metadata.STRUCT.size

    def __len__(self):
        return self._len

    def __getitem__(self, index: int) -> Metadata:
        return Metadata.parse_from(self._data[index * Metadata.STRUCT.size :])

    def __iter__(self) -> Iterator[Metadata]:
        for i in range(self._len):
            yield self[i]


EMPTY_META_BYTES = b"\x00\x00\x00\x00\x00\x00\x00\x00"
"""A serialized empty file index meta file."""

assert EMPTY_META_BYTES == Metadata.from_path(b"", 0).serialize()


@attr.s(slots=True)
class TreeNodeHeader:
    """A node header in the tree file."""

    STRUCT = struct.Struct(">IBB")

    # A token that contains this node's label.
    token = attr.ib(type=FileTokenT)
    # The length of this node's label.
    label_length = attr.ib(type=int)
    # Number of children.
    num_children = attr.ib(type=int)

    @classmethod
    def parse_from(cls, data: memoryview) -> TreeNodeHeader:
        return cls(*cls.STRUCT.unpack_from(data))

    def serialize(self):
        return self.STRUCT.pack(*attr.astuple(self))


EMPTY_TREE_BYTES = b"\x00\x00\x00\x00\x00\x00"
"""A serialized empty file index tree file."""

assert EMPTY_TREE_BYTES == TreeNodeHeader(ROOT_TOKEN, 0, 0).serialize()


POINTER_STRUCT = struct.Struct(">I")
"""A file index node pseudo-pointer represented as 32-bit big-endian integer."""


@attr.s(slots=True)
class PointerOrToken:
    """Either a node pointer or a file token."""

    MASK = 1 << 31
    STRUCT = struct.Struct(">I")

    value = attr.ib(type=int)

    @classmethod
    def iter_parse(cls, data: memoryview) -> Iterator[PointerOrToken]:
        # iter_unpack checks it's a multiple, even though we're not reading all.
        end = len(data) - len(data) % cls.STRUCT.size
        return (cls(*fields) for fields in cls.STRUCT.iter_unpack(data[:end]))

    def serialize(self) -> bytes:
        return self.STRUCT.pack(*attr.astuple(self))

    @classmethod
    def pointer(cls, pointer: NodePointerT) -> PointerOrToken:
        return cls(pointer)

    @classmethod
    def token(cls, token: FileTokenT) -> PointerOrToken:
        return cls(cls.MASK | token)

    def get_pointer(self) -> NodePointerT | None:
        if self.value & self.MASK == 0:
            return NodePointerT(self.value)
        return None

    def get_token(self) -> FileTokenT | None:
        if self.value & self.MASK != 0:
            return FileTokenT(self.value & ~self.MASK)
        return None


@attr.s(slots=True)
class TreeNode:
    """A node parsed from the tree file.

    It stores a token and, indirectly, a label.
    The label is a substring of the file path corresponding to the token.
    The substring start position is implicit by summing parent label lengths.
    The node also stores the first characters of child labels, for performance
    """

    # A token that contains this node's label.
    token = attr.ib(type=FileTokenT)
    # The length of this node's label.
    label_length = attr.ib(type=int)
    # First character of each child label. These are all distinct.
    child_chars = attr.ib(type=bytes)
    # Pointers to this node's children, or tokens for the leaves.
    child_ptrs = attr.ib(type=list[PointerOrToken])

    @classmethod
    def parse_from(cls, data: memoryview) -> TreeNode:
        header = TreeNodeHeader.parse_from(data)
        rest = data[TreeNodeHeader.STRUCT.size :]
        n = header.num_children
        child_chars, rest = bytes(rest[:n]), rest[n:]
        rest = rest[: n * POINTER_STRUCT.size]
        child_ptrs = list(PointerOrToken.iter_parse(rest))
        return cls(header.token, header.label_length, child_chars, child_ptrs)

    def find_child(self, char: int) -> PointerOrToken | None:
        """Return the child pointer or token whose label starts with char."""
        try:
            index = self.child_chars.index(char)
        except ValueError:
            return None
        return self.child_ptrs[index]


@attr.s(slots=True, init=False)
class FileIndexView:
    """Read-only view of the file index."""

    list_file = attr.ib(type=memoryview)
    meta_array = attr.ib(type=MetadataArray)
    tree_file = attr.ib(type=memoryview)
    tree_file_size = attr.ib(type=int)
    tree_root_pointer = attr.ib(type=NodePointerT)
    tree_unused_bytes = attr.ib(type=int)
    root = attr.ib(type=TreeNode)

    @classmethod
    def empty(cls) -> FileIndexView:
        """Return a view of an empty file index."""
        return cls(
            docket=Docket(),
            list_file=util.buffer(b""),
            meta_file=util.buffer(b""),
            tree_file=util.buffer(b""),
        )

    def __init__(
        self,
        docket: Docket,
        list_file: memoryview,
        meta_file: memoryview,
        tree_file: memoryview,
    ):
        """Creates a file index view given a docket and file contents."""
        # Unlike in Rust we don't limit files to their docket "use size" fields
        # because that is already done before calling this method.
        # TODO: Make the implementations more consistent on this point.
        if len(meta_file) == 0:
            meta_file = util.buffer(EMPTY_META_BYTES)
        if len(tree_file) == 0:
            tree_file = util.buffer(EMPTY_TREE_BYTES)
        root = TreeNode.parse_from(tree_file[docket.tree_root_pointer :])
        if root.token != ROOT_TOKEN or root.label_length != 0:
            raise error.CorruptedState("invalid file index root node")
        if docket.tree_file_size > 0 and len(root.child_ptrs) == 0:
            raise error.CorruptedState("invalid file index singleton tree")
        self.list_file = list_file
        self.meta_array = MetadataArray(meta_file)
        self.tree_file = tree_file
        self.tree_file_size = docket.tree_file_size
        self.tree_root_pointer = docket.tree_root_pointer
        self.tree_unused_bytes = docket.tree_unused_bytes
        self.root = root

    def token_count(self) -> int:
        """Return the number of tokens in the file index."""
        return len(self.meta_array)

    def items(self) -> Iterator[tuple[HgPathT, FileTokenT]]:
        """Iterate the file index entries as (path, token).

        Excludes the root token.
        """
        iterator = enumerate(self.meta_array)
        next(iterator)  # skip root
        for token, meta in iterator:
            path = self._read_span(meta.offset, meta.length)
            yield bytes(path), FileTokenT(token)

    def get_path(self, token: FileTokenT) -> HgPathT | None:
        """Look up a path on disk by token."""
        meta = self.meta_array[token]
        return bytes(self._read_span(meta.offset, meta.length))

    def get_token(self, path: HgPathT) -> FileTokenT | None:
        """Look up a token on disk by path."""
        if not path:
            return None
        node = self.root
        position = 0
        while (child := node.find_child(path[position])) is not None:
            child_node = self._read_node(child, position)
            label = self._read_label(child_node, position)
            if not path[position:].startswith(label):
                break
            assert len(label) > 0
            position += len(label)
            if position == len(path):
                token = child_node.token
                if len(path) == self.meta_array[token].length:
                    return token
                break
            node = child_node
        return None

    def _read_span(self, offset: int, length: int) -> memoryview:
        """Read a span of bytes from the list file."""
        return self.list_file[offset : offset + length]

    def _read_label(
        self, node: TreeNode, position: LabelPositionT
    ) -> memoryview:
        """Read a node's label from the list file via the meta file."""
        metadata = self.meta_array[node.token]
        return self._read_span(metadata.offset + position, node.label_length)

    def _read_node(
        self, child: PointerOrToken, position: LabelPositionT
    ) -> TreeNode:
        """Read a node from a pointer or token."""
        if (ptr := child.get_pointer()) is not None:
            return TreeNode.parse_from(self.tree_file[ptr:])
        if (token := child.get_token()) is not None:
            return self._read_leaf_node(token, position)
        raise error.ProgrammingError(b"invalid PointerOrToken")

    def _read_leaf_node(
        self, token: FileTokenT, position: LabelPositionT
    ) -> TreeNode:
        """Read a leaf node by token."""
        meta = self.meta_array[token]
        label_length = meta.length - position
        return TreeNode(token, label_length, b"", [])

    def debug_iter_tree_nodes(self) -> Iterator[int_file_index.DebugTreeNode]:
        tree = self.tree_file

        def recur(pointer: NodePointerT, position: LabelPositionT):
            node = TreeNode.parse_from(tree[pointer:])
            if node.token == ROOT_TOKEN:
                label = b""
            else:
                label = bytes(self._read_label(node, position))
            position += node.label_length
            children = []
            for char, child in zip(node.child_chars, node.child_ptrs):
                if (ptr := child.get_pointer()) is not None:
                    rhs = ptr
                elif (token := child.get_token()) is not None:
                    child_node = self._read_leaf_node(token, position)
                    child_label = self._read_label(child_node, position)
                    rhs = bytes(child_label), token
                else:
                    print(child)
                    raise error.ProgrammingError(b"invalid PointerOrToken")
                children.append((bytes([char]), rhs))
            yield (pointer, node.token, label, children)
            for child in node.child_ptrs:
                if (ptr := child.get_pointer()) is not None:
                    yield from recur(ptr, position)

        yield from recur(self.tree_root_pointer, 0)


@attr.s(slots=True)
class MutableTreeNode:
    """Mutable version of `TreeNode`."""

    # See TreeNode.token.
    token = attr.ib(type=FileTokenT)
    # The label of this node.
    label = attr.ib(type=bytes)
    # Children of this node.
    children = attr.ib(type=List["MutableTreeChild"])

    def find_child(self, char: int) -> MutableTreeChild | None:
        """Return the child whose label starts with char."""
        for child in self.children:
            if child.char == char:
                return child
        return None


@attr.s(slots=True)
class MutableTreeChild:
    """A child of a `MutableTreeNode`."""

    # First character of the child node's label.
    char = attr.ib(type=int)
    # If True, node_pointer is an index into MutableTree.nodes.
    # If False, node_pointer is an offset into MutableTree.base.tree_file.
    node_is_in_memory = attr.ib(type=bool)
    # Pointer to the child node.
    node_pointer = attr.ib(type=Union[NodePointerT, int])


@attr.s(slots=True)
class SerializedMutableTree:
    """Result of serializing a `MutableTree`."""

    # Bytes to be written or appended to the tree file.
    bytes = attr.ib(type=bytearray)
    ## The fields below correspond to Docket fields.
    # New total size of the tree file.
    tree_file_size = attr.ib(type=int)
    # New root node offset.
    tree_root_pointer = attr.ib(type=NodePointerT)
    # New total number of unused bytes.
    tree_unused_bytes = attr.ib(type=int)


class MutableTree:
    """An in-memory prefix tree that can be serialized to a tree file.

    We can use it to build a tree from scratch:

    >>> files = [b"foo", b"bar", b"fool", b"baz", b"ba"]
    >>> list_file = b"".join(f + b"\\x00" for f in files)
    >>> meta_array = [Metadata.from_path(b"", 0)]
    >>> t = MutableTree(base=None)
    >>> offset = 0
    >>> t.debug()
    {}
    >>> t.insert(b"foo", 1)
    >>> meta_array.append(Metadata(offset, len(b"foo"), 0))
    >>> offset += len(b"foo") + 1
    >>> t.debug()
    {'f': (b'foo', 1)}
    >>> t.insert(b"bar", 2)
    >>> meta_array.append(Metadata(offset, len(b"bar"), 0))
    >>> offset += len(b"bar") + 1
    >>> t.debug()
    {'f': (b'foo', 1), 'b': (b'bar', 2)}
    >>> t.insert(b"fool", 3)
    >>> meta_array.append(Metadata(offset, len(b"fool"), 0))
    >>> offset += len(b"fool") + 1
    >>> t.debug()
    {'f': (b'foo', 1, {'l': (b'l', 3)}), 'b': (b'bar', 2)}
    >>> t.insert(b"baz", 4)
    >>> meta_array.append(Metadata(offset, len(b"baz"), 0))
    >>> offset += len(b"baz") + 1
    >>> t.debug()
    {'f': (b'foo', 1, {'l': (b'l', 3)}), 'b': (b'ba', 4, {'r': (b'r', 2), 'z': (b'z', 4)})}
    >>> t.insert(b"ba", 5)
    >>> meta_array.append(Metadata(offset, len(b"ba"), 0))
    >>> offset += len(b"ba") + 1
    >>> t.debug()
    {'f': (b'foo', 1, {'l': (b'l', 3)}), 'b': (b'ba', 5, {'r': (b'r', 2), 'z': (b'z', 4)})}

    Then we can serialize it:

    >>> s = t.serialize()
    >>> docket = Docket(
    ...     list_file_size=len(list_file),
    ...     tree_file_size=s.tree_file_size,
    ...     tree_root_pointer=s.tree_root_pointer,
    ... )
    >>> base = FileIndexView(
    ...     docket=docket,
    ...     list_file=list_file,
    ...     meta_file=b"".join(m.serialize() for m in meta_array),
    ...     tree_file=s.bytes,
    ... )

    Then we can create new nodes to append to the serialized tree:

    >>> t = MutableTree(base=base)
    >>> t.debug()
    {'f': '0x0020', 'b': '0x0010'}
    >>> t.insert(b"other", 6)
    >>> offset += len(b"other") + 1
    >>> t.debug()
    {'f': '0x0020', 'b': '0x0010', 'o': (b'other', 6)}
    >>> t.insert(b"food", 7)
    >>> offset += len(b"food") + 1
    >>> t.debug()
    {'f': (b'foo', 1, {'l': (b'l', 3), 'd': (b'd', 7)}), 'b': '0x0010', 'o': (b'other', 6)}
    >>> t.insert(b"barn", 8)
    >>> offset += len(b"barn") + 1
    >>> t.debug()
    {'f': (b'foo', 1, {'l': (b'l', 3), 'd': (b'd', 7)}), 'b': (b'ba', 5, {'r': (b'r', 2, {'n': (b'n', 8)}), 'z': (b'z', 4)}), 'o': (b'other', 6)}
    """

    def __init__(self, base: FileIndexView | None):
        self.base = base or FileIndexView.empty()
        self.nodes: list[MutableTreeNode] = []
        self.num_internal_nodes = 0
        self.num_copied_nodes = 0
        self.num_copied_internal_nodes = 0
        self.num_copied_children = 0
        self.num_paths_added = 0
        self._copy_node_with_label(self.base.root, 0, b"")
        if self.base.tree_file_size == 0:
            self.num_copied_nodes = 0
            self.num_copied_internal_nodes = 0

    def token_count(self) -> int:
        """Return the number of distinct tokens in this tree and its base."""
        return self.base.token_count() + self.num_paths_added

    def _copy_node_at(self, ptr: NodePointerT, position: LabelPositionT) -> int:
        node = TreeNode.parse_from(self.base.tree_file[ptr:])
        return self._copy_node(node, position)

    def _copy_node(self, node: TreeNode, position: LabelPositionT) -> int:
        label = bytes(self.base._read_label(node, position))
        return self._copy_node_with_label(node, position, label)

    def _copy_node_with_label(
        self, node: TreeNode, position: LabelPositionT, label: bytes
    ) -> int:
        self.num_copied_nodes += 1
        if node.child_ptrs:
            self.num_internal_nodes += 1
            self.num_copied_internal_nodes += 1
            self.num_copied_children += len(node.child_ptrs)
        mutable_node = MutableTreeNode(node.token, label, [])
        index = len(self.nodes)
        # Push node first, then children, so root node stays at index 0.
        self.nodes.append(mutable_node)
        mutable_node.children = self._copy_node_children(node, position)
        return index

    def _copy_node_children(
        self, node: TreeNode, position: LabelPositionT
    ) -> list[MutableTreeChild]:
        position += node.label_length
        children = []
        for char, child in zip(node.child_chars, node.child_ptrs):
            if (ptr := child.get_pointer()) is not None:
                mutable_child = MutableTreeChild(
                    char=char, node_is_in_memory=False, node_pointer=ptr
                )
            elif (token := child.get_token()) is not None:
                child_node = self.base._read_leaf_node(token, position)
                index = self._copy_node(child_node, position)
                mutable_child = MutableTreeChild(
                    char=char, node_is_in_memory=True, node_pointer=index
                )
            else:
                raise error.ProgrammingError(b"invalid PointerOrToken")
            children.append(mutable_child)
        return children

    def insert(self, path: HgPathT, token: FileTokenT):
        assert len(path) != 0
        node = self.nodes[0]
        position = 0
        while (child := node.find_child(path[position])) is not None:
            if child.node_is_in_memory:
                child_index = child.node_pointer
            else:
                child_index = self._copy_node_at(child.node_pointer, position)
            child_node = self.nodes[child_index]
            label = child_node.label
            remainder = path[position:]
            length = len(stringutil.common_prefix(remainder, label))
            if length != len(label):
                child_node.label = label[length:]
                intermediate_node = MutableTreeNode(
                    token=token,
                    label=remainder[:length],
                    children=[
                        MutableTreeChild(
                            char=child_node.label[0],
                            node_is_in_memory=True,
                            node_pointer=child_index,
                        )
                    ],
                )
                intermediate_index = len(self.nodes)
                self.nodes.append(intermediate_node)
                self.num_internal_nodes += 1
                child.node_is_in_memory = True
                child.node_pointer = intermediate_index
                node = intermediate_node
                position += length
                break
            child.node_is_in_memory = True
            child.node_pointer = child_index
            node = child_node
            assert len(label) > 0
            position += len(label)
            if position == len(path):
                break
        remainder = path[position:]
        while remainder:
            n = min(len(remainder), 255)
            label, remainder = remainder[:n], remainder[n:]
            if not node.children:
                self.num_internal_nodes += 1
            node.children.append(
                MutableTreeChild(
                    char=label[0],
                    node_is_in_memory=True,
                    node_pointer=len(self.nodes),
                )
            )
            assert len(node.children) <= 255
            node = MutableTreeNode(token=token, label=label, children=[])
            self.nodes.append(node)
        node.token = token
        self.num_paths_added += 1

    def serialize(self) -> SerializedMutableTree | None:
        assert len(self.nodes) > 0, "must have root node"
        if len(self.nodes) == 1:
            # If there's only a root node, no need to write anything.
            return None
        # Terminology: final = old + additional = old + (copied + fresh).
        old_size = self.base.tree_file_size
        num_fresh_nodes = len(self.nodes) - self.num_copied_nodes
        root_is_fresh = self.num_copied_nodes == 0
        # There is a fresh child for every fresh node except the root.
        num_fresh_children = num_fresh_nodes - (1 if root_is_fresh else 0)
        num_additional_children = self.num_copied_children + num_fresh_children
        NODE_SIZE = TreeNodeHeader.STRUCT.size
        CHILD_SIZE = 1 + POINTER_STRUCT.size
        additional_size = (
            self.num_internal_nodes * NODE_SIZE
            + num_additional_children * CHILD_SIZE
        )
        final_size = old_size + additional_size
        buffer = bytearray()
        stack = [(0, 0)]
        UNSET_POINTER = 0xFFFFFFFF
        while stack:
            index, fixup_offset = stack.pop()
            if index != 0:
                # Fix up the incoming pointer.
                current_offset = old_size + len(buffer)
                POINTER_STRUCT.pack_into(buffer, fixup_offset, current_offset)
            node = self.nodes[index]
            header = TreeNodeHeader(
                token=node.token,
                label_length=len(node.label),
                num_children=len(node.children),
            )
            buffer.extend(header.serialize())
            for child in node.children:
                buffer.append(child.char)
            for child in node.children:
                if child.node_is_in_memory:
                    child_node = self.nodes[child.node_pointer]
                    if not child_node.children:
                        token = PointerOrToken.token(child_node.token)
                        buffer.extend(token.serialize())
                    else:
                        fixup_offset = len(buffer)
                        stack.append((child.node_pointer, fixup_offset))
                        buffer.extend(POINTER_STRUCT.pack(UNSET_POINTER))
                else:
                    buffer.extend(POINTER_STRUCT.pack(child.node_pointer))

        assert (
            len(buffer) == additional_size
        ), f"buffer size is {len(buffer)}, expected {additional_size}"
        old_unused_bytes = self.base.tree_unused_bytes
        additional_unused_bytes = (
            self.num_copied_internal_nodes * NODE_SIZE
            + self.num_copied_children * CHILD_SIZE
        )
        final_unused_bytes = old_unused_bytes + additional_unused_bytes
        assert final_unused_bytes <= old_size
        return SerializedMutableTree(
            bytes=buffer,
            tree_root_pointer=old_size,
            tree_file_size=final_size,
            tree_unused_bytes=final_unused_bytes,
        )

    def debug(self):
        """Return a dict representation for debugging."""

        def recur(children: list[MutableTreeChild]):
            result = {}
            for child in children:
                if child.node_is_in_memory:
                    node = self.nodes[child.node_pointer]
                    if node.children:
                        val = (node.label, node.token, recur(node.children))
                    else:
                        val = (node.label, node.token)
                else:
                    val = f"{child.node_pointer:#06x}"
                result[chr(child.char)] = val
            return result

        return recur(self.nodes[0].children)
