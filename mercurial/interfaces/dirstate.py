from __future__ import annotations

import abc
import contextlib
import enum
import os
import typing

from typing import (
    Callable,
    Collection,
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

    ParentFileDataT = tuple[int, int, Optional["TimestampT"]]
    """The ``(mode, size, mtime)`` of a file matching its parent content, as
    passed to dirstate.update_file()."""

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
    def v1_state(self) -> bytes:
        """The state the dirstate-v1 format records for this entry

        One of b'n', b'm', b'r', b'a' or b'?'. This is a direct expression of
        that format: use the semantic attributes instead.
        """

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

    @property
    @abc.abstractmethod
    def mode_size(self) -> tuple[int, int] | None:
        """The recorded mode and size of the clean version of the file

        None when the item records none. A file not matching them is
        modified; a file matching them is clean when its mtime matches too,
        or modified when `expected_state_is_modified` is set.
        """

    @property
    @abc.abstractmethod
    def mtime(self) -> tuple[int, int, bool] | None:
        """The recorded mtime of the file, or None when the item records none

        A `(seconds, nanoseconds, second_ambiguous)` tuple; with an
        ambiguous second, another write may share the mtime and the content
        has to be checked.
        """


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
    def changing_files(self, repo: IChangingContextRepo) -> Iterator[None]:
        """Context manager for handling dirstate files.

        If an exception occurs in the scope of the context manager,
        the incoherent dirstate won't be written when wlock is
        released.
        """

    @contextlib.contextmanager
    @abc.abstractmethod
    def running_status(self, repo: IChangingContextRepo) -> Iterator[None]:
        """Context manager wrapping a status operation

        This context is not mutually exclusive with the `changing_*` ones, and
        does not require the wlock.
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
    def invalidate_cwd(self) -> None:
        """invalidate the cached read of the current working directory

        The next `getcwd` call reads it again."""

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
    def prefetch_parents(self) -> None:
        """make sure the parents are loaded

        Used to avoid a race condition."""

    @abc.abstractmethod
    def p1(self) -> bytes:
        pass

    @abc.abstractmethod
    def p2(self) -> bytes:
        pass

    @abc.abstractmethod
    def branch(self) -> bytes:
        pass

    @abc.abstractmethod
    def setparents(
        self,
        p1: NodeIdT,
        p2: NodeIdT | None = None,
    ) -> dict[HgPathT, HgPathT]:
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
        parent: NodeIdT,
        allfiles: Collection[HgPathT],
        changedfiles: Collection[HgPathT] | None = None,
    ) -> None:
        pass

    @abc.abstractmethod
    def update_file(
        self,
        filename: HgPathT,
        wc_tracked: bool,
        p1_tracked: bool,
        p2_info: bool = False,
        possibly_dirty: bool = False,
        parentfiledata: ParentFileDataT | None = None,
    ) -> None:
        """update the information about a file in the dirstate

        This is to be called when the dirstate parents change, to keep track of
        the file situation regarding the working copy and its parents.

        This must be called within a `changing_parents` context.
        """

    @abc.abstractmethod
    def update_file_p1(
        self,
        filename: HgPathT,
        p1_tracked: bool,
    ) -> None:
        """Set a file as tracked in the parent (or not)

        This is to be called when adjusting the dirstate to a new parent after
        a history rewriting operation.

        It must not be called during a merge, and only within a
        `changing_parents` context.
        """

    @abc.abstractmethod
    def set_tracked(
        self,
        filename: HgPathT,
        reset_copy: bool = False,
    ) -> bool:
        """mark a file as tracked in the working copy

        This is to be called outside of the update/merge cases, for example by
        a command like `hg add X`, within a `changing_files` context.

        If `reset_copy` is set, any existing copy information is dropped.

        Return True if the file was previously untracked, False otherwise.
        """

    @abc.abstractmethod
    def set_clean(
        self,
        filename: HgPathT,
        parentfiledata: ParentFileDataT,
    ) -> None:
        """record that the current state of the file on disk is known to be
        clean

        This must be called within a `changing_files` or `running_status`
        context.
        """

    @abc.abstractmethod
    def set_possibly_dirty(self, filename: HgPathT) -> None:
        """record that the current state of the file on disk is unknown

        This must be called within a `changing_files` or `running_status`
        context.
        """

    @abc.abstractmethod
    def set_untracked(self, filename: HgPathT) -> bool:
        """mark a file as untracked in the working copy

        This is to be called outside of the update/merge cases, for example by
        a command like `hg remove X`, within a `changing_files` context.

        Return True if the file was previously tracked, False otherwise.
        """

    @abc.abstractmethod
    def write(self, tr: TransactionT | None) -> None:
        pass

    @abc.abstractmethod
    def all_file_names(self) -> tuple[bytes, ...]:
        """list all the files currently used by this dirstate

        The names are relative to the `.hg` directory. This is used to back
        them up in the transaction for `hg rollback`."""

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
