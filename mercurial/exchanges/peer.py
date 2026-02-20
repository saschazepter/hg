# mercurial/exchanges/peer.py - command code for peers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc

from typing import Optional

from ..i18n import _
from ..interfaces.types import (
    RepoT,
    UiT,
)

from .. import (
    error,
    repoview,
)
from ..interfaces import (
    misc as i_misc,
    repository as i_repo,
)


class PhaseSummary(i_repo.IPhaseSummary):
    """A summary of some relevant phase data for the peer"""

    _HEADER_V1 = b'phase-summary-v01:'

    publishing: bool
    all_public: bool

    def __init__(self, publishing: bool, all_public: bool):
        self.publishing = publishing
        self.all_public = all_public

    @classmethod
    def try_parse(cls, line: bytes) -> Optional['PhaseSummary']:
        if line.startswith(cls._HEADER_V1):
            raw_item = line.split(b':', 1)[1].split()
            items = dict(i.split(b'=', 1) for i in raw_item)
            return cls(
                publishing=items.get(b'publish') == b'all',
                all_public=items.get(b'public-revs') == b'all',
            )
        return None


class Peer(i_repo.IPeer, abc.ABC):
    """common code for Peer class"""

    phase_summary = None

    def __init__(
        self,
        ui: UiT,
        path: i_misc.IPath | None = None,
        remotehidden: bool = False,
    ) -> None:
        self.ui = ui
        self.path = path

    def capable(self, name: bytes) -> bool | bytes:
        caps = self.capabilities()
        if name in caps:
            return True

        name = b'%s=' % name
        for cap in caps:
            if cap.startswith(name):
                return cap[len(name) :]

        return False

    def is_capable(self, name: bytes) -> bool:
        ret = self.capable(name)
        if isinstance(ret, bool):
            return ret
        else:
            return True

    def cap_value(self, name: bytes) -> bytes:
        value = self.capable(name)
        if isinstance(value, bool):
            return b''
        return value

    def requirecap(self, name: bytes, purpose: bytes) -> None:
        if self.capable(name):
            return

        raise error.CapabilityError(
            _(
                b'cannot %s; remote repository does not support the '
                b'\'%s\' capability'
            )
            % (purpose, name)
        )


def server_filtername(repo: RepoT, accesshidden: bool) -> bytes:
    """return the view to use for a server"""
    viewconfig = repo.ui.config(b'server', b'view')

    if (
        accesshidden
        and viewconfig is not None
        and viewconfig + b'.hidden' in repoview.filtertable
    ):
        viewconfig += b'.hidden'
    return viewconfig
