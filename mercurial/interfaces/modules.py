# modules.py - protocol classes for dynamically loaded modules
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import typing

from typing import (
    List,
    Protocol,
    Tuple,
)

if typing.TYPE_CHECKING:
    BDiffBlock = Tuple[int, int, int, int]
    """An entry in the list returned by bdiff.blocks()."""


class BDiff(Protocol):
    """A Protocol class for the various bdiff module implementations."""

    def splitnewlines(self, text: bytes) -> List[bytes]:
        """like str.splitlines, but only split on newlines."""

    def bdiff(self, a: bytes, b: bytes) -> bytes:
        ...

    def blocks(self, a: bytes, b: bytes) -> List[BDiffBlock]:
        ...

    def fixws(self, text: bytes, allws: bool) -> bytes:
        ...
