# mercurial/interfaces/bundke - typing protocol for bundle related object
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc

from typing import (
    Iterator,
    Protocol,
)


class IUnbundlePart(Protocol):
    """A protocol to match a bundle2 part for "unbundling"."""

    @abc.abstractmethod
    def __iter__(self) -> Iterator[bytes]:
        ...

    @abc.abstractmethod
    def consume(self) -> None:
        """Read the part payload until completion.

        By consuming the part data, the underlying stream read offset will
        be advanced to the next part (or end of stream).
        """

    @abc.abstractmethod
    def read(self, size: int | None = None) -> bytes:
        """read payload data"""
        ...

    @abc.abstractmethod
    def tell(self) -> int:
        ...
