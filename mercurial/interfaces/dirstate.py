from __future__ import annotations

import abc
import contextlib
import enum
import os
import typing

from typing import (
    Callable,
    Iterable,
    Iterator,
    Optional,
    Protocol,
)


class DirstateVersion(enum.Enum):
    """Identify the on-disk format of the dirstate."""

    V1 = enum.auto()
    """dirstate use v1 format storage"""

    V2 = enum.auto()
    """dirstate use v1 format storage"""

    GIT = enum.auto()
    """value for the experimental dirstate from `hgext.git`

    (the working copy state is stored in git's index)"""


if typing.TYPE_CHECKING:
    from ._basetypes import (
        HgPathT,
        LockT,
        NodeIdT,
        UiT,
    )

    # Almost all mercurial modules are only imported in the type checking phase
    # to avoid circular imports
    from . import (
        matcher,
        status as istatus,
        transaction,
    )

    AddParentChangeCallbackT = Callable[
        ["IDirstate", tuple[NodeIdT, NodeIdT], tuple[NodeIdT, NodeIdT]], None
    ]
    """The callback type for dirstate.addparentchangecallback()."""

    FlagFuncFallbackT = Callable[[], "FlagFuncReturnT"]
    """The type for the dirstate.flagfunc() fallback function."""

    FlagFuncReturnT = Callable[[bytes], bytes]
    """The return type of dirstate.flagfunc()."""

    StatusReturnT = tuple[list[HgPathT], istatus.Status, Optional["TimestampT"]]
    """The return type of dirstate.status()."""

    TimestampT = tuple[int, int, bool]
    """A Unix timestamp with optional nanoseconds precision, modulo 2**31
    seconds, as ``(truncated_seconds, subsecond_nanoseconds,
    second_ambiguous)``.
    """

    TransactionT = transaction.ITransaction
    """The type for a transaction used with dirstate.

    This is meant to help callers avoid having to remember to delay the import
    of the transaction module.
    """

    # TODO: The value can also be mercurial.osutil.stat
    WalkReturnT = dict[bytes, Optional[os.stat_result]]
    """The return type of dirstate.walk().

    The matched files are keyed in the dictionary, mapped to a stat-like object
    if the file exists.
    """


class IDirstateItem(Protocol):
    """represent a dirstate entry

    (implemented in Python by mercurial.pure.parsers.DirstateItem, and in Rust
    for the dirstate-map bindings)
    """

    # keep the slotted implementations free of a `__dict__`
    __slots__ = ()

    @property
    @abc.abstractmethod
    def state(self) -> bytes:
        """The dirstate-v1 state: one of b'n', b'm', b'r', b'a' or b'?'."""

    @property
    @abc.abstractmethod
    def has_fallback_exec(self) -> bool:
        """True if "fallback" information are available for the "exec" bit"""

    @property
    @abc.abstractmethod
    def fallback_exec(self) -> bool | None:
        """ "fallback" information for the executable bit"""

    @property
    @abc.abstractmethod
    def has_fallback_symlink(self) -> bool:
        """True if "fallback" information are available for symlink status"""

    @property
    @abc.abstractmethod
    def fallback_symlink(self) -> bool | None:
        """ "fallback" information for symlink status"""

    @property
    @abc.abstractmethod
    def tracked(self) -> bool:
        """True is the file is tracked in the working copy"""

    @property
    @abc.abstractmethod
    def any_tracked(self) -> bool:
        """True is the file is tracked anywhere (wc or parents)"""

    @property
    @abc.abstractmethod
    def added(self) -> bool:
        """True if the file has been added"""

    @property
    @abc.abstractmethod
    def modified(self) -> bool:
        """True if the file has been modified"""

    @property
    @abc.abstractmethod
    def maybe_clean(self) -> bool:
        """True if the file has a chance to be in the "clean" state"""

    @property
    @abc.abstractmethod
    def p1_tracked(self) -> bool:
        """True if the file is tracked in the first parent manifest"""

    @property
    @abc.abstractmethod
    def p2_info(self) -> bool:
        """True if the file needed to merge or apply any input from p2"""

    @property
    @abc.abstractmethod
    def removed(self) -> bool:
        """True if the file has been removed"""


class IChangingContextRepo(Protocol):
    """The part of a repository a dirstate changing context needs

    We cannot use RepoT or it would create an import cycle and pytype would
    stop typing one of the two files.
    """

    ui: UiT

    @abc.abstractmethod
    def currentwlock(self) -> LockT | None:
        """Return the wlock if it's held or None."""

    @abc.abstractmethod
    def currenttransaction(self) -> TransactionT | None:
        """Obtain the current transaction instance or None."""


class IDirstate(Protocol):
    # TODO: convert these constructor args to fields?
    # def __init__(
    #     self,
    #     opener,
    #     ui,
    #     root,
    #     validate,
    #     sparsematchfn,
    #     nodeconstants,
    #     use_dirstate_v2,
    #     use_tracked_hint=False,
    # ):
    #     """Create a new dirstate object.
    #
    #     opener is an open()-like callable that can be used to open the
    #     dirstate file; root is the root of the directory tracked by
    #     the dirstate.
    #     """

    version: DirstateVersion
    """The on-disk format used by this dirstate."""

    # TODO: decorate with `@rootcache(b'.hgignore')` like dirstate class?
    @property
    def ignore_matcher(self) -> matcher.IMatcher:
        """Matcher for ignored files."""

    @property
    @abc.abstractmethod
    def is_changing_any(self) -> bool:
        """True if any changes in progress."""

    @property
    @abc.abstractmethod
    def is_changing_parents(self) -> bool:
        """True if parents changes in progress."""

    @property
    @abc.abstractmethod
    def is_changing_files(self) -> bool:
        """True if file tracking changes in progress."""

    @contextlib.contextmanager
    @abc.abstractmethod
    def changing_parents(self, repo: IChangingContextRepo) -> Iterator[None]:
        """Context manager for handling dirstate parents.

        If an exception occurs in the scope of the context manager,
        the incoherent dirstate won't be written when wlock is
        released.
        """

    @contextlib.contextmanager
    @abc.abstractmethod
    def changing_files(self, repo) -> Iterator:  # TODO: typehint this
        """Context manager for handling dirstate files.

        If an exception occurs in the scope of the context manager,
        the incoherent dirstate won't be written when wlock is
        released.
        """

    @abc.abstractmethod
    def hasdir(self, d: bytes) -> bool:
        pass

    @abc.abstractmethod
    def flagfunc(self, buildfallback: FlagFuncFallbackT) -> FlagFuncReturnT:
        """build a callable that returns flags associated with a filename

        The information is extracted from three possible layers:
        1. the file system if it supports the information
        2. the "fallback" information stored in the dirstate if any
        3. a more expensive mechanism inferring the flags from the parents.
        """

    @abc.abstractmethod
    def getcwd(self) -> bytes:
        """Return the path from which a canonical path is calculated.

        This path should be used to resolve file patterns or to convert
        canonical paths back to file paths for display. It shouldn't be
        used to get real file paths. Use vfs functions instead.
        """

    @abc.abstractmethod
    def get_entry(self, path: bytes) -> IDirstateItem:
        """return a DirstateItem for the associated path"""

    @abc.abstractmethod
    def __contains__(self, key: HgPathT) -> bool:
        """Check if bytestring `key` is known to the dirstate."""

    @abc.abstractmethod
    def __iter__(self) -> Iterator[bytes]:
        """Iterate the dirstate's contained filenames as bytestrings."""

    @abc.abstractmethod
    def items(self) -> Iterator[tuple[bytes, IDirstateItem]]:
        """Iterate the dirstate's entries as (filename, DirstateItem.

        As usual, filename is a bytestring.
        """

    iteritems = items

    @abc.abstractmethod
    def parents(self) -> list[bytes]:
        pass

    @abc.abstractmethod
    def p1(self) -> bytes:
        pass

    @abc.abstractmethod
    def p2(self) -> bytes:
        pass

    @abc.abstractmethod
    def branch(self) -> bytes:
        pass

    # TODO: typehint the return.  It's a copies Map of some sort.
    @abc.abstractmethod
    def setparents(self, p1: bytes, p2: bytes | None = None):
        """Set dirstate parents to p1 and p2.

        When moving from two parents to one, "merged" entries a
        adjusted to normal and previous copy records discarded and
        returned by the call.

        See localrepo.setparents()
        """

    @abc.abstractmethod
    def setbranch(
        self, branch: bytes, transaction: TransactionT | None
    ) -> None:
        pass

    @abc.abstractmethod
    def invalidate(self) -> None:
        """Causes the next access to reread the dirstate.

        This is different from localrepo.invalidatedirstate() because it always
        rereads the dirstate. Use localrepo.invalidatedirstate() if you want to
        check whether the dirstate has changed before rereading it."""

    @abc.abstractmethod
    def clear_caches(self) -> None:
        """Drop the in-memory caches derived from the dirstate content.

        They are recomputed on next access. Unlike `invalidate`, this does not
        reread the dirstate. This is mostly useful for benchmarking."""

    @abc.abstractmethod
    def copy(self, source: bytes | None, dest: bytes) -> None:
        """Mark dest as a copy of source. Unmark dest if source is None."""

    @abc.abstractmethod
    def copied(self, file: bytes) -> bytes | None:
        pass

    @abc.abstractmethod
    def copies(self) -> dict[bytes, bytes]:
        pass

    @abc.abstractmethod
    def normalize(
        self, path: bytes, isknown: bool = False, ignoremissing: bool = False
    ) -> bytes:
        """
        normalize the case of a pathname when on a casefolding filesystem

        isknown specifies whether the filename came from walking the
        disk, to avoid extra filesystem access.

        If ignoremissing is True, missing path are returned
        unchanged. Otherwise, we try harder to normalize possibly
        existing path components.

        The normalized case is determined based on the following precedence:

        - version of name already stored in the dirstate
        - version of name stored on disk
        - version provided via command arguments
        """

    @abc.abstractmethod
    def clear(self) -> None:
        pass

    @abc.abstractmethod
    def rebuild(
        self,
        parent: bytes,
        allfiles: Iterable[bytes],  # TODO: more than iterable? (uses len())
        changedfiles: Iterable[bytes] | None = None,
    ) -> None:
        pass

    @abc.abstractmethod
    def write(self, tr: TransactionT | None) -> None:
        pass

    @abc.abstractmethod
    def delete_tracked_hint(self) -> None:
        """remove the tracked_hint file

        To be used by format downgrades operation"""

    @abc.abstractmethod
    def addparentchangecallback(
        self, category: bytes, callback: AddParentChangeCallbackT
    ) -> None:
        """add a callback to be called when the wd parents are changed

        Callback will be called with the following arguments:
            dirstate, (oldp1, oldp2), (newp1, newp2)

        Category is a unique identifier to allow overwriting an old callback
        with a newer callback.
        """

    @abc.abstractmethod
    def walk(
        self,
        match: matcher.IMatcher,
        subrepos: list[HgPathT],
        unknown: bool,
        ignored: bool,
        full: bool = True,
    ) -> WalkReturnT:
        """
        Walk recursively through the directory tree, finding all files
        matched by match.

        If full is False, maybe skip some known-clean files.

        Return a dict mapping filename to stat-like object (either
        mercurial.osutil.stat instance or return value of os.stat()).

        """

    @abc.abstractmethod
    def status(
        self,
        match: matcher.IMatcher,
        subrepos: bool,
        ignored: bool,
        clean: bool,
        unknown: bool,
        empty_dirs_keep_files: bool,
    ) -> StatusReturnT:
        """Determine the status of the working copy relative to the
        dirstate and return a pair of (unsure, status), where status is of type
        scmutil.status and:

          unsure:
            files that might have been modified since the dirstate was
            written, but need to be read to be sure (size is the same
            but mtime differs)
          status.modified:
            files that have definitely been modified since the dirstate
            was written (different size or mode)
          status.clean:
            files that have definitely not been modified since the
            dirstate was written
        """

    # TODO: could return a list, except git.dirstate is a generator

    @abc.abstractmethod
    def matches(self, match: matcher.IMatcher) -> Iterable[bytes]:
        """
        return files in the dirstate (in whatever state) filtered by match
        """

    # TODO: finish adding typehints here, and to subclasses

    @abc.abstractmethod
    def verify(
        self,
        m1,
        m2,
        p1: bytes,
        narrow_matcher: matcher.IMatcher | None = None,
    ) -> Iterator[bytes]:
        """
        check the dirstate contents against the parent manifest and yield errors
        """
