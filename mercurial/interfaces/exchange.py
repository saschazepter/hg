# mercurial/interfaces/exchange.py - typing protocol for exchange related object
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from typing import (
    Protocol,
)


from . import (
    _basetypes as i_base,
)


class IOutgoing(Protocol):
    """Represents the result of a findcommonoutgoing() call."""

    ancestorsof: list[i_base.NodeIdT]
    """a list of the nodes whose ancestors are included in the
    outgoing operation."""

    missing: list[i_base.NodeIdT]
    """list of those ancestors of ancestorsof that are present in
    local but not in remote."""

    common: set[i_base.RevnumT]
    """contains revs common between the local and the remote
    repository (at least all of those that are ancestors of ancestorsof)."""

    commonheads: list[i_base.RevnumT]
    """list of heads of `common`."""

    excluded: list[i_base.NodeIdT]
    """the list of missing changeset that shouldn't be sent remotely."""


class IRemotePhasesSummary(Protocol):
    """summarize phase information on the remote side"""

    publishing: bool
    public_heads: list[i_base.RevnumT]
    draft_heads: list[i_base.RevnumT]
    draft_roots: list[i_base.RevnumT]
