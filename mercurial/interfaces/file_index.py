"""Interface for mercurial/store_utils/file_index.py.

The file index keeps track of all file paths in a repository. It provides a
mapping between file paths and integer tokens.
"""

from __future__ import annotations

import abc
from typing import Iterator, NewType, Protocol, Tuple

from ._basetypes import HgPathT
from .types import TransactionT


FileTokenT = NewType("FileTokenT", int)
"""An integer representing a file path in the repository."""


class IFileIndex(Protocol):
    """Interface for the file index.

    Not to be confused with ifileindex in mercurial/interfaces/repository.py,
    which is the storage interface for a revlog index (.i) file.
    """

    @abc.abstractmethod
    def get_path(self, token: FileTokenT) -> HgPathT | None:
        """Look up a path by token.

        Returns None if the token isn't in the file index.
        """

    @abc.abstractmethod
    def get_token(self, path: HgPathT) -> FileTokenT | None:
        """Look up a token by path.

        Returns None if the path isn't in the file index.
        """

    @abc.abstractmethod
    def has_token(self, token: FileTokenT) -> bool:
        """Return True if the token exists in the file index."""

    @abc.abstractmethod
    def has_path(self, path: HgPathT) -> bool:
        """Return True if the path exists in the file index."""

    @abc.abstractmethod
    def __contains__(self, path: HgPathT) -> bool:
        """Same as has_path."""

    @abc.abstractmethod
    def __len__(self) -> int:
        """Return the number of file paths in the file index."""

    @abc.abstractmethod
    def __iter__(self) -> Iterator[HgPathT]:
        """Iterate the paths in the file index."""

    @abc.abstractmethod
    def items(self) -> Iterator[Tuple[HgPathT, FileTokenT]]:
        """Iterate the file index entries as (path, token)."""

    @abc.abstractmethod
    def add(self, path: HgPathT, tr: TransactionT) -> FileTokenT:
        """Add a path to the file index and return the new token.

        If the path already exists in the file index, returns its token.
        """

    @abc.abstractmethod
    def vacuum(self, tr: TransactionT):
        """Vacuum the file index tree file.

        This is done automatically upon writing when the ratio of unused bytes
        gets too large, but this method provides a way to do it manually.
        """
