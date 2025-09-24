# changegroup.py - Type annotations for ChangeGroup related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
from typing import (
    Dict,
    Iterator,
    Protocol,
    Set,
)

from . import (
    _basetypes,
    matcher,
)


PreComputedEllipsisT = Dict[_basetypes.RevnumT, Set[_basetypes.RevnumT]]


class IChangeGroupPacker(Protocol):
    """An object able to produce a changegroup"""

    @abc.abstractmethod
    def __init__(
        self,
        repo: _basetypes.RepoT,
        oldmatcher: matcher.MatcherT,
        matcher: matcher.MatcherT,
        bundlecaps: set[bytes],
        ellipses: bool = False,
        shallow: bool = False,
        ellipsisroots: PreComputedEllipsisT | None = None,
        fullnodes: set[_basetypes.NodeIdT] | None = None,
        remote_sidedata: set[bytes] | None = None,
    ) -> None:
        ...

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
