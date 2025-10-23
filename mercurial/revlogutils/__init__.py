# mercurial.revlogutils -- basic utilities for revlog
#
# Copyright 2019 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc

from typing import (
    Optional,
    Protocol,
    TYPE_CHECKING,
)

from ..thirdparty import attr

# Force pytype to use the non-vendored package
if TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

from ..interfaces.types import (
    NodeIdT,
    RevnumT,
)
from ..interfaces import (
    compression as i_comp,
    repository,
    revlog as revlog_t,
)

# See mercurial.revlogutils.constants for doc
COMP_MODE_INLINE = 2
RANK_UNKNOWN = -1


def offset_type(offset, type):
    if (type & ~repository.REVISION_FLAGS_KNOWN) != 0:
        raise ValueError(b'unknown revlog index flags: %d' % type)
    return int(int(offset) << 16 | type)


def entry(
    data_offset,
    data_compressed_length,
    data_delta_base,
    link_rev,
    parent_rev_1,
    parent_rev_2,
    node_id,
    flags=0,
    data_uncompressed_length=None,
    data_compression_mode=COMP_MODE_INLINE,
    sidedata_offset=0,
    sidedata_compressed_length=0,
    sidedata_compression_mode=COMP_MODE_INLINE,
    rank=RANK_UNKNOWN,
):
    """Build one entry from symbolic name

    This is useful to abstract the actual detail of how we build the entry
    tuple for caller who don't care about it.

    This should always be called using keyword arguments. Some arguments have
    default value, this match the value used by index version that does not store such data.
    """
    return (
        offset_type(data_offset, flags),
        data_compressed_length,
        data_uncompressed_length,
        data_delta_base,
        link_rev,
        parent_rev_1,
        parent_rev_2,
        node_id,
        sidedata_offset,
        sidedata_compressed_length,
        data_compression_mode,
        sidedata_compression_mode,
        rank,
    )


@attr.s(slots=True)
class DeltaQuality(repository.IDeltaQuality):
    """Information about the quality of a delta"""

    is_good = attr.ib(type=bool, default=False)
    """the delta is considered good"""
    p1_small = attr.ib(type=bool, default=False)
    """delta vs first parent produce a smaller delta"""
    p2_small = attr.ib(type=bool, default=False)
    """delta vs second parent produce a smaller delta"""

    def to_v1_flags(self) -> int:
        """serialize this information to revlog index flag"""
        flags = repository.REVISION_FLAG_DELTA_HAS_QUALITY
        if self.is_good:
            flags |= repository.REVISION_FLAG_DELTA_IS_GOOD
        if self.p1_small:
            flags |= repository.REVISION_FLAG_DELTA_P1_IS_SMALL
        if self.p2_small:
            flags |= repository.REVISION_FLAG_DELTA_P2_IS_SMALL
        return flags

    @staticmethod
    def from_v1_flags(flags) -> DeltaQuality | None:
        if not flags & repository.REVISION_FLAG_DELTA_HAS_QUALITY:
            return None
        return DeltaQuality(
            is_good=bool(flags & repository.REVISION_FLAG_DELTA_IS_GOOD),
            p1_small=bool(flags & repository.REVISION_FLAG_DELTA_P1_IS_SMALL),
            p2_small=bool(flags & repository.REVISION_FLAG_DELTA_P2_IS_SMALL),
        )


@attr.s(slots=True)
class CachedDelta:
    base = attr.ib(type=RevnumT)
    """The revision number of the revision on which the delta apply on"""
    u_delta = attr.ib(type=Optional[bytes], default=None)
    """The uncompressed delta data if any

    If None, `c_delta` must be set
    """
    reuse_policy = attr.ib(
        type=Optional[revlog_t.DeltaBaseReusePolicy],
        default=None,
    )
    """The policy request to reuse this delta"""
    snapshot_level = attr.ib(type=Optional[int], default=None)
    """The snapshot_level of this delta.

    Possible values:
    * None: No snapshot information for this delta,
    * -1:   Delta isn't a snapshot,
    * >=0:  Detla is a snapshot of the corresponding level.
    """
    c_delta = attr.ib(type=Optional[bytes], default=None)
    """The compressed delta data if any

    If None, `u_delta` must be set
    If not None, `compression` must be set
    """
    compression = attr.ib(
        type=i_comp.RevlogCompHeader,
        default=i_comp.REVLOG_COMP_NONE,
    )
    """The type of compression used by the data in `c_delta`

    When `c_delta` is None, the value in this attribute is irrelevant.
    """

    u_full_text = attr.ib(type=Optional[bytes], default=None)
    """uncompressed full text if available"""
    c_full_text = attr.ib(type=Optional[bytes], default=None)
    """compressed full text if available"""

    fulltext_length = attr.ib(type=Optional[int], default=None)
    """length of the full text created by this patch"""

    quality = attr.ib(type=Optional[repository.IDeltaQuality], default=None)

    @property
    def has_delta(self):
        """True if a compressed or uncompressed delta is available"""
        return self.u_delta is not None or self.c_delta is not None


class IDeltaCache(Protocol):
    """Cache delta we already computed against various base for a unique revision

    This cache is used to pick the best available delta to use the rev-diff +
    extra delta optimization."""

    @abc.abstractmethod
    def add(self, base: RevnumT, delta: bytes) -> None:
        """register a new known delta against `base`"""

    @abc.abstractmethod
    def best_for(self, target: RevnumT) -> None | tuple[int, bytes]:
        """Find (base, delta) pair to pre-seed a delta computation against `target`

        The returned delta base will use a delta chain compatible with
        `target`. If none can be found, return None.
        """


@attr.s(slots=True)
class revisioninfo:
    """Information about a revision that allows building its fulltext
    node:       expected hash of the revision
    p1, p2:     parent revs of the revision (as node)
    btext:      built text cache
    cachedelta: (baserev, uncompressed_delta, usage_mode) or None
    flags:      flags associated to the revision storage

    One of btext or cachedelta must be set.
    """

    node = attr.ib(type=NodeIdT)
    p1 = attr.ib(type=NodeIdT)
    p2 = attr.ib(type=NodeIdT)
    btext = attr.ib(type=Optional[bytes])
    textlen = attr.ib(type=int)
    cachedelta = attr.ib(type=Optional[CachedDelta])
    flags = attr.ib(type=int)
    cache = attr.ib(type=Optional[IDeltaCache], default=None)
    tracked_parent_size = attr.ib(type=bool, default=False)
    """True if the parent delta-size will be set

    The parent delta-size might still be None after this if doing a delta
    against them was hopeless.
    """

    p1_delta_u_size = attr.ib(type=Optional[int], default=None)
    """The size of the uncompreseed delta against each p2, when applicable.

    Use to determine if a delta is of "good quality" and which parent was the
    best option.
    """

    p2_delta_u_size = attr.ib(type=Optional[int], default=None)
    """The size of the uncompressed delta against each p1, when applicable.

    Use to determine if a delta is of "good quality" and which parent was the
    best option.
    """

    @property
    def has_cached_delta(self):
        """True if an compressed or uncompressed delta is available"""
        return self.cachedelta is not None and self.cachedelta.has_delta


@attr.s(slots=True)
class InboundRevision(repository.IInboundRevision):
    """Data retrieved for a changegroup like data (used in revlog.addgroup)
    node:        the revision node
    p1, p2:      the parents (as node)
    linknode:    the linkrev information
    delta_base:  the node to which apply the delta informaiton
    data:        the data from the revision
    flags:       revision flags
    sidedata:    sidedata for the revision
    proto_flags: protocol related flag affecting this revision
    """

    node = attr.ib(type=NodeIdT)
    p1 = attr.ib(type=NodeIdT)
    p2 = attr.ib(type=NodeIdT)
    link_node = attr.ib(type=NodeIdT)
    delta_base = attr.ib(type=NodeIdT)
    delta = attr.ib(type=bytes)
    flags = attr.ib(type=int)
    sidedata = attr.ib(type=Optional[dict])
    protocol_flags = attr.ib(type=int, default=0)
    snapshot_level = attr.ib(default=None, type=Optional[int])
    raw_text = attr.ib(default=None, type=Optional[bytes])
    raw_text_size = attr.ib(default=None, type=Optional[int])
    compression = attr.ib(default=None, type=Optional[i_comp.RevlogCompHeader])
    has_censor_flag = attr.ib(default=False, type=bool)
    has_filelog_hasmeta_flag = attr.ib(default=False, type=bool)
