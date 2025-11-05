"""Data structures for the file index."""

from __future__ import annotations

import itertools
import struct
import typing
from typing import Iterator, List, Optional

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

    STRUCT = struct.Struct(">2B")

    # Flag byte.
    flags = attr.ib(type=int)
    # Number of TreeEdge values that follow.
    num_children = attr.ib(type=int)

    @classmethod
    def parse_from(cls, data: memoryview) -> TreeNodeHeader:
        return cls(*cls.STRUCT.unpack_from(data))

    def serialize(self):
        return self.STRUCT.pack(*attr.astuple(self))


TREE_NODE_FLAG_HAS_TOKEN = 0x01
"""Bit in TreeNodeHeader.flags indicating it is followed by a 32-bit token."""


@attr.s(slots=True)
class TreeEdge:
    """An edge in the tree file."""

    STRUCT = struct.Struct(">IHI")

    # Pseudo-pointer to the start of this edge's label in the list file.
    label_offset = attr.ib(type=int)
    # Length of this edge's label.
    label_length = attr.ib(type=int)
    # Pseudo-pointer to the child node in the tree file.
    node_pointer = attr.ib(type=int)

    @classmethod
    def iter_parse(cls, data: memoryview) -> Iterator["TreeEdge"]:
        # iter_unpack checks it's a multiple, even though we're not reading all.
        end = len(data) - len(data) % cls.STRUCT.size
        return (cls(*fields) for fields in cls.STRUCT.iter_unpack(data[:end]))

    def serialize(self):
        return self.STRUCT.pack(*attr.astuple(self))


TOKEN_STRUCT = struct.Struct(">I")
"""A file index token represented as 32-bit big-endian integer."""


@attr.s(slots=True)
class TreeNode:
    """A node parsed from the tree file."""

    # Token for this node, if it represents a path in the file index.
    token = attr.ib(type=Optional[FileTokenT])
    # Edges pointing to children of this node.
    edges = attr.ib(type=List[TreeEdge])

    @classmethod
    def empty_root(cls) -> TreeNode:
        """Return a root node for an empty tree."""
        return cls(token=None, edges=[])

    @classmethod
    def parse_from(cls, data: memoryview) -> TreeNode:
        header = TreeNodeHeader.parse_from(data)
        rest = data[TreeNodeHeader.STRUCT.size :]
        token = None
        if header.flags & TREE_NODE_FLAG_HAS_TOKEN:
            token = TOKEN_STRUCT.unpack_from(rest)[0]
            rest = rest[TOKEN_STRUCT.size :]
        edges = list(
            itertools.islice(TreeEdge.iter_parse(rest), header.num_children)
        )
        return cls(token, edges)


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
    token = attr.ib(type=Optional[FileTokenT])
    # Edges to children of this node.
    edges = attr.ib(type=List["MutableTreeEdge"])

    @staticmethod
    def copy(base: Base, node: TreeNode):
        return MutableTreeNode(
            token=node.token,
            edges=[MutableTreeEdge.copy(base, edge) for edge in node.edges],
        )


@attr.s(slots=True)
class MutableTreeEdge:
    """Mutable version of `TreeEdge`."""

    # The label of this edge.
    label = attr.ib(type=bytes)
    # Offset of label in the list file.
    label_offset = attr.ib(type=int)
    # If True, node_pointer is an index into MutableTree.nodes.
    # If False, node_pointer is an offset into MutableTree.base.tree_file.
    node_is_in_memory = attr.ib(type=bool)
    # Pointer to the child node.
    node_pointer = attr.ib(type=int)

    @staticmethod
    def copy(base: Base, edge: TreeEdge):
        return MutableTreeEdge(
            label=base.list_file[edge.label_offset :][: edge.label_length],
            label_offset=edge.label_offset,
            node_is_in_memory=False,
            node_pointer=edge.node_pointer,
        )


NODE_POINTER_STRUCT = struct.Struct(">I")


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
    >>> t.insert(b"foo", 0, offset)
    >>> meta_array.append(Metadata(offset, len(b"foo"), 0))
    >>> offset += len(b"foo") + 1
    >>> t.debug()
    {b'foo': 0}
    >>> t.insert(b"bar", 1, offset)
    >>> meta_array.append(Metadata(offset, len(b"bar"), 0))
    >>> offset += len(b"bar") + 1
    >>> t.debug()
    {b'foo': 0, b'bar': 1}
    >>> t.insert(b"fool", 2, offset)
    >>> meta_array.append(Metadata(offset, len(b"fool"), 0))
    >>> offset += len(b"fool") + 1
    >>> t.debug()
    {b'foo': (0, {b'l': 2}), b'bar': 1}
    >>> t.insert(b"baz", 3, offset)
    >>> meta_array.append(Metadata(offset, len(b"baz"), 0))
    >>> offset += len(b"baz") + 1
    >>> t.debug()
    {b'foo': (0, {b'l': 2}), b'ba': {b'r': 1, b'z': 3}}
    >>> t.insert(b"ba", 4, offset)
    >>> meta_array.append(Metadata(offset, len(b"ba"), 0))
    >>> offset += len(b"ba") + 1
    >>> t.debug()
    {b'foo': (0, {b'l': 2}), b'ba': (4, {b'r': 1, b'z': 3})}

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
    {b'foo': '0x003c', b'ba': '0x0016'}
    >>> t.insert(b"other", 5, offset)
    >>> offset += len(b"other") + 1
    >>> t.debug()
    {b'foo': '0x003c', b'ba': '0x0016', b'other': 5}
    >>> t.insert(b"food", 6, offset)
    >>> offset += len(b"food") + 1
    >>> t.debug()
    {b'foo': (0, {b'l': '0x004c', b'd': 6}), b'ba': '0x0016', b'other': 5}
    >>> t.insert(b"barn", 7, offset)
    >>> offset += len(b"barn") + 1
    >>> t.debug()
    {b'foo': (0, {b'l': '0x004c', b'd': 6}), b'ba': (4, {b'r': (1, {b'n': 7}), b'z': '0x0030'}), b'other': 5}
    """

    def __init__(self, base: Base | None):
        self.base = base or Base.empty()
        root = MutableTreeNode.copy(self.base, self.base.root_node)
        self.nodes = [root]
        self.num_copied_nodes = 1 if len(self.base.tree_file) > 0 else 0
        self.num_copied_edges = len(root.edges)
        self.num_copied_tokens = 0
        self.num_paths_added = 0

    def __len__(self) -> int:
        """Return the number of paths in this tree, including the base."""
        return len(self.base.meta_array) + self.num_paths_added

    def _copy_node_at(self, offset) -> int:
        node = TreeNode.parse_from(self.base.tree_file[offset:])
        self.num_copied_nodes += 1
        self.num_copied_edges += len(node.edges)
        if node.token is not None:
            self.num_copied_tokens += 1
        node_index = len(self.nodes)
        self.nodes.append(MutableTreeNode.copy(self.base, node))
        return node_index

    def insert(
        self,
        path: HgPathT,
        token: FileTokenT,
        path_offset: int,
    ):
        assert len(path) != 0
        remainder = path
        node = self.nodes[0]
        while True:
            for edge in node.edges:
                if remainder.startswith(edge.label):
                    remainder = remainder[len(edge.label) :]
                    if not edge.node_is_in_memory:
                        edge.node_pointer = self._copy_node_at(
                            edge.node_pointer
                        )
                        edge.node_is_in_memory = True
                    node = self.nodes[edge.node_pointer]
                    # Break, skipping else clause and continuing while loop.
                    break
            else:
                break
        common = None
        if remainder:
            for i, edge in enumerate(node.edges):
                prefix = stringutil.common_prefix(remainder, edge.label)
                if prefix:
                    common = i, edge, prefix
                    break
        consumed = len(path) - len(remainder)
        label_offset = path_offset + consumed
        if common:
            i, edge, prefix = common
            edge_to_intermediate_node = MutableTreeEdge(
                label=prefix,
                # We arbitrarily choose label_offset (prefix from new path)
                # here instead of edge.label_offset (prefix from old path).
                label_offset=label_offset,
                node_is_in_memory=True,
                node_pointer=len(self.nodes),
            )
            edge_to_old_node = MutableTreeEdge(
                label=edge.label[len(prefix) :],
                label_offset=edge.label_offset + len(prefix),
                node_is_in_memory=edge.node_is_in_memory,
                node_pointer=edge.node_pointer,
            )
            intermediate_node = MutableTreeNode(
                token=None, edges=[edge_to_old_node]
            )
            node.edges[i] = edge_to_intermediate_node
            self.nodes.append(intermediate_node)
            node = intermediate_node
            remainder = remainder[len(prefix) :]
            label_offset += len(prefix)
        if remainder:
            node.edges.append(
                MutableTreeEdge(
                    label=remainder,
                    label_offset=label_offset,
                    node_is_in_memory=True,
                    node_pointer=len(self.nodes),
                )
            )
            assert len(node.edges) <= 255
            node = MutableTreeNode(token=None, edges=[])
            self.nodes.append(node)
        assert node.token is None, "path was already inserted"
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
        num_additional_tokens = self.num_copied_tokens + self.num_paths_added
        num_fresh_nodes = num_additional_nodes - self.num_copied_nodes
        root_is_fresh = self.num_copied_nodes == 0
        # There is a fresh edge for every fresh node except the root.
        num_fresh_edges = num_fresh_nodes - (1 if root_is_fresh else 0)
        num_additional_edges = self.num_copied_edges + num_fresh_edges
        additional_size = (
            num_additional_nodes * TreeNodeHeader.STRUCT.size
            + num_additional_edges * TreeEdge.STRUCT.size
            + num_additional_tokens * TOKEN_STRUCT.size
        )
        final_size = old_size + additional_size
        buffer = bytearray()
        stack = [(0, 0)]
        UNSET_POINTER = 0xFFFFFFFF
        while stack:
            index, fixup_offset = stack.pop()
            if index != 0:
                # Fix up `TreeEdge.node_pointer` in the incoming edge.
                current_offset = old_size + len(buffer)
                NODE_POINTER_STRUCT.pack_into(
                    buffer, fixup_offset, current_offset
                )
            node = self.nodes[index]
            num_children = len(node.edges)
            flags = 0 if node.token is None else TREE_NODE_FLAG_HAS_TOKEN
            header = TreeNodeHeader(flags, num_children)
            assert not (flags == 0 and num_children == 0)
            buffer.extend(header.serialize())
            if node.token is not None:
                buffer.extend(TOKEN_STRUCT.pack(node.token))
            for edge in node.edges:
                if edge.node_is_in_memory:
                    # The field offset of TreeEdge.node_pointer is 6 bytes.
                    fixup_offset = len(buffer) + 6
                    stack.append((edge.node_pointer, fixup_offset))
                    node_pointer = UNSET_POINTER
                else:
                    node_pointer = edge.node_pointer
                edge_value = TreeEdge(
                    label_offset=edge.label_offset,
                    label_length=len(edge.label),
                    node_pointer=node_pointer,
                )
                buffer.extend(edge_value.serialize())

        assert (
            len(buffer) == additional_size
        ), f"buffer size is {len(buffer)}, expected {additional_size}"
        old_unused_bytes = self.base.docket.tree_unused_bytes
        additional_unused_bytes = (
            self.num_copied_nodes * TreeNodeHeader.STRUCT.size
            + self.num_copied_edges * TreeEdge.STRUCT.size
            + self.num_copied_tokens * TOKEN_STRUCT.size
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

        def recur(pointer, in_memory=True):
            if not in_memory:
                return f"{pointer:#06x}"
            node = self.nodes[pointer]
            edges = {
                e.label: recur(e.node_pointer, e.node_is_in_memory)
                for e in node.edges
            }
            if node.token is not None and node.edges:
                return (node.token, edges)
            if node.token is not None:
                return node.token
            return edges

        return recur(0)
