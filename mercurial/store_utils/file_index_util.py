"""Data structures for the file index."""

from __future__ import annotations

import itertools
import struct
import typing
from typing import Iterator, List

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

LabelPositionT = int
"""The position of a node's label within the file path."""

ROOT_TOKEN = FileTokenT(0xFFFFFFFF)
"""An invalid sentinel token for the root node."""

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
    tree_root_pointer = attr.ib(type=int, default=0)
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


POINTER_STRUCT = struct.Struct(">I")
"""A file index node pseudo-pointer represented as 32-bit big-endian integer."""


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
    # Pointers to this node's children.
    child_ptrs = attr.ib(type=list[int])

    @classmethod
    def empty_root(cls) -> TreeNode:
        """Return a root node for an empty tree."""
        return cls(
            token=ROOT_TOKEN, label_length=0, child_chars=b"", child_ptrs=[]
        )

    @classmethod
    def parse_from(cls, data: memoryview) -> TreeNode:
        header = TreeNodeHeader.parse_from(data)
        rest = data[TreeNodeHeader.STRUCT.size :]
        n = header.num_children
        child_chars, rest = bytes(rest[:n]), rest[n:]
        rest = rest[: n * POINTER_STRUCT.size]
        child_ptrs = [ptr for (ptr,) in POINTER_STRUCT.iter_unpack(rest)]
        return cls(header.token, header.label_length, child_chars, child_ptrs)

    def find_child(self, char: int) -> int | None:
        """Return the child pointer whose label starts with char."""
        try:
            index = self.child_chars.index(char)
        except ValueError:
            return None
        return self.child_ptrs[index]


@attr.s(slots=True)
class Base:
    """Base information that `MutableTree` builds on."""

    docket = attr.ib(type=Docket)
    list_file = attr.ib(type=memoryview)
    meta_array = attr.ib(type=MetadataArray)
    tree_file = attr.ib(type=memoryview)
    root_node = attr.ib(type=TreeNode)

    @classmethod
    def empty(cls) -> Base:
        return cls(
            docket=Docket(),
            list_file=util.buffer(b""),
            meta_array=MetadataArray(util.buffer(b"")),
            tree_file=util.buffer(b""),
            root_node=TreeNode.empty_root(),
        )


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
    node_pointer = attr.ib(type=int)


@attr.s(slots=True)
class SerializedMutableTree:
    """Result of serializing a `MutableTree`."""

    # Bytes to be written or appended to the tree file.
    bytes = attr.ib(type=bytearray)
    ## The fields below correspond to Docket fields.
    # New total size of the tree file.
    tree_file_size = attr.ib(type=int)
    # New root node offset.
    tree_root_pointer = attr.ib(type=int)
    # New total number of unused bytes.
    tree_unused_bytes = attr.ib(type=int)


class MutableTree:
    """An in-memory prefix tree that can be serialized to a tree file.

    We can use it to build a tree from scratch:

    >>> files = [b"foo", b"bar", b"fool", b"baz", b"ba"]
    >>> list_file = b"".join(f + b"\\x00" for f in files)
    >>> meta_array = []
    >>> t = MutableTree(base=None)
    >>> offset = 0
    >>> t.debug()
    {}
    >>> t.insert(b"foo", 0)
    >>> meta_array.append(Metadata(offset, len(b"foo"), 0))
    >>> offset += len(b"foo") + 1
    >>> t.debug()
    {'f': (b'foo', 0)}
    >>> t.insert(b"bar", 1)
    >>> meta_array.append(Metadata(offset, len(b"bar"), 0))
    >>> offset += len(b"bar") + 1
    >>> t.debug()
    {'f': (b'foo', 0), 'b': (b'bar', 1)}
    >>> t.insert(b"fool", 2)
    >>> meta_array.append(Metadata(offset, len(b"fool"), 0))
    >>> offset += len(b"fool") + 1
    >>> t.debug()
    {'f': (b'foo', 0, {'l': (b'l', 2)}), 'b': (b'bar', 1)}
    >>> t.insert(b"baz", 3)
    >>> meta_array.append(Metadata(offset, len(b"baz"), 0))
    >>> offset += len(b"baz") + 1
    >>> t.debug()
    {'f': (b'foo', 0, {'l': (b'l', 2)}), 'b': (b'ba', 3, {'r': (b'r', 1), 'z': (b'z', 3)})}
    >>> t.insert(b"ba", 4)
    >>> meta_array.append(Metadata(offset, len(b"ba"), 0))
    >>> offset += len(b"ba") + 1
    >>> t.debug()
    {'f': (b'foo', 0, {'l': (b'l', 2)}), 'b': (b'ba', 4, {'r': (b'r', 1), 'z': (b'z', 3)})}

    Then we can serialize it:

    >>> s = t.serialize()
    >>> docket = Docket(
    ...     list_file_size=len(list_file),
    ...     tree_file_size=s.tree_file_size,
    ...     tree_root_pointer=s.tree_root_pointer,
    ... )
    >>> root_node = TreeNode.parse_from(s.bytes[s.tree_root_pointer:])
    >>> base = Base(
    ...     docket=docket,
    ...     list_file=list_file,
    ...     meta_array=meta_array,
    ...     tree_file=s.bytes,
    ...     root_node=root_node,
    ... )

    Then we can create new nodes to append to the serialized tree:

    >>> t = MutableTree(base=base)
    >>> t.debug()
    {'f': '0x002c', 'b': '0x0010'}
    >>> t.insert(b"other", 5)
    >>> offset += len(b"other") + 1
    >>> t.debug()
    {'f': '0x002c', 'b': '0x0010', 'o': (b'other', 5)}
    >>> t.insert(b"food", 6)
    >>> offset += len(b"food") + 1
    >>> t.debug()
    {'f': (b'foo', 0, {'l': '0x0037', 'd': (b'd', 6)}), 'b': '0x0010', 'o': (b'other', 5)}
    >>> t.insert(b"barn", 7)
    >>> offset += len(b"barn") + 1
    >>> t.debug()
    {'f': (b'foo', 0, {'l': '0x0037', 'd': (b'd', 6)}), 'b': (b'ba', 4, {'r': (b'r', 1, {'n': (b'n', 7)}), 'z': '0x0020'}), 'o': (b'other', 5)}
    """

    def __init__(self, base: Base | None):
        self.base = base or Base.empty()
        self.nodes: list[MutableTreeNode] = []
        self.num_copied_nodes = 0
        self.num_copied_children = 0
        self.num_paths_added = 0
        self._copy_node(self.base.root_node, b"")
        if len(self.base.tree_file) == 0:
            self.num_copied_nodes = 0

    def __len__(self) -> int:
        """Return the number of paths in this tree, including the base."""
        return len(self.base.meta_array) + self.num_paths_added

    def _copy_node_at(self, offset: int, position: LabelPositionT) -> int:
        node = TreeNode.parse_from(self.base.tree_file[offset:])
        meta = self.base.meta_array[node.token]
        offset = meta.offset + position
        label = self.base.list_file[offset:][: node.label_length]
        return self._copy_node(node, bytes(label))

    def _copy_node(self, node: TreeNode, label: bytes) -> int:
        self.num_copied_nodes += 1
        self.num_copied_children += len(node.child_ptrs)
        node_index = len(self.nodes)
        children = [
            MutableTreeChild(
                char=char, node_is_in_memory=False, node_pointer=ptr
            )
            for char, ptr in zip(node.child_chars, node.child_ptrs)
        ]
        self.nodes.append(MutableTreeNode(node.token, label, children))
        return node_index

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
        old_size = self.base.docket.tree_file_size
        num_additional_nodes = len(self.nodes)
        num_fresh_nodes = num_additional_nodes - self.num_copied_nodes
        root_is_fresh = self.num_copied_nodes == 0
        # There is a fresh child for every fresh node except the root.
        num_fresh_children = num_fresh_nodes - (1 if root_is_fresh else 0)
        num_additional_children = self.num_copied_children + num_fresh_children
        NODE_SIZE = TreeNodeHeader.STRUCT.size
        CHILD_SIZE = 1 + POINTER_STRUCT.size
        additional_size = (
            num_additional_nodes * NODE_SIZE
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
                    fixup_offset = len(buffer)
                    stack.append((child.node_pointer, fixup_offset))
                    node_pointer = UNSET_POINTER
                else:
                    node_pointer = child.node_pointer
                buffer.extend(POINTER_STRUCT.pack(node_pointer))

        assert (
            len(buffer) == additional_size
        ), f"buffer size is {len(buffer)}, expected {additional_size}"
        old_unused_bytes = self.base.docket.tree_unused_bytes
        additional_unused_bytes = (
            self.num_copied_nodes * NODE_SIZE
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
