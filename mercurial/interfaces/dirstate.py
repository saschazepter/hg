from __future__ import annotations

import contextlib
import os
import typing

from typing import (
    Any,
    Callable,
    Dict,
    Iterable,
    Iterator,
    List,
    Optional,
    Protocol,
    Tuple,
)

if typing.TYPE_CHECKING:
    # Almost all mercurial modules are only imported in the type checking phase
    # to avoid circular imports
    from .. import (
        match as matchmod,
        scmutil,
        transaction as txnmod,
    )

    # TODO: finish adding type hints
    AddParentChangeCallbackT = Callable[
        ["idirstate", Tuple[Any, Any], Tuple[Any, Any]], Any
    ]
    """The callback type for dirstate.addparentchangecallback()."""

    # TODO: add a Protocol for dirstatemap.DirStateItem? (It is
    #  conditionalized with python or rust implementations.  Also,
    #  git.dirstate needs to yield non-None from ``items()``.)
    DirstateItemT = Any  # dirstatemap.DirstateItem

    IgnoreFileAndLineT = Tuple[Optional[bytes], int, bytes]
    """The return type of dirstate._ignorefileandline(), which holds
    ``(file, lineno, originalline)``.
    """

    FlagFuncFallbackT = Callable[[], "FlagFuncReturnT"]
    """The type for the dirstate.flagfunc() fallback function."""

    FlagFuncReturnT = Callable[[bytes], bytes]
    """The return type of dirstate.flagfunc()."""

    # TODO: verify and complete this- it came from a pytype *.pyi file
    StatusReturnT = Tuple[Any, scmutil.status, Any]
    """The return type of dirstate.status()."""

    # TODO: probably doesn't belong here.
    TransactionT = txnmod.transaction
    """The type for a transaction used with dirstate.

    This is meant to help callers avoid having to remember to delay the import
    of the transaction module.
    """

    # TODO: The value can also be mercurial.osutil.stat
    WalkReturnT = Dict[bytes, Optional[os.stat_result]]
    """The return type of dirstate.walk().

    The matched files are keyed in the dictionary, mapped to a stat-like object
    if the file exists.
    """


class idirstate(Protocol):
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

    # TODO: all these private methods and attributes should be made
    # public or removed from the interface.

    # TODO: decorate with `@rootcache(b'.hgignore')` like dirstate class?
    @property
    def _ignore(self) -> matchmod.basematcher:
        """Matcher for ignored files."""

    @property
    def is_changing_any(self) -> bool:
        """True if any changes in progress."""

    @property
    def is_changing_parents(self) -> bool:
        """True if parents changes in progress."""

    @property
    def is_changing_files(self) -> bool:
        """True if file tracking changes in progress."""

    def _ignorefiles(self) -> List[bytes]:
        """Return a list of files containing patterns to ignore."""

    def _ignorefileandline(self, f: bytes) -> IgnoreFileAndLineT:
        """Given a file `f`, return the ignore file and line that ignores it."""

    # TODO: decorate with `@util.propertycache` like dirstate class?
    #  (can't because circular import)
    @property
    def _checklink(self) -> bool:
        """Callable for checking symlinks."""  # TODO: this comment looks stale

    # TODO: decorate with `@util.propertycache` like dirstate class?
    #  (can't because circular import)
    @property
    def _checkexec(self) -> bool:
        """Callable for checking exec bits."""  # TODO: this comment looks stale

    @contextlib.contextmanager
    def changing_parents(self, repo) -> Iterator:  # TODO: typehint this
        """Context manager for handling dirstate parents.

        If an exception occurs in the scope of the context manager,
        the incoherent dirstate won't be written when wlock is
        released.
        """

    @contextlib.contextmanager
    def changing_files(self, repo) -> Iterator:  # TODO: typehint this
        """Context manager for handling dirstate files.

        If an exception occurs in the scope of the context manager,
        the incoherent dirstate won't be written when wlock is
        released.
        """

    def hasdir(self, d: bytes) -> bool:
        pass

    def flagfunc(self, buildfallback: FlagFuncFallbackT) -> FlagFuncReturnT:
        """build a callable that returns flags associated with a filename

        The information is extracted from three possible layers:
        1. the file system if it supports the information
        2. the "fallback" information stored in the dirstate if any
        3. a more expensive mechanism inferring the flags from the parents.
        """

    def getcwd(self) -> bytes:
        """Return the path from which a canonical path is calculated.

        This path should be used to resolve file patterns or to convert
        canonical paths back to file paths for display. It shouldn't be
        used to get real file paths. Use vfs functions instead.
        """

    def pathto(self, f: bytes, cwd: Optional[bytes] = None) -> bytes:
        pass

    def get_entry(self, path: bytes) -> DirstateItemT:
        """return a DirstateItem for the associated path"""

    def __contains__(self, key: Any) -> bool:
        """Check if bytestring `key` is known to the dirstate."""

    def __iter__(self) -> Iterator[bytes]:
        """Iterate the dirstate's contained filenames as bytestrings."""

    def items(self) -> Iterator[Tuple[bytes, DirstateItemT]]:
        """Iterate the dirstate's entries as (filename, DirstateItem.

        As usual, filename is a bytestring.
        """

    iteritems = items

    def parents(self) -> List[bytes]:
        pass

    def p1(self) -> bytes:
        pass

    def p2(self) -> bytes:
        pass

    def branch(self) -> bytes:
        pass

    # TODO: typehint the return.  It's a copies Map of some sort.
    def setparents(self, p1: bytes, p2: Optional[bytes] = None):
        """Set dirstate parents to p1 and p2.

        When moving from two parents to one, "merged" entries a
        adjusted to normal and previous copy records discarded and
        returned by the call.

        See localrepo.setparents()
        """

    def setbranch(
        self, branch: bytes, transaction: Optional[TransactionT]
    ) -> None:
        pass

    def invalidate(self) -> None:
        """Causes the next access to reread the dirstate.

        This is different from localrepo.invalidatedirstate() because it always
        rereads the dirstate. Use localrepo.invalidatedirstate() if you want to
        check whether the dirstate has changed before rereading it."""

    def copy(self, source: Optional[bytes], dest: bytes) -> None:
        """Mark dest as a copy of source. Unmark dest if source is None."""

    def copied(self, file: bytes) -> Optional[bytes]:
        pass

    def copies(self) -> Dict[bytes, bytes]:
        pass

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

    def clear(self) -> None:
        pass

    def rebuild(
        self,
        parent: bytes,
        allfiles: Iterable[bytes],  # TODO: more than iterable? (uses len())
        changedfiles: Optional[Iterable[bytes]] = None,
    ) -> None:
        pass

    def write(self, tr: Optional[TransactionT]) -> None:
        pass

    def addparentchangecallback(
        self, category: bytes, callback: AddParentChangeCallbackT
    ) -> None:
        """add a callback to be called when the wd parents are changed

        Callback will be called with the following arguments:
            dirstate, (oldp1, oldp2), (newp1, newp2)

        Category is a unique identifier to allow overwriting an old callback
        with a newer callback.
        """

    def walk(
        self,
        match: matchmod.basematcher,
        subrepos: Any,  # TODO: figure out what this is
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

    def status(
        self,
        match: matchmod.basematcher,
        subrepos: bool,
        ignored: bool,
        clean: bool,
        unknown: bool,
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

    def matches(self, match: matchmod.basematcher) -> Iterable[bytes]:
        """
        return files in the dirstate (in whatever state) filtered by match
        """

    # TODO: finish adding typehints here, and to subclasses

    def verify(
        self, m1, m2, p1: bytes, narrow_matcher: Optional[Any] = None
    ) -> Iterator[bytes]:
        """
        check the dirstate contents against the parent manifest and yield errors
        """
