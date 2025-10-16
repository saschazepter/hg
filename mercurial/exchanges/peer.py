# mercurial/exchanges/peer.py - command code for peers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc

from ..i18n import _
from ..interfaces.types import (
    UiT,
)

from .. import (
    error,
)
from ..interfaces import (
    misc as i_misc,
    repository as i_repo,
)


class Peer(i_repo.IPeer, abc.ABC):
    """common code for Peer class"""

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
