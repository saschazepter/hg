# changegroup.py - Type annotations for ChangeGroup related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
from typing import (
    Iterator,
    Protocol,
)

from . import _basetypes


class IChangeGroupPacker(Protocol):
    """An object able to produce a changegroup"""

    @abc.abstractmethod
    def generate(
        self,
        commonrevs: set[_basetypes.RevnumT],
        clnodes: list[_basetypes.NodeIdT],
        fastpathlinkrev: bool,
        source: bytes,
        changelog: bool = True,
    ) -> Iterator[bytes]:
        ...
