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
from .. import error, formatter, pycompat, util
from ..interfaces import file_index as int_file_index
from . import file_index_util

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

propertycache = util.propertycache

DEFAULT_DOCKET_TEMPLATE = b"""\
marker: {marker}
list_file_size: {list_file_size}
reserved_revlog_size: {reserved_revlog_size}
meta_file_size: {meta_file_size}
tree_file_size: {tree_file_size}
trash_file_size: {trash_file_size}
list_file_id: {list_file_id}
reserved_revlog_id: {reserved_revlog_id}
meta_file_id: {meta_file_id}
tree_file_id: {tree_file_id}
tree_root_pointer: {tree_root_pointer}
tree_unused_bytes: {tree_unused_bytes}
reserved_revlog_unused: {reserved_revlog_unused}
trash_start_offset: {trash_start_offset}
reserved_flags: {reserved_flags}
"""


class _FileIndexCommon(int_file_index.IFileIndex, abc.ABC):
    """
    Methods that are identical for both implementations of the fileindex
    class, with and without Rust extensions enabled.
    """

    def __init__(self, opener, try_pending: bool, max_unused_ratio: float):
        """
        If try_pending is True, tries opening the docket with the ".pending"
        suffix, falling back to the normal docket path.
        """
        if not 0 <= max_unused_ratio <= 100:
            raise error.ProgrammingError(b"invalid max_unused_ratio")
        self._opener = opener
        self._try_pending = try_pending
        self._max_unused_ratio = max_unused_ratio
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
            # If there are external hooks, both callbacks run:
            # - pending: write data files, and write docket with ".pending" suffix
            # - finalize: write docket again without suffix
            # Otherwise, only the finalize callback runs and we do everything then.
            tr.addpending(b"fileindex", self._add_file_generator)
            tr.addfinalize(b"fileindex", self._add_file_generator)
        return token

    def vacuum(self, tr: TransactionT):
        assert not self._written, "should only write file index once"
        assert not self._add, "manual vacuum should not add files"
        self._add_file_generator(tr, force_vacuum=True)

    def _add_file_generator(self, tr: TransactionT, force_vacuum=False):
        """Add a file generator for writing the file index."""
        tr.addfilegenerator(
            b"fileindex",
            (b"fileindex",),
            lambda f: self._write(f, force_vacuum),
            location=b"store",
            # Need post_finalize since we call this in an addfinalize callback.
            post_finalize=True,
        )

    def _write(self, f: typing.BinaryIO, force_vacuum: bool):
        """Write all data files and the docket."""
        # If we write multiple times (e.g. transaction pending and finalize),
        # only write data files the first time. Next time, just the docket.
        if not self._written:
            vacuum = (
                force_vacuum
                or self.docket.tree_unused_bytes
                >= self.docket.tree_file_size * self._max_unused_ratio
            )
            self._write_data(vacuum)
            self._written = True
        f.write(self.docket.serialize())

    @abc.abstractmethod
    def _write_data(self, vacuum: bool):
        """Write all data files and update self.docket.

        If vacuum is True, writes a new tree file instead of appending to the
        existing one.
        """

    @propertycache
    def docket(self) -> file_index_util.Docket:
        self._docket_file_found = False
        data = None
        if self._try_pending:
            # Written by transaction.writepending.
            data = self._opener.tryread(b"fileindex.pending")
        if not data:
            try:
                data = self._opener.read(b"fileindex")
            except FileNotFoundError:
                return file_index_util.Docket()
        self._docket_file_found = True
        return file_index_util.Docket.parse_from(data)

    def _is_initial(self):
        """Return true if this is a new file index (there was none on disk)."""
        self.docket
        return not self._docket_file_found

    def _list_file_path(self):
        return b"fileindex-list." + self.docket.list_file_id

    def _meta_file_path(self):
        return b"fileindex-meta." + self.docket.meta_file_id

    def _tree_file_path(self):
        return b"fileindex-tree." + self.docket.tree_file_id

    @propertycache
    def list_file(self):
        return self._mapfile(self._list_file_path(), self.docket.list_file_size)

    @propertycache
    def meta_file(self):
        return self._mapfile(self._meta_file_path(), self.docket.meta_file_size)

    @propertycache
    def meta_array(self):
        return file_index_util.MetadataArray(self.meta_file)

    @propertycache
    def tree_file(self):
        return self._mapfile(
            self._tree_file_path(),
            self.docket.tree_file_size,
            default=b"\x00\x00",
        )

    def _mapfile(self, path: bytes, size: int, default=b"") -> memoryview:
        """Read a file up to the given size using mmap if possible.

        If this is a new file index, returns default instead.
        """
        if self._is_initial():
            data = default
        else:
            with self._opener(path) as fp:
                if self._opener.is_mmap_safe(path):
                    data = util.mmapread(fp, size)
                else:
                    data = fp.read(size)
        return util.buffer(data)

    def _open_list_file(self, create: bool):
        if create:
            self.docket.list_file_id = file_index_util.Docket.make_id()
            return self._opener(self._list_file_path(), b"wb")
        f = self._opener(self._list_file_path(), b"r+b")
        f.seek(self.docket.list_file_size)
        return f

    def _open_meta_file(self, create: bool):
        if create:
            self.docket.meta_file_id = file_index_util.Docket.make_id()
            return self._opener(self._meta_file_path(), b"wb")
        f = self._opener(self._meta_file_path(), b"r+b")
        f.seek(self.docket.meta_file_size)
        return f

    def _open_tree_file(self, create: bool):
        if create:
            self.docket.tree_file_id = file_index_util.Docket.make_id()
            return self._opener(self._tree_file_path(), b"wb")
        f = self._opener(self._tree_file_path(), b"r+b")
        f.seek(self.docket.tree_file_size)
        return f

    def _read_span(self, offset: int, length: int) -> memoryview:
        """Read a span of bytes from the list file."""
        return self.list_file[offset : offset + length]

    def dump_docket(self, ui, template: bytes):
        if self._is_initial():
            ui.write(_(b"no docket exists yet (empty file index)\n"))
            return
        t = formatter.maketemplater(ui, template or DEFAULT_DOCKET_TEMPLATE)
        values = {
            pycompat.bytestr(k): pycompat.bytestr(v)
            for k, v in attr.asdict(self.docket).items()
        }
        ui.write(t.renderdefault(values))

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

    def _write_data(self, vacuum: bool):
        assert not self._written, "should only write once"
        docket = self.docket
        initial = self._is_initial()
        new_tree = initial or vacuum
        if new_tree:
            tree = file_index_util.MutableTree(base=None)
            for token, meta in enumerate(self.meta_array):
                path = bytes(self._read_span(meta.offset, meta.length))
                tree.insert(path, int_file_index.FileTokenT(token), meta.offset)
        else:
            tree = file_index_util.MutableTree(
                file_index_util.Base(
                    docket=docket,
                    list_file=self.list_file,
                    tree_file=self.tree_file,
                )
            )
        if initial or self._add:
            with (
                self._open_list_file(create=initial) as list_file,
                self._open_meta_file(create=initial) as meta_file,
            ):
                token = len(self.meta_array)
                for path in self._add:
                    offset = docket.list_file_size
                    metadata = file_index_util.Metadata.from_path(path, offset)
                    list_file.write(b"%s\x00" % path)
                    meta_file.write(metadata.serialize())
                    tree.insert(path, int_file_index.FileTokenT(token), offset)
                    docket.list_file_size += len(path) + 1
                    docket.meta_file_size += (
                        file_index_util.Metadata.STRUCT.size
                    )
                    token += 1
        if new_tree or self._add:
            serialized = tree.serialize()
            with self._open_tree_file(create=new_tree) as tree_file:
                tree_file.write(serialized.bytes)
            docket.tree_file_size = serialized.tree_file_size
            docket.tree_root_pointer = serialized.tree_root_pointer
            docket.tree_unused_bytes = serialized.tree_unused_bytes
        docket.reserved_flags = 0


# See debug_file_index in mercurial/debugcommands.py for the opts.
def debug_file_index(ui, repo, **opts):
    """inspect or manipulate the file index"""
    opts = pycompat.byteskwargs(opts)
    template = opts.pop(b"template", None)
    choice = None
    for opt, value in opts.items():
        if value:
            if choice:
                raise error.Abort(
                    _(b"cannot use --%s and --%s together" % (choice, opt))
                )
            choice = opt

    fileindex = repo.store.fileindex
    if fileindex is None:
        raise error.StateError(_(b"this repository does not have a file index"))

    if choice is None:
        for path, token in fileindex.items():
            ui.write(b"%d: %s\n" % (token, path))
    if choice == b"docket":
        fileindex.dump_docket(ui, template)
    elif choice == b"tree":
        fileindex.dump_tree(ui)
    elif choice == b"path":
        path = opts[choice]
        token = fileindex.get_token(path)
        if token is None:
            msg = _(b"path %s is not in the file index" % path)
            raise error.InputError(msg)
        ui.write(b"%d: %s\n" % (token, path))
    elif choice == b"token":
        token = int(opts[choice])
        if not fileindex.has_token(token):
            msg = _(b"token %d is not in the file index" % token)
            raise error.InputError(msg)
        path = fileindex.get_path(token)
        ui.write(b"%d: %s\n" % (token, path))
    elif choice == b"vacuum":
        with repo.lock():
            old_size = fileindex.docket.tree_file_size
            with repo.transaction(b"fileindex-vacuum") as tr:
                fileindex.vacuum(tr)
            new_size = fileindex.docket.tree_file_size
        percent = (old_size - new_size) / old_size * 100
        msg = _(b"vacuumed tree: %s => %s (saved %.01f%%)\n")
        msg %= util.bytecount(old_size), util.bytecount(new_size), percent
        ui.write(msg)
