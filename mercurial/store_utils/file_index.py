"""Implementation of the file index.

See mercurial/interfaces/file_index.py for the high level interface.
See mercurial/helptext/internals/fileindex.txt for format details.
"""

from __future__ import annotations

import time
import typing

from typing import BinaryIO, Iterator

from ..i18n import _
from ..thirdparty import attr
from ..interfaces.types import HgPathT, TransactionT
from ..utils import docket as docketmod
from .. import (
    error,
    policy,
    pycompat,
    testing,
    ui as uimod,
    util,
)
from ..interfaces import file_index as int_file_index
from . import file_index_util

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

FileTokenT = int_file_index.FileTokenT
VacuumMode = int_file_index.VacuumMode

rustmod = policy.importrust("file_index")

HAS_FAST_FILE_INDEX = rustmod is not None

# Minimum size of the tree file in bytes before auto-vacuuming starts.
#
# The value was picked by adding files one by one in individual transaction.
# 16K allows for adding 100 files before tree file is shrink down to 1.5K
AUTO_VACUUM_MIN_SIZE = 16 * 1024

# Initial TTL when adding a file to garbage_entries. Each hg transaction that
# follows will decrement it by 1, and will not delete it until it reaches 0.
INITIAL_GARBAGE_TTL = 2

DEFAULT_DOCKET_TEMPLATE = b"""\
marker: {marker}
list_file_size: {list_file_size}
reserved_revlog_size: {reserved_revlog_size}
meta_file_size: {meta_file_size}
tree_file_size: {tree_file_size}
list_file_id: {list_file_id}
reserved_revlog_id: {reserved_revlog_id}
meta_file_id: {meta_file_id}
tree_file_id: {tree_file_id}
tree_root_pointer: {tree_root_pointer}
tree_unused_bytes: {tree_unused_bytes}
reserved_revlog_unused: {reserved_revlog_unused}
reserved_flags: {reserved_flags}
garbage_entries: {garbage_entries|count}
{garbage_entries % "- ttl={ttl} timestamp={timestamp} path={path}\n"}\
"""


class FileIndex(int_file_index.IFileIndex):
    """
    Methods that are identical for both implementations of the fileindex
    class, with and without Rust extensions enabled.
    """

    def __init__(
        self,
        ui: uimod.ui,
        opener,
        try_pending: bool,
        vacuum_mode: VacuumMode,
        max_unused_ratio: float,
        gc_retention_s: int,
        garbage_timestamp: int | None,
    ):
        """
        If try_pending is True, tries opening the docket with the ".pending"
        suffix, falling back to the normal docket path.
        """
        if not 0 <= max_unused_ratio <= 100:
            raise error.ProgrammingError(b"invalid max_unused_ratio")
        self._opener = opener
        self._vacuum_mode = vacuum_mode
        self._max_unused_ratio = max_unused_ratio
        self._gc_retention_s = gc_retention_s
        self._garbage_timestamp = garbage_timestamp
        self._force_vacuum = False
        self._add_paths: list[HgPathT] = []
        self._add_map: dict[HgPathT, FileTokenT] = {}
        self._remove_tokens: set[FileTokenT] = set()
        self._add_to_garbage: list[HgPathT] = []
        self._docket = FileIndex._load_docket(opener, try_pending)
        testing.wait_on_cfg(ui, b"fileindex.pre-read-data-files")
        self._load_data_files()

    def _token_count(self) -> int:
        return len(self._meta_array) + len(self._add_paths)

    def has_token(self, token: FileTokenT) -> bool:
        return (
            0 <= token < self._token_count()
            and token not in self._remove_tokens
        )

    def has_path(self, path: HgPathT) -> bool:
        return self.get_token(path) is not None

    def get_path(self, token: FileTokenT) -> HgPathT | None:
        if not self.has_token(token):
            return None
        n = len(self._meta_array)
        if token < n:
            return self._get_path_on_disk(token)
        return self._add_paths[token - n]

    def get_token(self, path: HgPathT) -> FileTokenT | None:
        token = self._add_map.get(path)
        if token is not None:
            return token
        token = self._get_token_on_disk(path)
        if token in self._remove_tokens:
            return None
        return token

    def __contains__(self, path: HgPathT) -> bool:
        return self.has_path(path)

    def __len__(self) -> int:
        return self._token_count() - len(self._remove_tokens)

    def __iter__(self) -> Iterator[HgPathT]:
        for path, _token in self.items():
            yield path

    def items(self) -> Iterator[tuple[HgPathT, FileTokenT]]:
        for token in range(self._token_count()):
            path = self.get_path(FileTokenT(token))
            if path is not None:
                yield path, FileTokenT(token)

    def add(self, path: HgPathT, tr: TransactionT) -> FileTokenT:
        if self._remove_tokens:
            raise error.ProgrammingError(b"cannot add and remove in same txn")
        token = self.get_token(path)
        if token is None:
            token = FileTokenT(self._token_count())
            self._add_paths.append(path)
            self._add_map[path] = token
            self._add_file_generator(tr)
        return token

    def remove(self, path: HgPathT, tr: TransactionT):
        if self._add_paths:
            raise error.ProgrammingError(b"cannot add and remove in same txn")
        token = self.get_token(path)
        if token is None:
            raise ValueError("path not in file index")
        self._remove_tokens.add(token)
        self._add_file_generator(tr)

    def vacuum(self, tr: TransactionT):
        if self._add_paths:
            raise error.ProgrammingError(b"manual vacuum should not add files")
        self._force_vacuum = True
        self._add_file_generator(tr)

    def garbage_collect(self, tr: TransactionT, force=False):
        old_entries = self._docket.garbage_entries
        if not old_entries:
            return

        now = int(time.time())

        def eligible_for_gc(entry):
            if entry.ttl > 0:
                return False
            # Make zero a special case so timing never affects it.
            if self._gc_retention_s == 0:
                return True
            return now > entry.timestamp + self._gc_retention_s

        new_entries = []
        changed = False
        for entry in old_entries:
            if entry.ttl > 0:
                entry.ttl -= 1
                changed = True
            if force or eligible_for_gc(entry):
                self._opener.tryunlink(entry.path)
                changed = True
            else:
                new_entries.append(entry)
        if changed:
            self._docket.garbage_entries = new_entries
            self._add_file_generator(tr)

    def data_files(self) -> list[HgPathT]:
        paths = [
            b"fileindex",
            self._list_file_path(),
            self._meta_file_path(),
            self._tree_file_path(),
        ]
        return [p for p in paths if p is not None]

    def debug_docket(self) -> dict[str, typing.Any]:
        return attr.asdict(self._docket)

    def debug_tree_file_size(self) -> int:
        return self._docket.tree_file_size

    def debug_iter_tree_nodes(self) -> Iterator[int_file_index.DebugTreeNode]:
        tree = self._tree_file

        def recur(pointer):
            node = file_index_util.TreeNode.parse_from(tree[pointer:])
            edges = []
            for edge in node.edges:
                label = self._read_span(edge.label_offset, edge.label_length)
                edges.append((label, edge.node_pointer))
            yield (pointer, node.token, edges)
            for edge in node.edges:
                yield from recur(edge.node_pointer)

        yield from recur(self._docket.tree_root_pointer)

    def _add_file_generator(self, tr: TransactionT):
        """Add a file generator for writing the file index."""
        tr.addfilegenerator(
            b"fileindex",
            (b"fileindex",),
            lambda f: self._write(f, tr),
            location=b"store",
            # Need post_finalize since we do garbage_collect in an addfinalize
            # callback, and we want to write the docket after that.
            post_finalize=True,
        )

    def _write(self, f: BinaryIO, tr: TransactionT):
        """Write all data files and the docket."""
        if self._add_paths or self._remove_tokens or self._force_vacuum:
            self._write_data(tr)
            self._add_paths.clear()
            self._add_map.clear()
            self._remove_tokens.clear()
            self._load_data_files()
            self._force_vacuum = False
        if self._add_to_garbage:
            ttl = INITIAL_GARBAGE_TTL
            timestamp = int(time.time())
            if self._garbage_timestamp is not None:
                timestamp = self._garbage_timestamp
            self._docket.garbage_entries.extend(
                file_index_util.GarbageEntry(ttl, timestamp, path)
                for path in self._add_to_garbage
            )
            self._add_to_garbage.clear()
        f.write(self._docket.serialize())

    def _should_vacuum(self) -> bool:
        """Return True if the current write should vacuum the tree file."""
        if self._vacuum_mode == VacuumMode.ALWAYS or self._force_vacuum:
            return True
        if self._vacuum_mode == VacuumMode.NEVER:
            return False
        if self._vacuum_mode == VacuumMode.AUTO:
            size = self._docket.tree_file_size
            if size < AUTO_VACUUM_MIN_SIZE:
                return False
            unused = self._docket.tree_unused_bytes
            return unused / size >= self._max_unused_ratio
        raise error.ProgrammingError(b"invalid file index vacuum mode")

    @staticmethod
    def _load_docket(opener, try_pending: bool) -> file_index_util.Docket:
        data = None
        if try_pending:
            # Written by transaction.writepending.
            data = opener.tryread(b"fileindex.pending")
        if not data:
            try:
                data = opener.read(b"fileindex")
            except FileNotFoundError:
                return file_index_util.Docket()
        return file_index_util.Docket.parse_from(data)

    def _list_file_path(self) -> HgPathT | None:
        id = self._docket.list_file_id
        if id == docketmod.UNSET_UID:
            return None
        return b"fileindex-list." + id

    def _meta_file_path(self) -> HgPathT | None:
        id = self._docket.meta_file_id
        if id == docketmod.UNSET_UID:
            return None
        return b"fileindex-meta." + id

    def _tree_file_path(self) -> HgPathT | None:
        id = self._docket.tree_file_id
        if id == docketmod.UNSET_UID:
            return None
        return b"fileindex-tree." + id

    def _load_data_files(self):
        self._list_file = self._load_list_file()
        self._meta_array = self._load_meta_array()
        self._tree_file = self._load_tree_file()

    def _load_list_file(self) -> memoryview:
        path = self._list_file_path()
        if path is None:
            return util.buffer(b"")
        return self._mapfile(path, self._docket.list_file_size)

    def _load_meta_file(self) -> memoryview:
        path = self._meta_file_path()
        if path is None:
            return util.buffer(b"")
        return self._mapfile(path, self._docket.meta_file_size)

    def _load_meta_array(self) -> file_index_util.MetadataArray:
        return file_index_util.MetadataArray(self._load_meta_file())

    def _load_tree_file(self) -> memoryview:
        path = self._tree_file_path()
        if path is None:
            return util.buffer(file_index_util.EMPTY_TREE_BYTES)
        return self._mapfile(path, self._docket.tree_file_size)

    def _mapfile(self, path: bytes, size: int) -> memoryview:
        """Read a file up to the given size using mmap if possible."""
        with self._opener(path) as fp:
            if self._opener.is_mmap_safe(path):
                data = util.mmapread(fp, size)
            else:
                data = fp.read(size)
        return util.buffer(data)

    def _open_list_file(self, new: bool, tr: TransactionT) -> BinaryIO:
        docket = self._docket
        path = self._list_file_path()
        if new:
            if path is not None:
                self._add_to_garbage.append(path)
            docket.list_file_id = docketmod.make_uid()
            docket.list_file_size = 0
            path = self._list_file_path()
            assert path is not None
            return self._open_new(path, tr)
        assert path is not None
        return self._open_for_appending(path, docket.list_file_size)

    def _open_meta_file(self, new: bool, tr: TransactionT) -> BinaryIO:
        docket = self._docket
        path = self._meta_file_path()
        if new:
            if path is not None:
                self._add_to_garbage.append(path)
            docket.meta_file_id = docketmod.make_uid()
            docket.meta_file_size = 0
            path = self._meta_file_path()
            assert path is not None
            return self._open_new(path, tr)
        assert path is not None
        return self._open_for_appending(path, docket.meta_file_size)

    def _open_tree_file(self, new: bool, tr: TransactionT) -> BinaryIO:
        docket = self._docket
        path = self._tree_file_path()
        if new:
            if path is not None:
                self._add_to_garbage.append(path)
            docket.tree_file_id = docketmod.make_uid()
            docket.tree_file_size = 0
            path = self._tree_file_path()
            assert path is not None
            return self._open_new(path, tr)
        assert path is not None
        return self._open_for_appending(path, docket.tree_file_size)

    def _open_new(self, path: HgPathT, tr: TransactionT) -> BinaryIO:
        """Open a new file for writing.

        This adds the file to the transaction so that it will be removed if we
        later abort or rollback.
        """
        tr.add(path, 0)
        return self._opener(path, b"wb")

    def _open_for_appending(self, path: HgPathT, used_size: int) -> BinaryIO:
        """Open a file for appending past used_size.

        Despite "appending", this doesn't open in append mode because the
        physical size of the file may be larger than used_size.

        Unlike _open_new, this doesn't add the file to the transaction. If we
        rollback, there's no need to truncate since the docket stores used_size.
        """
        f = self._opener(path, b"r+b")
        f.seek(used_size)
        return f

    def _read_span(self, offset: int, length: int) -> memoryview:
        """Read a span of bytes from the list file."""
        return self._list_file[offset : offset + length]

    def _get_path_on_disk(self, token: FileTokenT) -> HgPathT:
        """Look up a path on disk by token."""
        meta = self._meta_array[token]
        return bytes(self._read_span(meta.offset, meta.length))

    def _get_token_on_disk(self, path: HgPathT) -> FileTokenT | None:
        """Look up a path on disk by token."""
        tree_file = self._tree_file
        node = file_index_util.TreeNode.parse_from(
            tree_file[self._docket.tree_root_pointer :]
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

    def _write_data(self, tr: TransactionT):
        """Write all data files and update self._docket."""
        docket = self._docket
        removing = bool(self._remove_tokens)
        new_list = docket.list_file_id == docketmod.UNSET_UID or removing
        new_meta = docket.meta_file_id == docketmod.UNSET_UID or removing
        new_tree = docket.tree_file_id == docketmod.UNSET_UID or removing
        new_tree = new_tree or self._should_vacuum()
        meta_array = self._meta_array
        add_paths = self._add_paths
        if add_paths and removing:
            raise error.ProgrammingError(b"cannot add and remove in same txn")
        if removing:
            meta_array = []
            add_paths = list(self)
        if new_tree:
            tree = file_index_util.MutableTree(base=None)
            for token, meta in enumerate(meta_array):
                path = bytes(self._read_span(meta.offset, meta.length))
                tree.insert(path, FileTokenT(token), meta.offset)
        else:
            tree = file_index_util.MutableTree(
                file_index_util.Base(
                    docket=docket,
                    list_file=self._list_file,
                    tree_file=self._tree_file,
                )
            )
        with (
            self._open_list_file(new_list, tr) as list_file,
            self._open_meta_file(new_meta, tr) as meta_file,
        ):
            token = len(meta_array)
            for path in add_paths:
                offset = docket.list_file_size
                metadata = file_index_util.Metadata.from_path(path, offset)
                list_file.write(b"%s\x00" % path)
                meta_file.write(metadata.serialize())
                tree.insert(path, FileTokenT(token), offset)
                docket.list_file_size += len(path) + 1
                docket.meta_file_size += file_index_util.Metadata.STRUCT.size
                token += 1
        serialized = tree.serialize()
        with self._open_tree_file(new_tree, tr) as tree_file:
            tree_file.write(serialized.bytes)
        docket.tree_file_size = serialized.tree_file_size
        docket.tree_root_pointer = serialized.tree_root_pointer
        docket.tree_unused_bytes = serialized.tree_unused_bytes
        docket.reserved_flags = 0


if rustmod is not None:
    FileIndex = rustmod.FileIndex


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
    elif choice == b"docket":
        formatter_opts = {b"template": template or DEFAULT_DOCKET_TEMPLATE}
        with ui.formatter(b"file-index", formatter_opts) as fm:
            fm.startitem()
            values = fileindex.debug_docket()
            garbage_entries = values.pop("garbage_entries")
            fm.data(**values)
            with fm.nested(b"garbage_entries") as fm_garbage:
                for entry in garbage_entries:
                    fm_garbage.startitem()
                    fm_garbage.data(**entry)
    elif choice == b"tree":
        for pointer, token, edges in fileindex.debug_iter_tree_nodes():
            token_str = b""
            if token is not None:
                token_str = b" token = %d" % token
            ui.write(b"%08x:%s\n" % (pointer, token_str))
            for label, pointer in edges:
                ui.write(b'    "%s" -> %08x\n' % (label, pointer))
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
            old_size = fileindex.debug_tree_file_size()
            with repo.transaction(b"fileindex-vacuum") as tr:
                fileindex.vacuum(tr)
            new_size = fileindex.debug_tree_file_size()
        percent = (old_size - new_size) / old_size * 100
        msg = _(b"vacuumed tree: %s => %s (saved %.01f%%)\n")
        msg %= util.bytecount(old_size), util.bytecount(new_size), percent
        ui.write(msg)
    elif choice == b"gc":
        with repo.lock(), repo.transaction(b"fileindex-gc") as tr:
            fileindex.garbage_collect(tr, force=True)
