# mercurial/interfaces/exchange.py - typing protocol for exchange related object
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
from typing import (
    Collection,
    Iterator,
    Protocol,
)


from . import (
    _basetypes as i_base,
    context as i_ctx,
    misc as i_misc,
    repository as i_repo,
    transaction as i_tr,
)


class ITransactionManager(Protocol):
    """An object to manage the life cycle of a transaction

    It creates the transaction on demand and calls the appropriate hooks when
    closing the transaction."""

    @abc.abstractmethod
    def transaction(self) -> i_tr.ITransaction:
        """Return an open transaction object, constructing if necessary"""

    @abc.abstractmethod
    def close(self):
        """close transaction if created"""

    @abc.abstractmethod
    def release(self):
        """release transaction if created"""

    @abc.abstractmethod
    def __enter__(self) -> 'ITransactionManager':
        ...

    @abc.abstractmethod
    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        ...


class IPullOperation(Protocol):
    """A object that represent a single pull operation"""

    # This protocol is a stub, you can help by expanding it
    # (or shrinking if we blindly things that are too internal)

    repo: i_repo.IRepo
    """repo we pull into"""

    remote: i_repo.peer
    """repo we pull from"""

    remote_path: i_misc.IPath
    """path object used to build this remote

    XXX Ideally we would just fetch this from the `remote`
    """

    heads: Collection[i_base.RevnumT]
    """revision we try to pull (None is "all")"""

    explicitbookmarks: Collection[bytes]
    """bookmark pulled explicitly"""

    force: bool
    """do we force pull?"""

    streamclonerequested: bool
    """whether a streaming clone was requested"""

    trmanager: ITransactionManager
    """transaction manager"""

    common: set[i_base.NodeIdT] | None
    """set of common changeset between local and remote before pull"""

    rheads: set[i_base.NodeIdT]
    """set of pulled head"""

    fetch: set[i_base.NodeIdT]
    """list of missing changeset to fetch remotely"""

    remotebookmarks: dict[bytes, i_base.NodeIdT]
    """remote bookmarks data"""

    cgresult: int
    """result of changegroup pulling (used as return code by pull)"""

    stepsdone: set[bytes]
    """list of step already done"""

    clonebundleattempted: bool
    """Whether we attempted a clone from pre-generated bundles."""

    includepats: set[bytes]
    """Set of file patterns to include."""

    excludepats: set[bytes]
    """Set of file patterns to exclude."""

    depth: int | None
    """Number of ancestor changesets to pull from each pulled head."""

    canusebundle2: bool
    """can the bundle2 format be used"""

    remotebundle2caps: i_base.Capabilities


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


class IPushOperation(Protocol):
    """A object that represent a single push operation"""

    # This protocol is a stub, you can help by expanding it
    # (or shrinking if we blindly things that are too internal)

    repo: i_repo.IRepo
    """repo we push from"""

    ui: i_base.UiT

    remote: i_repo.peer
    """repo we push to"""

    force: bool
    """force option provided"""

    revs: None | Collection[i_base.RevnumT]
    """revs to be pushed (None is "all")"""

    bookmarks: Collection[bytes]
    """bookmark explicitly pushed"""

    newbranch: bool
    """allow push of new branch"""

    stepsdone: set[bytes]
    """step already performed"""

    cgresult: int | None
    """Integer version of the changegroup push result

    - None means nothing to push
    - 0 means HTTP error
    - 1 means we pushed and remote head count is unchanged *or*
      we have outgoing changesets but refused to push
    - other values as described by addchangegroup()
    """

    bkresult: int | None
    """integer value for the bookmark push"""

    outgoing: IOutgoing
    """discover.outgoing object (contains common and outgoing data)"""

    remoteheads: Collection[i_base.NodeIdT] | None
    """all remote topological heads before the push"""

    pushbranchmap: dict[bytes, list[bytes]] | None
    """Details of the remote branch pre and post push

    mapping: {'branch': ([remoteheads],
                         [newheads],
                         [unsyncedheads],
                         [discardedheads])}
    - branch: the branch name
    - remoteheads: the list of remote heads known locally
                   None if the branch is new
    - newheads: the new remote heads (known locally) with outgoing pushed
    - unsyncedheads: the list of remote heads unknown locally.
    - discardedheads: the list of remote heads made obsolete by the push
    """

    incoming: bool | None
    """testable as a boolean indicating if any nodes are missing locally."""

    remotephases: IRemotePhasesSummary | None
    """summary of the remote phase situation"""

    outdatedphases: list[i_ctx.IChangeContext] | None
    """phases changes that must be pushed along side the changesets"""

    fallbackoutdatedphases: list[i_ctx.IChangeContext] | None

    """phases changes that must be pushed if changeset push fails"""

    outobsmarkers: Collection[
        tuple[
            bytes,
            tuple[bytes, ...],
            int,
            dict[bytes, bytes],
            tuple[float, int],
            tuple[bytes, ...] | None,
        ]
    ]
    """outgoing obsmarkers"""

    outbookmarks: list[tuple[bytes, bytes, bytes]]
    """outgoing bookmarks, list of (bm, oldnode | '', newnode | '')"""

    trmanager: ITransactionManager | None
    """transaction manager"""

    pkfailcb: dict
    """ map { pushkey partid -> callback handling failure}
    used to handle exception from mandatory pushkey part failure
    """

    pushvars: dict[bytes, bytes] | None
    """an iterable of pushvars or None"""

    publish: bool
    """publish pushed changesets"""


class IBundlePart(Protocol):
    """A bundle2 part contains application level payload

    The part `type` is used to route the part to the application level
    handler.

    The part payload is contained in ``part.data``. It could be raw bytes or a
    generator of byte chunks.

    You can add parameters to the part using the ``addparam`` method.
    Parameters can be either mandatory (default) or advisory. Remote side
    should be able to safely ignore the advisory ones.

    Both data and parameters cannot be modified after the generation has begun.
    """

    id: bytes | None
    type: bytes
    mandatory: bool
    data: bytes
    mandatoryparams: dict[bytes, bytes]
    advisoryparams: dict[bytes, bytes]

    @abc.abstractmethod
    def copy(self) -> "IBundlePart":
        """return a copy of the part

        The new part have the very same content but no partid assigned yet.
        Parts with generated data cannot be copied."""

    @abc.abstractmethod
    def addparam(
        self,
        name: bytes,
        value: bytes = b'',
        mandatory: bool = True,
    ) -> None:
        """add a parameter to the part

        If 'mandatory' is set to True, the remote handler must claim support
        for this parameter or the unbundling will be aborted.

        The 'name' and 'value' cannot exceed 255 bytes each.
        """

    @abc.abstractmethod
    def getchunks(self, ui) -> Iterator[bytes]:
        """Yield bytes that containt the part header and payload"""
        ...
