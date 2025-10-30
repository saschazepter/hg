# mercurial/interfaces/exchange.py - typing protocol for exchange related object
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
from typing import (
    Any,
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


class IBundle20(Protocol):
    """represent an outgoing Bundle20 container

    Use the `addparam` method to add stream level parameter. and `newpart` to
    populate it. Then call `getchunks` to retrieve all the binary chunks of
    data that compose the bundle2 container."""

    capabilities: i_base.Capabilities
    prefercompressed: bool
    nbparts: int

    @abc.abstractmethod
    def setcompression(
        self,
        alg: bytes | None,
        compopts: dict | None = None,
    ) -> None:
        """setup core part compression to <alg>"""

    @abc.abstractmethod
    def addparam(self, name: bytes, value: None | bytes = None) -> None:
        """add a stream level parameter"""

    @abc.abstractmethod
    def addpart(self, part: IBundlePart) -> None:
        """add a new part to the bundle2 container

        Parts contains the actual applicative payload."""

    @abc.abstractmethod
    def newpart(self, typeid: bytes, *args, **kwargs) -> IBundlePart:
        """create a new part and add it to the containers

        As the part is directly added to the containers. For now, this means
        that any failure to properly initialize the part after calling
        ``newpart`` should result in a failure of the whole bundling process.

        You can still fall back to manually create and add if you need better
        control."""

    @abc.abstractmethod
    def getchunks(self) -> Iterator[bytes]:
        """yield the content of this bundle as bytes"""

    @abc.abstractmethod
    def salvageoutput(self) -> Collection[IBundlePart]:
        """return a list with a copy of all output parts in the bundle

        This is meant to be used during error handling to make sure we preserve
        server output"""


class IUnbundleRecords(Protocol):
    """keep record of what happens during and unbundle

    New records are added using `records.add('cat', obj)`. Where 'cat' is a
    category of record and obj is an arbitrary object.

    `records['cat']` will return all entries of this category 'cat'.

    Iterating on the object itself will yield `('category', obj)` tuples
    for all entries.

    All iterations happens in chronological order.
    """

    @abc.abstractmethod
    def add(
        self, category: bytes, entry: Any, inreplyto: int | None = None
    ) -> None:
        """add a new record of a given category.

        The entry can then be retrieved in the list returned by
        self['category']."""

    @abc.abstractmethod
    def getreplies(self, partid) -> "IUnbundleRecords":
        """get the records that are replies to a specific part"""

    @abc.abstractmethod
    def __getitem__(self, cat: bytes) -> Collection[Any]:
        """return all records in a given category"""

    @abc.abstractmethod
    def __iter__(self) -> tuple[bytes, Any]:
        """iter over every records a ('cat', obj)"""

    @abc.abstractmethod
    def __len__(self) -> int:
        """Number of records"""

    @abc.abstractmethod
    def __bool__(self) -> bool:
        """True if the records hold any information"""


class IUnbundleOperation(Protocol):
    """an object that represents the processing of a single

    Its purpose is to carry unbundle-related objects and states.

    A new object should be created at the beginning of each bundle processing.
    The object is to be returned by the processing function.

    The object has very little content now it will ultimately contain:
    * an access to the repo the bundle is applied to,
    * a ui object,
    * a way to retrieve a transaction to add changes to the repo,
    * a way to record the result of processing each part,
    * a way to construct a bundle response when applicable.
    """

    repo: i_repo.IRepo
    ui: i_base.UiT
    source = bytes
    records: IUnbundleRecords
    remote: i_repo.peer | None
    reply: IBundle20 | None
    captureoutput: bool
    modes: dict[int, int]

    @abc.abstractmethod
    def gettransaction(self) -> i_tr.ITransaction:
        """return an active transaction to unbundle into"""

    @abc.abstractmethod
    def addhookargs(self, hookargs: dict[bytes, bytes]):
        """add new hook args

        Can only be called before the transaction start.
        """
