# vfs.py - Mercurial 'vfs' classes
#
#  Copyright Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import contextlib
import os
import shutil
import stat
import threading
import typing

from typing import (
    Any,
    BinaryIO,
    Callable,
    Iterable,
    Iterator,
    Literal,
    MutableMapping,
    Optional,
    Protocol,
    TypeVar,
    overload,
)

from .i18n import _
from . import (
    encoding,
    error,
    pathutil,
    pycompat,
    util,
)
from .interfaces import vfs as i_vfs

if typing.TYPE_CHECKING:
    from .interfaces.types import (
        FsPathT,
        HgPathT,
        UiT,
    )

    _Tbackgroundfilecloser = TypeVar(
        '_Tbackgroundfilecloser', bound='backgroundfilecloser'
    )
    _Tclosewrapbase = TypeVar('_Tclosewrapbase', bound='closewrapbase')
    _OnErrorFn = Callable[[Exception], Optional[object]]

    # For some reason, pytype got confused by using ParamSpec, and demoted
    # some (but not all) decorated methods to Callable with no defined args.
    # This manages to preserve all methods, even including the variable names.
    _C = TypeVar('_C', bound=Callable)
    """An unconstrained Callable, for when a method takes a method with any
    signature, and returns a method with an identical signature.
    """


def _avoidambig(path: bytes, oldstat: util.filestat) -> None:
    """Avoid file stat ambiguity forcibly

    This function causes copying ``path`` file, if it is owned by
    another (see issue5418 and issue5584 for detail).
    """

    def checkandavoid():
        newstat = util.filestat.frompath(path)
        # return whether file stat ambiguity is (already) avoided
        return not newstat.isambig(oldstat) or newstat.avoidambig(path, oldstat)

    if not checkandavoid():
        # simply copy to change owner of path to get privilege to
        # advance mtime (see issue5418)
        util.rename(util.mktempcopy(path), path)
        checkandavoid()


class abstractvfs(i_vfs.IVfs):
    """Abstract base class; cannot be instantiated"""

    # default directory separator for vfs
    #
    # Other vfs code always use `/` and this works fine because python file API
    # abstract the use of `/` and make it work transparently. For consistency
    # vfs will always use `/` when joining. This avoids some confusion in
    # encoded vfs (see issue6546)
    _dir_sep: bytes = b'/'

    # Used to disable the Rust `InnerRevlog` in case the VFS is not supported
    # by the Rust code
    rust_compatible: bool = True

    # createmode is always available on subclasses
    createmode: int | None

    _chmod: bool

    base: FsPathT

    # Expose the read_write vs read_only status.
    #
    # This mostly exist to help the Rust extensions to easily propagate vfs
    # information, to the Rust side. This can probably be removed in the future
    # when Rust no longer needs it.
    read_write: bool = True

    # The name of the encoding used if any
    #
    # Mostly exist to help the Rust extension to identify the encoding it needs
    # to use.
    # This can probably be removed in the future when Rust no longer needs it.
    filter_name: str | None = None

    if typing.TYPE_CHECKING:

        @overload
        def __call__(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: Literal[False] = ...,
            **kwargs,
        ) -> BinaryIO:
            ...

        @overload
        def __call__(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: Literal[True],
            **kwargs,
        ) -> i_vfs.IAtomicTempFile:
            ...

        @overload
        def __call__(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: bool,
            **kwargs,
        ) -> BinaryIO | i_vfs.IAtomicTempFile:
            ...

    @abc.abstractmethod
    def __call__(
        self,
        path: HgPathT,
        mode: bytes = b'rb',
        **kwargs,
    ) -> BinaryIO | i_vfs.IAtomicTempFile:
        """Open ``path`` file, which is relative to vfs root.

        With ``atomictemp=True``, the file is written atomically, see
        IAtomicTempFile.

        By default, parent directories are created as needed. Newly created
        directories are marked as "not to be indexed by the content indexing
        service", if ``notindexed`` is specified for "write" mode access.
        Set ``makeparentdirs=False`` to not create directories implicitly.

        If ``backgroundclose`` is passed, the file may be closed asynchronously.
        It can only be used if the ``self.backgroundclosing()`` context manager
        is active. This should only be specified if the following criteria hold:

        1. There is a potential for writing thousands of files. Unless you
           are writing thousands of files, the performance benefits of
           asynchronously closing files is not realized.
        2. Files are opened exactly once for the ``backgroundclosing``
           active duration and are therefore free of race conditions between
           closing a file on a background thread and reopening it. (If the
           file were opened multiple times, there could be unflushed data
           because the original file handle hasn't been flushed/closed yet.)

        ``checkambig`` argument is passed to atomictempfile (valid
        only for writing), and is useful only if target file is
        guarded by any lock (e.g. repo.lock or repo.wlock).

        To avoid file stat ambiguity forcibly, checkambig=True involves
        copying ``path`` file opened in "append" mode (e.g. for
        truncation), if it is owned by another. Therefore, use
        combination of append mode and checkambig=True only in limited
        cases (see also issue5418 and issue5584 for detail).
        """

    @abc.abstractmethod
    def _auditpath(self, path: bytes, mode: bytes) -> None:
        ...

    @abc.abstractmethod
    def join(self, path: HgPathT | None, *insidef: HgPathT) -> FsPathT:
        """return the file system path for ``path`` (joined with ``insidef``)

        The vfs "base" is returned if ``path`` is empty.
        """

    def tryread(
        self,
        path: HgPathT,
        mmap_threshold: int | None = None,
        size: int | None = None,
    ) -> bytes:
        '''gracefully return an empty string for missing files'''
        try:
            return self.read(path, mmap_threshold, size)
        except FileNotFoundError:
            pass
        return b""

    def tryreadlines(self, path: HgPathT, mode: bytes = b'rb') -> list[bytes]:
        '''gracefully return an empty list for missing files'''
        try:
            return self.readlines(path, mode=mode)
        except FileNotFoundError:
            pass
        return []

    @util.propertycache
    def open(self):
        """Open ``path`` file, which is relative to vfs root.

        Newly created directories are marked as "not to be indexed by
        the content indexing service", if ``notindexed`` is specified
        for "write" mode access.
        """
        return self.__call__

    def wopen(self, path: HgPathT, **kwargs) -> BinaryIO:
        """Open ``path`` file, relative to vfs root for writing

        If the file is missing, create it.
        """
        try:
            return self(path, mode=b"r+", **kwargs)
        except FileNotFoundError:
            return self(path, mode=b"w+", **kwargs)

    def read(
        self,
        path: HgPathT,
        mmap_threshold: int | None = None,
        size: int | None = None,
    ) -> bytes:
        """return the content of the ``path`` file

        If ``size`` is set, read at most that many bytes.

        If the file is at least ``mmap_threshold`` bytes long (and mmap is safe
        for it), return a buffer over a memory map of the file instead of
        reading it.
        """
        with self(path, b'rb') as fp:
            if mmap_threshold is not None:
                file_size = self.fstat(fp).st_size
                if file_size >= mmap_threshold and self.is_mmap_safe(path):
                    if size is not None:
                        # avoid potentiel mmap crash
                        size = min(file_size, size)
                    # TODO: should .close() to release resources without
                    # relying on Python GC
                    if size is None:
                        return util.buffer(util.mmapread(fp))
                    else:
                        return util.buffer(util.mmapread(fp, size))
            if size is None:
                return fp.read()
            else:
                return fp.read(size)

    def readlines(self, path: HgPathT, mode: bytes = b'rb') -> list[bytes]:
        """return the content of the ``path`` file as a list of lines

        The lines keep their end-of-line characters.
        """
        with self(path, mode=mode) as fp:
            return fp.readlines()

    def write(
        self,
        path: HgPathT,
        data: bytes,
        backgroundclose: bool = False,
        **kwargs,
    ) -> int:
        """replace the content of the ``path`` file with ``data``

        Return the number of bytes written.

        ``backgroundclose`` and the other keyword arguments are passed to
        ``__call__``.
        """
        with self(path, b'wb', backgroundclose=backgroundclose, **kwargs) as fp:
            return fp.write(data)

    def writelines(
        self,
        path: HgPathT,
        data: Iterable[bytes],
        mode: bytes = b'wb',
        notindexed: bool = False,
    ) -> None:
        """write the ``data`` lines into the ``path`` file

        No end-of-line characters are added. The file is overwritten unless
        another ``mode`` is specified (e.g. ``b'ab'`` to append).
        """
        with self(path, mode=mode, notindexed=notindexed) as fp:
            return fp.writelines(data)

    def append(self, path: HgPathT, data: bytes) -> int:
        """add ``data`` at the end of the ``path`` file

        The file is created if missing. Return the number of bytes written.
        """
        with self(path, b'ab') as fp:
            return fp.write(data)

    def basename(self, path: HgPathT) -> HgPathT:
        """return base element of a path (as os.path.basename would do)

        This exists to allow handling of strange encoding if needed."""
        return os.path.basename(path)

    def chmod(self, path: HgPathT, mode: int) -> None:
        """change the permissions of the ``path`` file (as os.chmod would do)"""
        return os.chmod(self.join(path), mode)

    def dirname(self, path: HgPathT) -> HgPathT:
        """return dirname element of a path (as os.path.dirname would do)

        This exists to allow handling of strange encoding if needed."""
        return os.path.dirname(path)

    def exists(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) exists

        Symlinks are followed (as os.path.exists would do).
        """
        return os.path.exists(self.join(path))

    def fstat(self, fp: BinaryIO) -> os.stat_result:
        """stat an open file object, even one without a ``fileno`` method"""
        return util.fstat(fp)

    def isdir(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a directory

        Symlinks are followed (as os.path.isdir would do).
        """
        return os.path.isdir(self.join(path))

    def isfile(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a regular file

        Symlinks are followed (as os.path.isfile would do).
        """
        return os.path.isfile(self.join(path))

    def islink(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a symlink"""
        return os.path.islink(self.join(path))

    def isfileorlink(self, path: HgPathT | None = None) -> bool:
        """return whether path is a regular file or a symlink

        Unlike isfile, this doesn't follow symlinks."""
        try:
            st = self.lstat(path)
        except OSError:
            return False
        mode = st.st_mode
        return stat.S_ISREG(mode) or stat.S_ISLNK(mode)

    def _join(self, *paths: bytes) -> bytes:
        root_idx = 0
        for idx, p in enumerate(paths):
            if os.path.isabs(p) or p.startswith(self._dir_sep):
                root_idx = idx
        if root_idx != 0:
            paths = paths[root_idx:]
        paths = [p for p in paths if p]
        return self._dir_sep.join(paths)

    def reljoin(self, *paths: HgPathT) -> HgPathT:
        """join various elements of a path together (as os.path.join would do)

        The vfs base is not injected so that paths stay relative. This exists
        to allow handling of strange encoding if needed."""
        return self._join(*paths)

    def split(self, path: HgPathT) -> tuple[HgPathT, HgPathT]:
        """split top-most element of a path (as os.path.split would do)

        This exists to allow handling of strange encoding if needed."""
        return os.path.split(path)

    def lexists(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) exists

        Symlinks are not followed, so a broken symlink exists (as
        os.path.lexists would do).
        """
        return os.path.lexists(self.join(path))

    def lstat(self, path: HgPathT | None = None) -> os.stat_result:
        """return the stat of ``path`` (or the vfs base)

        Symlinks are not followed (as os.lstat would do).
        """
        return os.lstat(self.join(path))

    def is_mmap_safe(self, path: HgPathT | None = None) -> bool:
        """return True if it is safe to read a file content as mmap

        This focuses on the file system aspect of such safety, the application
        logic around that file is not taken into account, so callers need to
        make sure the file won't be truncated in a way that will create SIGBUS
        on access.

        The initial motivation for this logic is that if mmap is used on NFS
        and somebody deletes the mapped file (e.g. by renaming on top of it),
        then you get SIGBUS, which can be pretty disruptive: we get core dump
        reports, and the process terminates without writing to the blackbox.

        Instead, in this situation we prefer to read the file normally.
        The risk of ESTALE in the middle of the read remains, but it's
        smaller because we read sooner and the error should be reported
        just as any other error.

        Note that python standard library does not offer the necessary function
        to detect the file system bits. So this detection relies on compiled
        bits and is not available in pure python.
        """
        # XXX Since we already assume a vfs to address a consistent file system
        # in other location, we could determine the fstype once for the root
        # and cache that value.
        fstype = util.getfstype(self.join(path))
        return fstype is not None and fstype != b'nfs'

    def listdir(self, path: HgPathT | None = None) -> list[bytes]:
        """return the names of the entries in the ``path`` directory

        When ``path`` is None, the vfs "base" is used.

        This behaves as os.listdir would."""
        return os.listdir(self.join(path))

    def makedir(
        self,
        path: HgPathT | None = None,
        notindexed: bool = True,
    ) -> None:
        """create the ``path`` directory (its parent must exist)

        If ``notindexed`` is set, the directory is marked as "not to be indexed
        by the content indexing service" (on platforms supporting it).
        """
        return util.makedir(self.join(path), notindexed)

    def makedirs(
        self,
        path: HgPathT | None = None,
        mode: int | None = None,
    ) -> None:
        """create the ``path`` directory and any missing parent directory

        Does nothing if the directory already exists.

        If ``mode`` is set, it is applied to the ``path`` directory.
        """
        return util.makedirs(self.join(path), mode)

    def makelock(self, info: bytes, path: HgPathT) -> None:
        """atomically create the ``path`` lock file holding ``info``

        The lock is a symlink pointing to ``info`` if possible, a regular file
        containing it otherwise. Fails if ``path`` already exists.
        """
        return util.makelock(info, self.join(path))

    def mkdir(self, path: HgPathT | None = None) -> None:
        """create the ``path`` directory (as os.mkdir would do)"""
        return os.mkdir(self.join(path))

    def mkstemp(
        self,
        suffix: bytes = b'',
        prefix: bytes = b'tmp',
        dir: HgPathT | None = None,
    ) -> tuple[int, HgPathT]:
        """create a new temporary file in the ``dir`` directory (or the vfs
        base), as tempfile.mkstemp would do

        Return ``(fd, path)`` where ``fd`` is an open file descriptor for the
        file and ``path`` its path relative to the vfs base.
        """
        fd, name = pycompat.mkstemp(
            suffix=suffix, prefix=prefix, dir=self.join(dir)
        )
        dname, fname = util.split(name)
        if dir:
            return fd, os.path.join(dir, fname)
        else:
            return fd, fname

    if typing.TYPE_CHECKING:

        @overload
        def readdir(
            self,
            path: HgPathT | None = None,
            stat: Literal[False] = ...,
            skip: bytes | None = None,
        ) -> list[tuple[bytes, int]]:
            ...

        @overload
        def readdir(
            self,
            path: HgPathT | None = None,
            stat: Literal[True] = ...,
            skip: bytes | None = None,
        ) -> list[tuple[bytes, int, os.stat_result]]:
            ...

    # note: the cext returns its own stat object, with a subset of the
    # `os.stat_result` attributes.
    def readdir(
        self,
        path: HgPathT | None = None,
        stat: bool = False,
        skip: bytes | None = None,
    ) -> list[tuple[bytes, int]] | list[tuple[bytes, int, os.stat_result]]:
        """return a sorted list of (name, kind) for the entries of the
        ``path`` directory (or the vfs base)

        ``kind`` is the file type, as a ``stat.S_IF*`` constant. If ``stat``
        is True, (name, kind, stat) tuples are returned instead.

        If the directory contains a ``skip`` sub-directory, an empty list is
        returned.
        """
        return util.listdir(self.join(path), stat, skip)

    def readlock(self, path: HgPathT) -> bytes:
        """return the ``info`` held by the ``path`` lock file (see makelock)"""
        return util.readlock(self.join(path))

    def rename(
        self,
        src: HgPathT,
        dst: HgPathT,
        checkambig: bool = False,
    ) -> None:
        """rename the ``src`` file to ``dst``, replacing ``dst`` if it exists

        checkambig argument is used with util.filestat, and is useful
        only if destination file is guarded by any lock
        (e.g. repo.lock or repo.wlock).

        To avoid file stat ambiguity forcibly, checkambig=True involves
        copying ``src`` file, if it is owned by another. Therefore, use
        checkambig=True only in limited cases (see also issue5418 and
        issue5584 for detail).
        """
        self._auditpath(dst, b'w')
        srcpath = self.join(src)
        dstpath = self.join(dst)
        oldstat = util.filestat.frompath(dstpath) if checkambig else None

        util.rename(srcpath, dstpath)

        if oldstat and oldstat.stat:
            _avoidambig(dstpath, oldstat)

    def readlink(self, path: HgPathT) -> FsPathT:
        """return the target of the ``path`` symlink (as os.readlink would)"""
        return util.readlink(self.join(path))

    def removedirs(self, path: HgPathT | None = None) -> None:
        """Remove a leaf directory and all empty intermediate ones"""
        return util.removedirs(self.join(path))

    def rmdir(self, path: HgPathT | None = None) -> None:
        """Remove an empty directory."""
        return os.rmdir(self.join(path))

    def rmtree(
        self,
        path: HgPathT | None = None,
        ignore_errors: bool = False,
        forcibly: bool = False,
    ) -> None:
        """Remove a directory tree recursively

        If ``forcibly``, this tries to remove READ-ONLY files, too.
        """
        if forcibly:

            def onexc(function: Callable, path: str, excinfo: Exception):
                # Note: str is passed here even if bytes are passed to rmtree
                # on platforms where `shutil._use_fd_functions == True`.  It is
                # bytes otherwise.  Fortunately, the methods used here accept
                # both.
                if function is not os.remove:
                    raise
                # read-only files cannot be unlinked under Windows
                s = os.stat(path)
                if (s.st_mode & stat.S_IWRITE) != 0:
                    raise
                os.chmod(path, stat.S_IMODE(s.st_mode) | stat.S_IWRITE)
                os.remove(path)

        else:

            def onexc(*args):
                pass

        try:
            # pytype: disable=wrong-keyword-args
            return shutil.rmtree(
                self.join(path), ignore_errors=ignore_errors, onexc=onexc
            )
            # pytype: enable=wrong-keyword-args
        except TypeError:  # onexc was introduced in Python 3.12
            return shutil.rmtree(
                self.join(path), ignore_errors=ignore_errors, onerror=onexc
            )

    def setflags(self, path: HgPathT, l: bool, x: bool) -> None:
        """set the symlink (``l``) and executable (``x``) flags of ``path``

        With ``l``, a regular file is turned into a symlink pointing to its
        content. Without it, a symlink is turned back into a regular file and
        the executable bit is set according to ``x``.
        """
        return util.setflags(self.join(path), l, x)

    def stat(self, path: HgPathT | None = None) -> os.stat_result:
        """return the stat of ``path`` (or the vfs base)

        Symlinks are followed (as os.stat would do).
        """
        return os.stat(self.join(path))

    def unlink(self, path: HgPathT | None = None) -> None:
        """remove the ``path`` file (as os.unlink would do)"""
        return util.unlink(self.join(path))

    def tryunlink(self, path: HgPathT | None = None) -> bool:
        """Attempt to remove a file, ignoring missing file errors."""
        return util.tryunlink(self.join(path))

    def unlinkpath(
        self,
        path: HgPathT | None = None,
        ignoremissing: bool = False,
        rmdir: bool = True,
    ) -> None:
        """remove the ``path`` file

        With ``ignoremissing``, a missing file is not an error. With
        ``rmdir``, the parent directories left empty are removed too.
        """
        return util.unlinkpath(
            self.join(path), ignoremissing=ignoremissing, rmdir=rmdir
        )

    # TODO: could be Tuple[float, float] too.
    def utime(
        self,
        path: HgPathT | None = None,
        t: tuple[int, int] | None = None,
    ) -> None:
        """set the access and modification times of ``path`` to ``t``

        The current time is used if ``t`` is None (as os.utime would do).
        """
        return os.utime(self.join(path), t)

    def walk(
        self,
        path: HgPathT | None = None,
        onerror: _OnErrorFn | None = None,
    ) -> Iterator[tuple[bytes, list[bytes], list[bytes]]]:
        """Yield (dirpath, dirs, files) tuple for each directory under path

        ``dirpath`` is relative one from the root of this vfs. This
        uses ``os.sep`` as path separator, even if you specify POSIX
        style ``path``.

        "The root of this vfs" is represented as empty ``dirpath``.
        """
        root = os.path.normpath(self.join(None))
        # when dirpath == root, dirpath[prefixlen:] becomes empty
        # because len(dirpath) < prefixlen.
        prefixlen = len(pathutil.normasprefix(root))
        for dirpath, dirs, files in os.walk(self.join(path), onerror=onerror):
            yield (dirpath[prefixlen:], dirs, files)

    @contextlib.contextmanager
    def backgroundclosing(
        self,
        ui: UiT,
        expectedcount: int = -1,
    ) -> Iterator[backgroundfilecloser | None]:
        """Allow files to be closed asynchronously.

        When this context manager is active, ``backgroundclose`` can be passed
        to ``__call__``/``open`` to result in the file possibly being closed
        asynchronously, on a background thread.
        """
        # Sharing backgroundfilecloser between threads is complex and using
        # multiple instances puts us at risk of running out of file descriptors
        # only allow to use backgroundfilecloser when in main thread.
        if threading.current_thread() is not threading.main_thread():
            yield
            return
        vfs = getattr(self, 'vfs', self)
        if getattr(vfs, '_backgroundfilecloser', None):
            raise error.Abort(
                _(b'can only have 1 active background file closer')
            )

        with backgroundfilecloser(ui, expectedcount=expectedcount) as bfc:
            try:
                vfs._backgroundfilecloser = (
                    bfc  # pytype: disable=attribute-error
                )
                yield bfc
            finally:
                vfs._backgroundfilecloser = (
                    None  # pytype: disable=attribute-error
                )

    def register_file(self, path: HgPathT) -> None:
        """generic hook point to lets fncache steer its stew"""

    def prepare_streamed_file(
        self,
        path: HgPathT,
        known_directories: set[FsPathT],
    ) -> tuple[FsPathT, int | None]:
        """make sure we are ready to write a file from a stream clone

        The "known_directories" variable is here to avoid trying to create the
        same directories over and over during a stream clone. It will be
        updated by this function.

        return (path, mode)::

            <path> is the real file system path content should be written to,
            <mode> is the file mode that need to be set if any.
        """
        real_path = self.join(path)
        self._auditpath(real_path, b'wb')
        self.register_file(path)
        dirname, basename = util.split(real_path)
        if dirname not in known_directories:
            util.makedirs(dirname, self.createmode, True)
            known_directories.add(dirname)
        mode = None
        if self.createmode is not None:
            mode = self.createmode & 0o666
        return real_path, mode


class vfs(abstractvfs, i_vfs.IWorkingVfs):
    """Operate files relative to a base directory

    This class is used to hide the details of COW semantics and
    remote file access from higher level code.

    'cacheaudited' should be enabled only if (a) vfs object is short-lived, or
    (b) the base directory is managed by hg and considered sort-of append-only.
    See pathutil.pathauditor() for details.
    """

    audit: pathutil.PathAuditT
    base: FsPathT
    createmode: int | None
    options: dict[bytes, Any]
    _audit: bool
    _trustnlink: bool | None

    def __init__(
        self,
        base: FsPathT,
        audit: bool = True,
        cacheaudited: bool = False,
        expandpath: bool = False,
        realpath: bool = False,
    ) -> None:
        if expandpath:
            base = util.expandpath(base)
        if realpath:
            base = os.path.realpath(base)
        self.base = base
        self._audit = audit
        if audit:
            self.audit = pathutil.pathauditor(self.base, cached=cacheaudited)
        else:
            self.audit = lambda path, mode=None: True
        self.createmode = None
        self._trustnlink = None
        self.options = {}

    @util.propertycache
    def _cansymlink(self) -> bool:
        return util.checklink(self.base)

    @util.propertycache
    def _chmod(self) -> bool:
        return util.checkexec(self.base)

    def _fixfilemode(self, name: bytes) -> None:
        if self.createmode is None or not self._chmod:
            return
        os.chmod(name, self.createmode & 0o666)

    def _auditpath(self, path: bytes, mode: bytes) -> None:
        if self.audit:
            if os.path.isabs(path) and path.startswith(self.base):
                path = os.path.relpath(path, self.base)
            r = util.checkosfilename(path)
            if r:
                raise error.Abort(b"%s: %r" % (r, path))
            self.audit(path, mode=mode)

    def isfileorlink_checkdir(
        self,
        dircache: MutableMapping[bytes, bool],
        path: HgPathT,
    ) -> bool:
        """return True if the path is a regular file or a symlink and
        the directories along the path are "normal", that is
        not symlinks or nested hg repositories.

        Ignores the `_audit` setting, and checks the directories regardless.
        `dircache` is used to cache the directory checks.
        """
        try:
            for prefix in pathutil.finddirs_rev_noroot(util.localpath(path)):
                if prefix in dircache:
                    res = dircache[prefix]
                else:
                    res = pathutil.pathauditor._checkfs_exists(
                        self.base, prefix, path
                    )
                    dircache[prefix] = res
                if not res:
                    return False
        except (OSError, error.Abort):
            return False
        return self.isfileorlink(path)

    def __call__(
        self,
        path: HgPathT,
        mode: bytes = b"rb",
        atomictemp: bool = False,
        notindexed: bool = False,
        backgroundclose: bool = False,
        checkambig: bool = False,
        auditpath: bool = True,
        makeparentdirs: bool = True,
        buffering: int = -1,
    ) -> Any:  # TODO: type the return with the IVfs.__call__ overloads
        """Open ``path`` file, which is relative to vfs root.

        With ``atomictemp=True``, the file is written atomically, see
        IAtomicTempFile.

        By default, parent directories are created as needed. Newly created
        directories are marked as "not to be indexed by the content indexing
        service", if ``notindexed`` is specified for "write" mode access.
        Set ``makeparentdirs=False`` to not create directories implicitly.

        If ``backgroundclose`` is passed, the file may be closed asynchronously.
        It can only be used if the ``self.backgroundclosing()`` context manager
        is active. This should only be specified if the following criteria hold:

        1. There is a potential for writing thousands of files. Unless you
           are writing thousands of files, the performance benefits of
           asynchronously closing files is not realized.
        2. Files are opened exactly once for the ``backgroundclosing``
           active duration and are therefore free of race conditions between
           closing a file on a background thread and reopening it. (If the
           file were opened multiple times, there could be unflushed data
           because the original file handle hasn't been flushed/closed yet.)

        ``checkambig`` argument is passed to atomictempfile (valid
        only for writing), and is useful only if target file is
        guarded by any lock (e.g. repo.lock or repo.wlock).

        To avoid file stat ambiguity forcibly, checkambig=True involves
        copying ``path`` file opened in "append" mode (e.g. for
        truncation), if it is owned by another. Therefore, use
        combination of append mode and checkambig=True only in limited
        cases (see also issue5418 and issue5584 for detail).
        """
        if auditpath:
            self._auditpath(path, mode)
        f = self.join(path)

        if b"b" not in mode:
            mode += b"b"  # for that other OS

        nlink = -1
        if mode not in (b'r', b'rb'):
            dirname, basename = util.split(f)
            # If basename is empty, then the path is malformed because it points
            # to a directory. Let the posixfile() call below raise IOError.
            if basename:
                if atomictemp:
                    if makeparentdirs:
                        util.makedirs(dirname, self.createmode, notindexed)
                    return util.atomictempfile(
                        f, mode, self.createmode, checkambig=checkambig
                    )
                try:
                    if b'w' in mode:
                        util.unlink(f)
                        nlink = 0
                    else:
                        # nlinks() may behave differently for files on Windows
                        # shares if the file is open.
                        with util.posixfile(f):
                            nlink = util.nlinks(f)
                            if nlink < 1:
                                nlink = 2  # force mktempcopy (issue1922)
                except FileNotFoundError:
                    nlink = 0
                    if makeparentdirs:
                        util.makedirs(dirname, self.createmode, notindexed)
                if nlink > 0:
                    if self._trustnlink is None:
                        self._trustnlink = nlink > 1 or util.checknlink(f)
                    if nlink > 1 or not self._trustnlink:
                        util.rename(util.mktempcopy(f), f)
        if atomictemp:
            # an atomictemp write returned earlier, so we only get here when
            # reading (or for a path without basename)
            msg = b'atomictemp is only valid when writing a file'
            raise error.ProgrammingError(msg)
        fp = util.posixfile(f, mode, buffering=buffering)
        if nlink == 0:
            self._fixfilemode(f)

        if checkambig:
            if mode in (b'r', b'rb'):
                raise error.Abort(
                    _(
                        b'implementation error: mode %s is not'
                        b' valid for checkambig=True'
                    )
                    % mode
                )
            fp = checkambigatclosing(fp)

        if (
            backgroundclose
            and threading.current_thread() is threading.main_thread()
        ):
            if (
                not self._backgroundfilecloser  # pytype: disable=attribute-error
            ):
                raise error.Abort(
                    _(
                        b'backgroundclose can only be used when a '
                        b'backgroundclosing context manager is active'
                    )
                )

            fp = delayclosedfile(
                fp,
                self._backgroundfilecloser,  # pytype: disable=attribute-error
            )

        return fp

    def symlink(self, src: FsPathT, dst: HgPathT) -> None:
        """create a ``dst`` symlink pointing to ``src``

        If the file system does not support symlinks, ``dst`` is written as a
        regular file containing ``src``.
        """
        self.audit(dst)
        linkname = self.join(dst)
        util.tryunlink(linkname)

        util.makedirs(os.path.dirname(linkname), self.createmode)

        if self._cansymlink:
            try:
                os.symlink(src, linkname)
            except OSError as err:
                raise OSError(
                    err.errno,
                    _(b'could not symlink to %r: %s')
                    % (src, encoding.strtolocal(err.strerror)),
                    linkname,
                )
        else:
            self.write(dst, src)

    def join(self, path: HgPathT | None, *insidef: HgPathT) -> FsPathT:
        """return the file system path for ``path`` (joined with ``insidef``)

        The vfs "base" is returned if ``path`` is empty.
        """
        if path:
            parts = [self.base, path]
            parts.extend(insidef)
            return self._join(*parts)
        else:
            return self.base


opener: type[vfs] = vfs


class proxyvfs(abstractvfs, abc.ABC):
    def __init__(self, vfs: vfs) -> None:
        self.vfs = vfs
        self.base = vfs.base
        self.read_write = vfs.read_write
        self.filter_name = vfs.filter_name

    @property
    def createmode(self) -> int | None:
        return self.vfs.createmode

    def _auditpath(self, path: bytes, mode: bytes) -> None:
        return self.vfs._auditpath(path, mode)

    @property
    def options(self) -> dict[bytes, Any]:
        return self.vfs.options

    @options.setter
    def options(self, value: dict[bytes, Any]) -> None:
        self.vfs.options = value

    @property
    def audit(self):
        return self.vfs.audit

    @audit.setter
    def audit(self, audit):
        self.vfs.audit = audit


class FilterFn(Protocol):
    """protocol for "filter" function used for path encoding"""

    filter_name: bytes

    @abc.abstractmethod
    def __call__(self, path: bytes) -> bytes:
        ...


def filter(name: str):
    """annotate a function with a filter name"""

    def add_name(fn: _C) -> _C:
        if hasattr(fn, '__dict__'):
            fn.filter_name = name
        else:
            _NAME_BY_FILTER[fn] = name
        FILTER_BY_NAME[name] = fn
        return fn

    return add_name


FILTER_BY_NAME: dict[str, FilterFn | Callable[[bytes], bytes]] = {}
"""gather known filter by name"""

_NAME_BY_FILTER: dict[Callable[[bytes], bytes], str] = {}
"""fallback for C function that can't be added attributes"""


class filtervfs(proxyvfs, abstractvfs):
    '''Wrapper vfs for filtering filenames with a function.'''

    def __init__(
        self,
        vfs: vfs,
        filter: FilterFn | Callable[[bytes], bytes],
    ) -> None:
        proxyvfs.__init__(self, vfs)
        self._filter = filter
        name = getattr(filter, "filter_name", None)
        if name is None:
            name = _NAME_BY_FILTER[filter]
        self.filter_name = name

    # TODO: type the return with the IVfs.__call__ overloads
    def __call__(self, path: HgPathT, *args, **kwargs) -> Any:
        """Open ``path`` file, which is relative to vfs root.

        With ``atomictemp=True``, the file is written atomically, see
        IAtomicTempFile.

        By default, parent directories are created as needed. Newly created
        directories are marked as "not to be indexed by the content indexing
        service", if ``notindexed`` is specified for "write" mode access.
        Set ``makeparentdirs=False`` to not create directories implicitly.

        If ``backgroundclose`` is passed, the file may be closed asynchronously.
        It can only be used if the ``self.backgroundclosing()`` context manager
        is active. This should only be specified if the following criteria hold:

        1. There is a potential for writing thousands of files. Unless you
           are writing thousands of files, the performance benefits of
           asynchronously closing files is not realized.
        2. Files are opened exactly once for the ``backgroundclosing``
           active duration and are therefore free of race conditions between
           closing a file on a background thread and reopening it. (If the
           file were opened multiple times, there could be unflushed data
           because the original file handle hasn't been flushed/closed yet.)

        ``checkambig`` argument is passed to atomictempfile (valid
        only for writing), and is useful only if target file is
        guarded by any lock (e.g. repo.lock or repo.wlock).

        To avoid file stat ambiguity forcibly, checkambig=True involves
        copying ``path`` file opened in "append" mode (e.g. for
        truncation), if it is owned by another. Therefore, use
        combination of append mode and checkambig=True only in limited
        cases (see also issue5418 and issue5584 for detail).
        """
        return self.vfs(self._filter(path), *args, **kwargs)

    def join(self, path: HgPathT | None, *insidef: HgPathT) -> FsPathT:
        """return the file system path for ``path`` (joined with ``insidef``)

        The vfs "base" is returned if ``path`` is empty.
        """
        if path:
            return self.vfs.join(self._filter(self.vfs.reljoin(path, *insidef)))
        else:
            return self.vfs.join(path)


filteropener: type[filtervfs] = filtervfs


class readonlyvfs(proxyvfs):
    '''Wrapper vfs preventing any writing.'''

    read_write = False

    def __init__(self, vfs: vfs) -> None:
        proxyvfs.__init__(self, vfs)

    # TODO: type the return with the IVfs.__call__ overloads
    def __call__(
        self,
        path: HgPathT,
        mode: bytes = b'rb',
        *args,
        **kw,
    ) -> Any:
        """Open ``path`` file, which is relative to vfs root.

        Only read modes are accepted.
        """
        if mode not in (b'r', b'rb'):
            raise error.Abort(_(b'this vfs is read only'))
        return self.vfs(path, mode, *args, **kw)

    def join(self, path: HgPathT | None, *insidef: HgPathT) -> FsPathT:
        """return the file system path for ``path`` (joined with ``insidef``)

        The vfs "base" is returned if ``path`` is empty.
        """
        return self.vfs.join(path, *insidef)


class closewrapbase(abc.ABC):
    """Base class of wrapper, which hooks closing

    Do not instantiate outside the vfs layer.
    """

    def __init__(self, fh) -> None:
        object.__setattr__(self, '_origfh', fh)

    def __getattr__(self, attr: str) -> Any:
        return getattr(self._origfh, attr)

    def __setattr__(self, attr: str, value: Any) -> None:
        return setattr(self._origfh, attr, value)

    def __delattr__(self, attr: str) -> None:
        return delattr(self._origfh, attr)

    def __enter__(self: _Tclosewrapbase) -> _Tclosewrapbase:
        self._origfh.__enter__()
        return self

    @abc.abstractmethod
    def __exit__(self, exc_type, exc_value, exc_tb) -> None:
        ...

    @abc.abstractmethod
    def close(self) -> None:
        ...


class delayclosedfile(closewrapbase):
    """Proxy for a file object whose close is delayed.

    Do not instantiate outside the vfs layer.
    """

    def __init__(self, fh, closer) -> None:
        super().__init__(fh)
        object.__setattr__(self, '_closer', closer)

    def __exit__(self, exc_type, exc_value, exc_tb) -> None:
        self._closer.close(self._origfh)

    def close(self) -> None:
        self._closer.close(self._origfh)


class backgroundfilecloser(i_vfs.IBackgroundFileCloser):
    """Coordinates background closing of file handles on multiple threads."""

    def __init__(self, ui: UiT, expectedcount: int = -1) -> None:
        self._running = False
        self._entered = False
        self._threads = []
        self._threadexception = None

        # Only Windows/NTFS has slow file closing. So only enable by default
        # on that platform. But allow to be enabled elsewhere for testing.
        defaultenabled = pycompat.iswindows
        enabled = ui.configbool(b'worker', b'backgroundclose', defaultenabled)

        if not enabled:
            return

        # There is overhead to starting and stopping the background threads.
        # Don't do background processing unless the file count is large enough
        # to justify it.
        minfilecount = ui.configint(b'worker', b'backgroundcloseminfilecount')
        # FUTURE dynamically start background threads after minfilecount closes.
        # (We don't currently have any callers that don't know their file count)
        if expectedcount > 0 and expectedcount < minfilecount:
            return

        maxqueue = ui.configint(b'worker', b'backgroundclosemaxqueue')
        threadcount = ui.configint(b'worker', b'backgroundclosethreadcount')

        ui.debug(
            b'starting %d threads for background file closing\n' % threadcount
        )

        self._queue = pycompat.queue.Queue(maxsize=maxqueue)
        self._running = True

        for i in range(threadcount):
            t = threading.Thread(target=self._worker, name='backgroundcloser')
            self._threads.append(t)
            t.start()

    def __enter__(self: _Tbackgroundfilecloser) -> _Tbackgroundfilecloser:
        self._entered = True
        return self

    def __exit__(self, exc_type, exc_value, exc_tb) -> None:
        self._running = False

        # Wait for threads to finish closing so open files don't linger for
        # longer than lifetime of context manager.
        for t in self._threads:
            t.join()

    def _worker(self) -> None:
        """Main routine for worker thread."""
        while True:
            try:
                fh = self._queue.get(block=True, timeout=0.100)
                # Need to catch or the thread will terminate and
                # we could orphan file descriptors.
                try:
                    fh.close()
                except Exception as e:
                    # Stash so can re-raise from main thread later.
                    self._threadexception = e
            except pycompat.queue.Empty:
                if not self._running:
                    break

    def close(self, fh) -> None:
        """Schedule a file for closing."""
        if not self._entered:
            raise error.Abort(
                _(b'can only call close() when context manager active')
            )

        # If a background thread encountered an exception, raise now so we fail
        # fast. Otherwise, we may potentially go on for minutes until the error
        # is acted on.
        if self._threadexception:
            e = self._threadexception
            self._threadexception = None
            raise e

        # If we're not actively running, close synchronously.
        if not self._running:
            fh.close()
            return

        self._queue.put(fh, block=True, timeout=None)


class checkambigatclosing(closewrapbase):
    """Proxy for a file object, to avoid ambiguity of file stat

    See also util.filestat for detail about "ambiguity of file stat".

    This proxy is useful only if the target file is guarded by any
    lock (e.g. repo.lock or repo.wlock)

    Do not instantiate outside the vfs layer.
    """

    def __init__(self, fh) -> None:
        super().__init__(fh)
        object.__setattr__(self, '_oldstat', util.filestat.frompath(fh.name))

    def _checkambig(self) -> None:
        oldstat = self._oldstat
        if oldstat.stat:
            _avoidambig(self._origfh.name, oldstat)

    def __exit__(self, exc_type, exc_value, exc_tb) -> None:
        self._origfh.__exit__(exc_type, exc_value, exc_tb)
        self._checkambig()

    def close(self) -> None:
        self._origfh.close()
        self._checkambig()
