# changegroup.py - Type annotations for ChangeGroup related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import io
from typing import (
    Dict,
    Iterator,
    Protocol,
    Set,
)

from . import (
    _basetypes,
    matcher,
    repository,
)


PreComputedEllipsisT = Dict[_basetypes.RevnumT, Set[_basetypes.RevnumT]]


class IChangeGroupUnpacker(Protocol):
    """Unpacker for a "changegroup" stream

    A changegroup unpacker handles the framing of the revision data in
    the wire format. Most consumers will want to use the apply()
    method to add the changes from the changegroup to a repository.

    If you're forwarding a changegroup unmodified to another consumer,
    use getchunks(), which returns an iterator of changegroup
    chunks. This is mostly useful for cases where you need to know the
    data stream has ended by observing the end of the changegroup.

    deltachunk() is useful only if you're applying delta data. Most
    consumers should prefer apply() instead.

    A few other public methods exist. Those are used only for
    bundlerepo and some debug commands - their use is discouraged.
    """

    extra: dict[bytes, _basetypes.NeedsTypeHint]

    version: bytes
    extras: dict[bytes, _basetypes.NeedsTypeHint]

    @abc.abstractmethod
    def __init__(
        self,
        # The fh can be a read only stream and we need further typing and
        # refactoring to distinct the two cases.
        fh: io.BytesIO | _basetypes.NeedsTypeHint,
        alg: bytes | None,
        extras: dict[bytes, _basetypes.NeedsTypeHint] | None = None,
    ) -> None:
        ...

    @abc.abstractmethod
    def deltaiter(self) -> Iterator[repository.IInboundRevision]:
        """returns an iterator of the deltas in this changegroup

        Useful for passing to the underlying storage system to be stored.
        """
        ...

    @abc.abstractmethod
    def deltachunk(
        self,
        prevnode: bytes | None,
    ) -> repository.IInboundRevision | None:
        """return one specific delta coming after another node"""
        ...

    @abc.abstractmethod
    def getchunks(self) -> Iterator[bytes]:
        """returns all the chunks contains in the bundle

        Used when you need to forward the binary stream to a file or another
        network API. To do so, it parse the changegroup data, otherwise it will
        block in case of sshrepo because it don't know the end of the stream.
        """
        ...

    @abc.abstractmethod
    def changelogheader(self):
        """v10 does not have a changelog header chunk"""
        ...

    @abc.abstractmethod
    def manifestheader(self):
        """v10 does not have a manifestlog header chunk"""
        ...

    @abc.abstractmethod
    def filelogheader(self):
        """return the header of the filelogs chunk, v10 only has the filename"""

    ### XXX from there this is weird methode that should be on a dedicated "Seekable Changegroup" method.
    @abc.abstractmethod
    def read(self, l: int) -> bytes:
        ...

    @abc.abstractmethod
    def seek(self, pos: int) -> None:
        ...

    @abc.abstractmethod
    def tell(self) -> int:
        ...

    @abc.abstractmethod
    def close(self) -> None:
        ...


class IChangeGroupPacker(Protocol):
    """An object able to produce a changegroup"""

    @abc.abstractmethod
    def __init__(
        self,
        repo: repository.IRepo,
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
