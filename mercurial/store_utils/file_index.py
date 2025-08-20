"""Implementation of the file index.

See mercurial/interfaces/file_index.py for the high level interface.
See mercurial/helptext/internals/fileindex.txt for format details.
"""

from __future__ import annotations

import abc
import time
import typing

from ..i18n import _
from ..thirdparty import attr
from ..interfaces.types import HgPathT, TransactionT
from ..utils import docket as docketmod
from .. import (
    error,
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

propertycache = util.propertycache

# Values of the config devel.fileindex.vacuum-mode.
VACUUM_MODE_AUTO = b'auto'
VACUUM_MODE_NEVER = b'never'
VACUUM_MODE_ALWAYS = b'always'
ALL_VACUUM_MODES = {VACUUM_MODE_AUTO, VACUUM_MODE_NEVER, VACUUM_MODE_ALWAYS}

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


class _FileIndexCommon(int_file_index.IFileIndex, abc.ABC):
    """
    Methods that are identical for both implementations of the fileindex
    class, with and without Rust extensions enabled.
    """

    def __init__(
        self,
        ui: uimod.ui,
        opener,
        try_pending: bool,
        vacuum_mode: bytes,
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
        self._ui = ui
        self._opener = opener
        self._try_pending = try_pending
        self._vacuum_mode = vacuum_mode
        self._max_unused_ratio = max_unused_ratio
        self._gc_retention_s = gc_retention_s
        self._garbage_timestamp = garbage_timestamp
        self._force_vacuum = False
        self._add_paths: list[HgPathT] = []
        self._add_map: dict[HgPathT, FileTokenT] = {}
        self._remove_tokens: set[FileTokenT] = set()
        self._add_to_garbage: list[HgPathT] = []

    def _token_count(self):
        return len(self.meta_array) + len(self._add_paths)

    def has_token(self, token: FileTokenT):
        return (
            0 <= token < self._token_count()
            and token not in self._remove_tokens
        )

    def has_path(self, path: HgPathT):
        return self.get_token(path) is not None

    def get_path(self, token: FileTokenT):
        if not self.has_token(token):
            return None
        n = len(self.meta_array)
        if token < n:
            return self._get_path_on_disk(token)
        return self._add_paths[token - n]

    @abc.abstractmethod
    def _get_path_on_disk(self, token: FileTokenT) -> HgPathT:
        """Look up a path on disk by token."""

    def get_token(self, path: HgPathT):
        token = self._add_map.get(path)
        if token is not None:
            return token
        token = self._get_token_on_disk(path)
        if token in self._remove_tokens:
            return None
        return token

    @abc.abstractmethod
    def _get_token_on_disk(self, path: HgPathT) -> FileTokenT | None:
        """Look up a path on disk by token."""

    def __contains__(self, path: HgPathT):
        return self.has_path(path)

    def __len__(self):
        return self._token_count() - len(self._remove_tokens)

    def __iter__(self):
        for path, _token in self.items():
            yield path

    def items(self):
        for token in range(self._token_count()):
            path = self.get_path(FileTokenT(token))
            if path is not None:
                yield path, token

    def add(self, path: HgPathT, tr: TransactionT):
        if self._remove_tokens:
            raise error.ProgrammingError(b"cannot add and remove in same txn")
        token = self.get_token(path)
        if token is None:
            token = self._token_count()
            self._add_paths.append(path)
            self._add_map[path] = FileTokenT(token)
            self._register_write(tr)
        return token

    def remove(self, path: HgPathT, tr: TransactionT):
        if self._add_paths:
            raise error.ProgrammingError(b"cannot add and remove in same txn")
        token = self.get_token(path)
        if token is None:
            raise ValueError("path not in file index")
        self._remove_tokens.add(token)
        self._register_write(tr)

    def _register_write(self, tr: TransactionT):
        # If there are external hooks, both callbacks run:
        # - pending: write data files, and write docket with ".pending" suffix
        # - finalize: write docket again without suffix
        # Otherwise, only the finalize callback runs and we do everything then.
        tr.addpending(b"fileindex", self._add_file_generator)
        tr.addfinalize(b"fileindex", self._add_file_generator)

    def vacuum(self, tr: TransactionT):
        if self._add_paths:
            raise error.ProgrammingError(b"manual vacuum should not add files")
        self._force_vacuum = True
        self._add_file_generator(tr)

    def garbage_collect(self, tr: TransactionT, force=False):
        old_entries = self.docket.garbage_entries
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
            self.docket.garbage_entries = new_entries
            self._add_file_generator(tr)

    def data_files(self):
        return [
            b"fileindex",
            self._list_file_path(),
            self._meta_file_path(),
            self._tree_file_path(),
        ]

    def _add_file_generator(self, tr: TransactionT):
        """Add a file generator for writing the file index."""
        tr.addfilegenerator(
            b"fileindex",
            (b"fileindex",),
            lambda f: self._write(f, tr),
            location=b"store",
            # Need post_finalize since we call this in an addfinalize callback.
            post_finalize=True,
        )

    def _write(self, f: typing.BinaryIO, tr: TransactionT):
        """Write all data files and the docket."""
        if self._add_paths or self._remove_tokens or self._force_vacuum:
            self._write_data(tr)
            self._add_paths.clear()
            self._add_map.clear()
            self._remove_tokens.clear()
            self._invalidate_caches()
            self._force_vacuum = False
        if self._add_to_garbage:
            ttl = INITIAL_GARBAGE_TTL
            timestamp = int(time.time())
            if self._garbage_timestamp is not None:
                timestamp = self._garbage_timestamp
            self.docket.garbage_entries.extend(
                file_index_util.GarbageEntry(ttl, timestamp, path)
                for path in self._add_to_garbage
            )
            self._add_to_garbage.clear()
        f.write(self.docket.serialize())

    def _should_vacuum(self) -> bool:
        """Return True if the current write should vacuum the tree file."""
        if self._vacuum_mode == VACUUM_MODE_ALWAYS or self._force_vacuum:
            return True
        if self._vacuum_mode == VACUUM_MODE_NEVER:
            return False
        if self._vacuum_mode == VACUUM_MODE_AUTO:
            size = self.docket.tree_file_size
            if size < AUTO_VACUUM_MIN_SIZE:
                return False
            unused = self.docket.tree_unused_bytes
            return unused / size >= self._max_unused_ratio
        raise error.ProgrammingError(b"invalid file index vacuum mode")

    @abc.abstractmethod
    def _write_data(self, tr: TransactionT):
        """Write all data files and update self.docket."""

    @propertycache
    def docket(self) -> file_index_util.Docket:
        data = None
        if self._try_pending:
            # Written by transaction.writepending.
            data = self._opener.tryread(b"fileindex.pending")
        if not data:
            try:
                data = self._opener.read(b"fileindex")
            except FileNotFoundError:
                return file_index_util.Docket()
        return file_index_util.Docket.parse_from(data)

    def _list_file_path(self):
        return b"fileindex-list." + self.docket.list_file_id

    def _meta_file_path(self):
        return b"fileindex-meta." + self.docket.meta_file_id

    def _tree_file_path(self):
        return b"fileindex-tree." + self.docket.tree_file_id

    @propertycache
    def list_file(self):
        if self.docket.list_file_id == docketmod.UNSET_UID:
            return b""
        return self._mapfile(self._list_file_path(), self.docket.list_file_size)

    @propertycache
    def meta_file(self):
        if self.docket.meta_file_id == docketmod.UNSET_UID:
            return b""
        return self._mapfile(self._meta_file_path(), self.docket.meta_file_size)

    @propertycache
    def meta_array(self):
        return file_index_util.MetadataArray(self.meta_file)

    @propertycache
    def tree_file(self):
        testing.wait_on_cfg(self._ui, b"fileindex.pre-read-tree-file")
        if self.docket.meta_file_id == docketmod.UNSET_UID:
            return file_index_util.EMPTY_TREE_BYTES
        return self._mapfile(self._tree_file_path(), self.docket.tree_file_size)

    def _invalidate_caches(self):
        util.clearcachedproperty(self, b"list_file")
        util.clearcachedproperty(self, b"meta_file")
        util.clearcachedproperty(self, b"meta_array")
        util.clearcachedproperty(self, b"tree_file")

    def _mapfile(self, path: bytes, size: int) -> memoryview:
        """Read a file up to the given size using mmap if possible."""
        with self._opener(path) as fp:
            if self._opener.is_mmap_safe(path):
                data = util.mmapread(fp, size)
            else:
                data = fp.read(size)
        return util.buffer(data)

    def _open_list_file(self, new: bool, tr: TransactionT):
        if new:
            if self.docket.list_file_id != docketmod.UNSET_UID:
                self._add_to_garbage.append(self._list_file_path())
            self.docket.list_file_id = docketmod.make_uid()
            self.docket.list_file_size = 0
            return self._open_new(self._list_file_path(), tr)
        return self._open_for_appending(
            self._list_file_path(), self.docket.list_file_size
        )

    def _open_meta_file(self, new: bool, tr: TransactionT):
        if new:
            if self.docket.meta_file_id != docketmod.UNSET_UID:
                self._add_to_garbage.append(self._meta_file_path())
            self.docket.meta_file_id = docketmod.make_uid()
            self.docket.meta_file_size = 0
            return self._open_new(self._meta_file_path(), tr)
        return self._open_for_appending(
            self._meta_file_path(), self.docket.meta_file_size
        )

    def _open_tree_file(self, new: bool, tr: TransactionT):
        if new:
            if self.docket.tree_file_id != docketmod.UNSET_UID:
                self._add_to_garbage.append(self._tree_file_path())
            self.docket.tree_file_id = docketmod.make_uid()
            self.docket.tree_file_size = 0
            return self._open_new(self._tree_file_path(), tr)
        return self._open_for_appending(
            self._tree_file_path(), self.docket.tree_file_size
        )

    def _open_new(self, path: HgPathT, tr: TransactionT):
        """Open a new file for writing.

        This adds the file to the transaction so that it will be removed if we
        later abort or rollback.
        """
        tr.add(path, 0)
        return self._opener(path, b"wb")

    def _open_for_appending(self, path: HgPathT, used_size: int):
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
        return self.list_file[offset : offset + length]

    def dump_docket(self, ui, template: bytes):
        opts = {b"template": template or DEFAULT_DOCKET_TEMPLATE}
        with ui.formatter(b"file-index", opts) as fm:
            fm.startitem()
            values = attr.asdict(self.docket)
            del values["garbage_entries"]
            fm.data(**values)
            with fm.nested(b"garbage_entries") as fm_garbage:
                for entry in self.docket.garbage_entries:
                    fm_garbage.startitem()
                    fm_garbage.data(**attr.asdict(entry))

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

    def _get_path_on_disk(self, token: FileTokenT):
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

    def _write_data(self, tr: TransactionT):
        docket = self.docket
        removing = bool(self._remove_tokens)
        new_list = docket.list_file_id == docketmod.UNSET_UID or removing
        new_meta = docket.meta_file_id == docketmod.UNSET_UID or removing
        new_tree = docket.tree_file_id == docketmod.UNSET_UID or removing
        new_tree = new_tree or self._should_vacuum()
        meta_array = self.meta_array
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
                    list_file=self.list_file,
                    tree_file=self.tree_file,
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
    elif choice == b"gc":
        with repo.lock(), repo.transaction(b"fileindex-gc") as tr:
            fileindex.garbage_collect(tr, force=True)
