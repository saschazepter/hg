"""Interface for mercurial/store_utils/file_index.py.

The file index keeps track of all file paths in a repository. It provides a
mapping between file paths and integer tokens.
"""

from __future__ import annotations

import abc
import enum
from typing import Iterator, NewType, Protocol

from ._basetypes import HgPathT
from .types import TransactionT, UiT, VfsT


FileTokenT = NewType("FileTokenT", int)
"""An integer representing a file path in the repository."""


class VacuumMode(enum.Enum):
    """Values of the config ``devel.fileindex.vacuum-mode``."""

    AUTO = b"auto"
    NEVER = b"never"
    ALWAYS = b"always"


class IFileIndex(Protocol):
    """Interface for the file index.

    Not to be confused with ifileindex in mercurial/interfaces/repository.py,
    which is the storage interface for a revlog index (.i) file.
    """

    @abc.abstractmethod
    def __init__(
        self,
        ui: UiT,
        opener: VfsT,
        try_pending: bool,
        vacuum_mode: VacuumMode,
        max_unused_ratio: float,
        gc_retention_s: int,
        garbage_timestamp: int | None,
    ):
        """Open the file index.

        :param ui:
            The UI object.
        :param opener:
            The store VFS.
        :param try_pending:
            If True, tries to open the pending docket before the normal one.
        :param vacuum_mode:
            Value of config ``devel.fileindex.vacuum-mode``.
        :param max_unused_ratio:
            Value of config ``storage.fileindex.max-unused-percentage``,
            converted to a ratio from 0 to 1.
        :param gc_retention_s:
            Value of config ``storage.fileindex.gc-retention-seconds``.
        :param garbage_timestamp:
            Value of config ``devel.fileindex.garbage-timestamp``.
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
    def items(self) -> Iterator[tuple[HgPathT, FileTokenT]]:
        """Iterate the file index entries as (path, token)."""

    @abc.abstractmethod
    def add(self, path: HgPathT, tr: TransactionT) -> FileTokenT:
        """Add a path to the file index and return the new token.

        If the path already exists in the file index, returns its token.

        It is not allowed to call add and remove in the same transaction.
        """

    @abc.abstractmethod
    def remove(self, path: HgPathT, tr: TransactionT):
        """Remove a path from the file index.

        Raises a ValueError if the path is not in the file index.

        It is not allowed to call add and remove in the same transaction.
        """

    @abc.abstractmethod
    def vacuum(self, tr: TransactionT):
        """Vacuum the file index tree file.

        This is done automatically upon writing when the ratio of unused bytes
        gets too large, but this method provides a way to do it manually.
        """

    @abc.abstractmethod
    def garbage_collect(self, tr: TransactionT, force: bool = False):
        """Delete data files eligible for garbage collection.

        When the file index writes a new data file instead of appending to an
        existing one, it adds the old file to the garbage list. That file
        becomes eligible for garbage collection once the retention period has
        elapsed (configured by storage.fileindex.gc-retention-seconds) and a
        certain number of transactions have occurred.

        If force is True, deletes all files in the garbage list unconditionally.
        """

    @abc.abstractmethod
    def data_files(self) -> list[HgPathT]:
        """Return the files where the file index is persisted on disk.

        The paths are relative to the VFS passed to the constructor.
        """
