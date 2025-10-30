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


class IRemotePhasesSummary(Protocol):
    """summarize phase information on the remote side"""

    publishing: bool
    public_heads: list[i_base.RevnumT]
    draft_heads: list[i_base.RevnumT]
    draft_roots: list[i_base.RevnumT]
