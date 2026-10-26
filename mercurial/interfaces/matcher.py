# mercurial/interfaces/matcher - typing protocol for Matcher objects
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc

from typing import (
    Callable,
    Protocol,
)

from ._basetypes import (
    HgPathT,
    UserMsgT,
)


class BadFuncT(Protocol):
    """The type for a bad match callback that can be supplied by matcher user"""

    def __call__(self, file: HgPathT, msg: UserMsgT | None) -> None:
        # TODO: a message should probably always be provided (it is not from
        #  manifest.py)
        raise NotImplementedError


KindPatT = tuple[bytes, bytes, bytes]
"""A parsed ``kind:pattern`` type.

The first entry is the kind of pattern, the second is the pattern, and the third
is the source of the pattern (or an empty string).
"""

MatchFuncT = Callable[[HgPathT], bool]
"""The signature of a matcher compatible matching function.

Given the path of a file, the method returns True to indicate a match.
"""

TraverseDirFuncT = Callable[[HgPathT], None]
"""The callback type that provides the directory being traversed."""


class IMatcher(Protocol):
    """A protocol class that defines the common interface for all file matching
    classes."""

    @abc.abstractmethod
    def was_tampered_with_nonrec(self) -> bool:
        ...

    @abc.abstractmethod
    def was_tampered_with(self) -> bool:
        ...

    @abc.abstractmethod
    def __call__(self, fn: HgPathT) -> bool:
        ...

    # Callbacks related to how the matcher is used by dirstate.walk.
    # Subscribers to these events must monkeypatch the matcher object.
    @abc.abstractmethod
    def bad(self, f: HgPathT, msg: UserMsgT | None) -> None:
        ...

    # If traversedir is set, it will be called when a directory discovered
    # by recursive traversal is visited.
    traversedir: TraverseDirFuncT | None = None

    @property
    @abc.abstractmethod
    def _files(self) -> list[HgPathT]:
        ...

    @abc.abstractmethod
    def files(self) -> list[HgPathT]:
        ...

    @property
    @abc.abstractmethod
    def _fileset(self) -> set[HgPathT]:
        ...

    @abc.abstractmethod
    def exact(self, f: HgPathT) -> bool:
        """Returns True if f is in .files()."""

    @abc.abstractmethod
    def matchfn(self, f: HgPathT) -> bool:
        ...

    @abc.abstractmethod
    def visitdir(self, dir: HgPathT) -> bool | bytes:
        """Tells the caller whether files under `dir` (not including `dir`
        itself) can match, so that it can skip the parts of the tree that
        contain no match.

        Returns False if no file under `dir` matches; the caller can skip
        `dir`. Returns 'all' if every file under `dir` matches. Returns True if
        the matcher can't tell; the caller has to look inside `dir`.
        """

    @abc.abstractmethod
    def visitchildrenset(self, dir: HgPathT) -> set[HgPathT] | bytes:
        """Tells the caller which files under `dir` (not including `dir`
        itself) can match, so that it can skip the parts of the tree that
        contain no match.

        The return value is one of:

          set()
            No file under `dir` matches. The caller can skip `dir`.
          a non-empty set of names, such as {'a', 'b'}
            Only the listed children of `dir` can contain matches: a file
            under `dir` can only match if it is `dir/a`, `dir/b`, or inside
            one of them. The caller can skip every other child. The entries
            are names (like 'a'), not full paths (like 'dir/a'). An entry may
            be a file, a directory, or a name that does not exist. The caller
            still has to check the files inside the listed children.
          'this'
            The matcher can't tell which files under `dir` match. The caller
            has to look at every child of `dir`.
          'all'
            Every file under `dir` matches. The caller does not need to call
            the matcher for anything under `dir`.

        The answer does not have to be as precise as possible, but it must
        never be wrong. A matcher that can't tell can always return 'this'.

        This function is very similar to 'visitdir', and the following mapping
        can be applied:

             visitdir | visitchildrenset
            ----------+-------------------
             False    | set()
             'all'    | 'all'
             True     | 'this' OR non-empty set of names

        Example:
          Assume matchers ['path:foo/bar', 'rootfilesin:qux'], we would return
          the following values (assuming the implementation of visitchildrenset
          is capable of recognizing this; some implementations are not).

          '' -> {'foo', 'qux'}
          'baz' -> set()
          'foo' -> {'bar'}
          # Ideally this would be 'all', but since the prefix nature of matchers
          # is applied to the entire matcher, we have to downgrade this to
          # 'this' due to the non-prefix 'rootfilesin'-kind matcher being mixed
          # in.
          'foo/bar' -> 'this'
          'qux' -> 'this'

        Important:
          Most matchers do not know if they're representing files or
          directories. They see ['path:dir/f'] and don't know whether 'f' is a
          file or a directory, so visitchildrenset('dir') for most matchers will
          return {'f'}, but if the matcher knows it's a file (like exactmatcher
          does), it may return 'this'. Do not rely on the return being a set
          indicating that there are no files in this dir to investigate (or
          equivalently that if there are files to investigate in 'dir' that it
          will always return 'this').
        """

    @abc.abstractmethod
    def always(self) -> bool:
        """Matcher will match everything and .files() will be empty --
        optimization might be possible."""

    @abc.abstractmethod
    def isexact(self) -> bool:
        """Matcher will match exactly the list of files in .files() --
        optimization might be possible."""

    @abc.abstractmethod
    def prefix(self) -> bool:
        """Matcher will match the paths in .files() recursively --
        optimization might be possible."""

    @abc.abstractmethod
    def anypats(self) -> bool:
        """None of .always(), .isexact(), and .prefix() is true --
        optimizations will be difficult."""


MatcherT = IMatcher
