# vfs.py - Type annotations for vfs related objects
#
# Copyright 2026 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import contextlib
import os
import typing

from typing import (
    Any,
    BinaryIO,
    Callable,
    Iterable,
    Iterator,
    Literal,
    MutableMapping,
    Protocol,
    overload,
)

from ._basetypes import (
    FsPathT,
    HgPathT,
    NeedsTypeHint,
    UiT,
)


class IBackgroundFileCloser(Protocol):
    """Coordinates background closing of file handles on multiple threads."""

    @abc.abstractmethod
    def close(self, fh) -> None:
        """Schedule a file for closing."""


class IAtomicTempFile(Protocol):
    """writable file object that atomically updates a file

    Compared to BinaryIO, IAtomicTempFile adds discard() and drops most of the
    file API.
    """

    @abc.abstractmethod
    def read(self, size: int = -1) -> bytes:
        ...

    @abc.abstractmethod
    def write(self, data: bytes) -> int:
        ...

    @abc.abstractmethod
    def writelines(self, lines: Iterable[bytes]) -> None:
        ...

    @abc.abstractmethod
    def seek(self, offset: int, whence: int = 0) -> int:
        ...

    @abc.abstractmethod
    def tell(self) -> int:
        ...

    @abc.abstractmethod
    def fileno(self) -> int:
        ...

    @abc.abstractmethod
    def close(self) -> None:
        """close the file and make its new content visible"""

    @abc.abstractmethod
    def discard(self) -> None:
        """close the file and drop the changes"""

    @abc.abstractmethod
    def __enter__(self) -> IAtomicTempFile:
        ...

    @abc.abstractmethod
    def __exit__(self, exc_type, exc_value, exc_tb) -> None:
        ...


class IVfs(Protocol):
    """Operate on files relative to a base directory"""

    base: FsPathT
    """The directory (or url) this vfs is rooted at."""

    createmode: int | None
    """The mode to use for new files and directories, if any."""

    options: dict[bytes, Any]
    """Configuration options for the users of this vfs (e.g. revlogs)."""

    audit: NeedsTypeHint  # a mercurial.pathutil.pathauditor in practice
    """Callable checking that a path is safe to use with this vfs."""

    read_write: bool
    """False if this vfs only allows read access."""

    filter_name: str | None
    """The name of the path encoding used, if any."""

    rust_compatible: bool
    """False if this vfs cannot be used by the Rust code."""

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
        ) -> IAtomicTempFile:
            ...

        @overload
        def __call__(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: bool,
            **kwargs,
        ) -> BinaryIO | IAtomicTempFile:
            ...

    @abc.abstractmethod
    def __call__(
        self,
        path: HgPathT,
        mode: bytes = b'rb',
        **kwargs,
    ) -> BinaryIO | IAtomicTempFile:
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

    if typing.TYPE_CHECKING:

        @overload
        def open(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: Literal[False] = ...,
            **kwargs,
        ) -> BinaryIO:
            ...

        @overload
        def open(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: Literal[True],
            **kwargs,
        ) -> IAtomicTempFile:
            ...

        @overload
        def open(
            self,
            path: HgPathT,
            mode: bytes = ...,
            *,
            atomictemp: bool,
            **kwargs,
        ) -> BinaryIO | IAtomicTempFile:
            ...

    @abc.abstractmethod
    def open(
        self,
        path: HgPathT,
        mode: bytes = b'rb',
        **kwargs,
    ) -> BinaryIO | IAtomicTempFile:
        """Open ``path`` file, which is relative to vfs root.

        Newly created directories are marked as "not to be indexed by
        the content indexing service", if ``notindexed`` is specified
        for "write" mode access.
        """

    @abc.abstractmethod
    def join(self, path: HgPathT | None, *insidef: HgPathT) -> FsPathT:
        """return the file system path for ``path`` (joined with ``insidef``)

        The vfs "base" is returned if ``path`` is empty.
        """

    @abc.abstractmethod
    def wopen(self, path: HgPathT, **kwargs) -> BinaryIO:
        """Open ``path`` file, relative to vfs root for writing

        If the file is missing, create it.
        """

    @abc.abstractmethod
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

    @abc.abstractmethod
    def readlines(self, path: HgPathT, mode: bytes = b'rb') -> list[bytes]:
        """return the content of the ``path`` file as a list of lines

        The lines keep their end-of-line characters.
        """

    @abc.abstractmethod
    def tryread(
        self,
        path: HgPathT,
        mmap_threshold: int | None = None,
        size: int | None = None,
    ) -> bytes:
        '''gracefully return an empty string for missing files'''

    @abc.abstractmethod
    def tryreadlines(self, path: HgPathT, mode: bytes = b'rb') -> list[bytes]:
        '''gracefully return an empty list for missing files'''

    @abc.abstractmethod
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

    @abc.abstractmethod
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

    @abc.abstractmethod
    def append(self, path: HgPathT, data: bytes) -> int:
        """add ``data`` at the end of the ``path`` file

        The file is created if missing. Return the number of bytes written.
        """

    @abc.abstractmethod
    def basename(self, path: HgPathT) -> HgPathT:
        """return base element of a path (as os.path.basename would do)

        This exists to allow handling of strange encoding if needed."""

    @abc.abstractmethod
    def chmod(self, path: HgPathT, mode: int) -> None:
        """change the permissions of the ``path`` file (as os.chmod would do)"""

    @abc.abstractmethod
    def dirname(self, path: HgPathT) -> HgPathT:
        """return dirname element of a path (as os.path.dirname would do)

        This exists to allow handling of strange encoding if needed."""

    @abc.abstractmethod
    def exists(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) exists

        Symlinks are followed (as os.path.exists would do).
        """

    @abc.abstractmethod
    def fstat(self, fp: BinaryIO) -> os.stat_result:
        """stat an open file object, even one without a ``fileno`` method"""

    @abc.abstractmethod
    def isdir(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a directory

        Symlinks are followed (as os.path.isdir would do).
        """

    @abc.abstractmethod
    def isfile(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a regular file

        Symlinks are followed (as os.path.isfile would do).
        """

    @abc.abstractmethod
    def islink(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) is a symlink"""

    @abc.abstractmethod
    def isfileorlink(self, path: HgPathT | None = None) -> bool:
        """return whether path is a regular file or a symlink

        Unlike isfile, this doesn't follow symlinks."""

    @abc.abstractmethod
    def reljoin(self, *paths: HgPathT) -> HgPathT:
        """join various elements of a path together (as os.path.join would do)

        The vfs base is not injected so that paths stay relative. This exists
        to allow handling of strange encoding if needed."""

    @abc.abstractmethod
    def split(self, path: HgPathT) -> tuple[HgPathT, HgPathT]:
        """split top-most element of a path (as os.path.split would do)

        This exists to allow handling of strange encoding if needed."""

    @abc.abstractmethod
    def lexists(self, path: HgPathT | None = None) -> bool:
        """True if ``path`` (or the vfs base) exists

        Symlinks are not followed, so a broken symlink exists (as
        os.path.lexists would do).
        """

    @abc.abstractmethod
    def lstat(self, path: HgPathT | None = None) -> os.stat_result:
        """return the stat of ``path`` (or the vfs base)

        Symlinks are not followed (as os.lstat would do).
        """

    @abc.abstractmethod
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
        """

    @abc.abstractmethod
    def listdir(self, path: HgPathT | None = None) -> list[bytes]:
        """return the names of the entries in the ``path`` directory

        When ``path`` is None, the vfs "base" is used.

        This behaves as os.listdir would."""

    @abc.abstractmethod
    def makedir(
        self,
        path: HgPathT | None = None,
        notindexed: bool = True,
    ) -> None:
        """create the ``path`` directory (its parent must exist)

        If ``notindexed`` is set, the directory is marked as "not to be indexed
        by the content indexing service" (on platforms supporting it).
        """

    @abc.abstractmethod
    def makedirs(
        self,
        path: HgPathT | None = None,
        mode: int | None = None,
    ) -> None:
        """create the ``path`` directory and any missing parent directory

        Does nothing if the directory already exists.

        If ``mode`` is set, it is applied to the ``path`` directory.
        """

    @abc.abstractmethod
    def makelock(self, info: bytes, path: HgPathT) -> None:
        """atomically create the ``path`` lock file holding ``info``

        The lock is a symlink pointing to ``info`` if possible, a regular file
        containing it otherwise. Fails if ``path`` already exists.
        """

    @abc.abstractmethod
    def readlock(self, path: HgPathT) -> bytes:
        """return the ``info`` held by the ``path`` lock file (see makelock)"""

    @abc.abstractmethod
    def mkdir(self, path: HgPathT | None = None) -> None:
        """create the ``path`` directory (as os.mkdir would do)"""

    @abc.abstractmethod
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

    @abc.abstractmethod
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

    @abc.abstractmethod
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

    @abc.abstractmethod
    def readlink(self, path: HgPathT) -> FsPathT:
        """return the target of the ``path`` symlink (as os.readlink would)"""

    @abc.abstractmethod
    def removedirs(self, path: HgPathT | None = None) -> None:
        """Remove a leaf directory and all empty intermediate ones"""

    @abc.abstractmethod
    def rmdir(self, path: HgPathT | None = None) -> None:
        """Remove an empty directory."""

    @abc.abstractmethod
    def rmtree(
        self,
        path: HgPathT | None = None,
        ignore_errors: bool = False,
        forcibly: bool = False,
    ) -> None:
        """Remove a directory tree recursively

        If ``forcibly``, this tries to remove READ-ONLY files, too.
        """

    @abc.abstractmethod
    def setflags(self, path: HgPathT, l: bool, x: bool) -> None:
        """set the symlink (``l``) and executable (``x``) flags of ``path``

        With ``l``, a regular file is turned into a symlink pointing to its
        content. Without it, a symlink is turned back into a regular file and
        the executable bit is set according to ``x``.
        """

    @abc.abstractmethod
    def stat(self, path: HgPathT | None = None) -> os.stat_result:
        """return the stat of ``path`` (or the vfs base)

        Symlinks are followed (as os.stat would do).
        """

    @abc.abstractmethod
    def unlink(self, path: HgPathT | None = None) -> None:
        """remove the ``path`` file (as os.unlink would do)"""

    @abc.abstractmethod
    def tryunlink(self, path: HgPathT | None = None) -> bool:
        """Attempt to remove a file, ignoring missing file errors."""

    @abc.abstractmethod
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

    @abc.abstractmethod
    def utime(
        self,
        path: HgPathT | None = None,
        t: tuple[int, int] | None = None,
    ) -> None:
        """set the access and modification times of ``path`` to ``t``

        The current time is used if ``t`` is None (as os.utime would do).
        """

    @abc.abstractmethod
    def walk(
        self,
        path: HgPathT | None = None,
        onerror: Callable[[Exception], object | None] | None = None,
    ) -> Iterator[tuple[bytes, list[bytes], list[bytes]]]:
        """Yield (dirpath, dirs, files) tuple for each directory under path

        ``dirpath`` is relative one from the root of this vfs. This
        uses ``os.sep`` as path separator, even if you specify POSIX
        style ``path``.

        "The root of this vfs" is represented as empty ``dirpath``.
        """

    @contextlib.contextmanager
    @abc.abstractmethod
    def backgroundclosing(
        self,
        ui: UiT,
        expectedcount: int = -1,
    ) -> Iterator[IBackgroundFileCloser | None]:
        """Allow files to be closed asynchronously.

        When this context manager is active, ``backgroundclose`` can be passed
        to ``__call__``/``open`` to result in the file possibly being closed
        asynchronously, on a background thread.
        """

    @abc.abstractmethod
    def register_file(self, path: HgPathT) -> None:
        """generic hook point to lets fncache steer its stew"""

    @abc.abstractmethod
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


class IWorkingVfs(IVfs, Protocol):
    """A vfs with the extra operations needed to manage a working copy"""

    @abc.abstractmethod
    def symlink(self, src: FsPathT, dst: HgPathT) -> None:
        """create a ``dst`` symlink pointing to ``src``

        If the file system does not support symlinks, ``dst`` is written as a
        regular file containing ``src``.
        """

    @abc.abstractmethod
    def isfileorlink_checkdir(
        self,
        dircache: MutableMapping[bytes, bool],
        path: HgPathT,
    ) -> bool:
        """return True if the path is a regular file or a symlink and
        the directories along the path are "normal", that is
        not symlinks or nested hg repositories.

        The directories are checked even if path auditing is disabled for this
        vfs. `dircache` is used to cache the directory checks.
        """
