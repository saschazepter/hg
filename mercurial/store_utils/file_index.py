"""Implementation of the file index.

See mercurial/interfaces/file_index.py for the high level interface.
See mercurial/helptext/internals/fileindex.txt for format details.
"""

from __future__ import annotations

import abc
import typing

from ..i18n import _
from ..thirdparty import attr
from ..interfaces.types import HgPathT, TransactionT
from .. import pycompat, util
from ..interfaces import file_index as int_file_index
from . import file_index_util

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

propertycache = util.propertycache


class _FileIndexCommon(int_file_index.IFileIndex, abc.ABC):
    """
    Methods that are identical for both implementations of the fileindex
    class, with and without Rust extensions enabled.
    """

    def __init__(self, opener):
        self._opener = opener
        self._add = []
        self._add_map = {}
        self._docket_file_found = False
        self._written = False

    def has_token(self, token: int_file_index.FileTokenT):
        return token >= 0 and token < len(self)

    def get_path(self, token: int_file_index.FileTokenT):
        if not self.has_token(token):
            raise KeyError
        n = len(self.meta_array)
        if token < n:
            return self._get_path_on_disk(token)
        return self._add[token - n]

    @abc.abstractmethod
    def _get_path_on_disk(self, token: int_file_index.FileTokenT) -> HgPathT:
        """Look up a path on disk by token."""

    def get_token(self, path: HgPathT):
        token = self._add_map.get(path)
        if token is not None:
            return token
        return self._get_token_on_disk(path)

    @abc.abstractmethod
    def _get_token_on_disk(
        self, path: HgPathT
    ) -> int_file_index.FileTokenT | None:
        """Look up a path on disk by token."""

    def __contains__(self, path: HgPathT):
        return self.get_token(path) is not None

    def __len__(self):
        return len(self.meta_array) + len(self._add)

    def __iter__(self):
        for token in range(len(self)):
            yield self.get_path(int_file_index.FileTokenT(token))

    def items(self):
        for token in range(len(self)):
            yield self.get_path(int_file_index.FileTokenT(token)), token

    def add(self, path: HgPathT, tr: TransactionT):
        assert not self._written, "cannot add to file index after writing"
        token = self.get_token(path)
        if token is None:
            token = len(self)
            self._add.append(path)
            self._add_map[path] = token
        return token

    def write(self, tr: TransactionT):
        assert not self._written, "should only write file index once"
        if not self._add:
            return
        tr.addfilegenerator(
            b"fileindex",
            (b"fileindex",),
            self._write,
            location=b"store",
            # Needs to be post_finalize so that we can call fileindex.write
            # in a tr.addfinalize callback.
            post_finalize=True,
        )

    @abc.abstractmethod
    def _write(self, f: typing.BinaryIO):
        """Write all data files, and write the docket to f."""

    @propertycache
    def docket(self) -> file_index_util.Docket:
        self._docket_file_found = False
        try:
            with self._open_docket_file() as fp:
                data = fp.read()
        except FileNotFoundError:
            return file_index_util.Docket()
        self._docket_file_found = True
        return file_index_util.Docket.parse_from(data)

    def _is_initial(self):
        """Return true if this is a new file index (there was none on disk)."""
        self.docket
        return not self._docket_file_found

    def _open_docket_file(self):
        return self._opener(b"fileindex")

    @propertycache
    def list_file(self):
        return self._mapfile(b"list", default=b"")

    @propertycache
    def meta_file(self):
        return self._mapfile(b"meta", default=b"")

    @propertycache
    def meta_array(self):
        return file_index_util.MetadataArray(self.meta_file)

    @propertycache
    def tree_file(self):
        return self._mapfile(b"tree", default=b"\x00\x00")

    def _mapfile(self, name: bytes, default: bytes) -> memoryview:
        if self._is_initial():
            data = default
        else:
            path = self._path(name)
            with self._opener(path) as fp:
                if self._opener.is_mmap_safe(path):
                    data = util.mmapread(fp, self._size(name))
                else:
                    data = fp.read()
        return util.buffer(data)

    def _openfile(self, name: bytes, create: bool) -> typing.BinaryIO:
        mode = b"wb" if create else b"r+b"
        f = self._opener(self._path(name, create=create), mode)
        if not create:
            try:
                f.seek(self._size(name))
            except:  # re-raises
                f.close()
                raise
        return f

    def _path(self, name: bytes, create=False) -> bytes:
        attr = pycompat.sysstr(b"%s_file_id" % name)
        if create:
            id = file_index_util.Docket.make_id()
            setattr(self.docket, attr, id)
        else:
            id = getattr(self.docket, attr)
        return b"fileindex-%s.%s" % (name, id)

    def _size(self, name: bytes) -> int:
        return getattr(self.docket, pycompat.sysstr(b"%s_file_size" % name))

    def _read_span(self, offset: int, length: int) -> memoryview:
        """Read a span of bytes from the list file."""
        return self.list_file[offset : offset + length]

    def dump_docket(self, ui):
        if self._is_initial():
            ui.write(_(b"no docket exists yet (empty file index)\n"))
            return
        for name, value in attr.asdict(self.docket).items():
            ui.write(
                b"%s: %s\n" % (pycompat.bytestr(name), pycompat.bytestr(value))
            )

    def dump_tree(self, ui):
        tree = self.tree_file

        def dump(pointer):
            node = file_index_util.TreeNode.parse_from(tree[pointer:])
            token = b""
            if node.token is not None:
                token = b" token = %d" % node.token
            ui.write(b"%08x:%s\n" % (pointer, token))
            for edge in node.edges:
                label = self._read_span(edge.label_offset, edge.label_length)
                ui.write(b'    "%s" -> %08x\n' % (label, edge.node_pointer))
            for edge in node.edges:
                dump(edge.node_pointer)

        dump(self.docket.tree_root_pointer)


class FileIndex(_FileIndexCommon):
    """Pure Python implementation of the file index."""

    def _get_path_on_disk(self, token: int_file_index.FileTokenT):
        meta = self.meta_array[token]
        return bytes(self._read_span(meta.offset, meta.length))

    def _get_token_on_disk(self, path: HgPathT):
        tree_file = self.tree_file
        node = file_index_util.TreeNode.parse_from(
            tree_file[self.docket.tree_root_pointer :]
        )
        remainder = path
        while remainder:
            for edge in node.edges:
                label = self._read_span(edge.label_offset, edge.label_length)
                if remainder.startswith(label):
                    remainder = remainder[len(label) :]
                    node = file_index_util.TreeNode.parse_from(
                        tree_file[edge.node_pointer :]
                    )
                    break
            else:
                return None
        return node.token

    def _write(self, f: typing.BinaryIO):
        assert not self._written, "should only write once"
        assert self._add, "should have something to write"
        docket = self.docket
        initial = self._is_initial()
        if initial:
            assert len(self.meta_array) == 0, "should have nothing on disk yet"
            tree = file_index_util.MutableTree(base=None)
        else:
            tree = file_index_util.MutableTree(
                file_index_util.Base(
                    docket=docket,
                    list_file=self.list_file,
                    tree_file=self.tree_file,
                )
            )
        list_file_size = docket.list_file_size
        meta_file_size = docket.meta_file_size
        with (
            self._openfile(b"list", create=initial) as list_file,
            self._openfile(b"meta", create=initial) as meta_file,
        ):
            token = len(self.meta_array)
            for path in self._add:
                offset = list_file_size
                metadata = file_index_util.Metadata.from_path(path, offset)
                list_file.write(b"%s\x00" % path)
                meta_file.write(metadata.serialize())
                tree.insert(path, token, offset)
                list_file_size += len(path) + 1
                meta_file_size += file_index_util.Metadata.STRUCT.size
                token += 1
        serialized = tree.serialize()
        with self._openfile(b"tree", create=initial) as tree_file:
            tree_file.write(serialized.bytes)
        docket.list_file_size = list_file_size
        docket.meta_file_size = meta_file_size
        docket.tree_file_size = serialized.tree_file_size
        docket.tree_root_pointer = serialized.tree_root_pointer
        docket.tree_unused_bytes = serialized.tree_unused_bytes
        docket.reserved_flags = 0
        f.write(docket.serialize())
        self._written = True
