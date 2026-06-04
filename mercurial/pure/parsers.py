# parsers.py - Python implementation of parsers.c
#
# Copyright 2009 Olivia Mackall <olivia@selenic.com> and others
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import io
import stat
import struct
import typing
import zlib

from typing import (
    Any,
    cast,
)


from ..interfaces.types import (
    RevnumT,
)
from ..node import (
    nullrev,
    sha1nodeconstants,
)
from ..thirdparty import attr

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

from .. import (
    error,
    pycompat,
    revlogutils,
    util,
)

from ..revlogutils import nodemap as nodemaputil
from ..revlogutils import constants as revlog_constants

if typing.TYPE_CHECKING:
    # TODO: Change to Buffer for 3.14+ support
    from collections.abc import ByteString

stringio = io.BytesIO


_pack = struct.pack
_unpack = struct.unpack
_compress = zlib.compress
_decompress = zlib.decompress


# a special value used internally for `size` if the file come from the other parent
FROM_P2 = -2

# a special value used internally for `size` if the file is modified/merged/added
NONNORMAL = -1

# a special value used internally for `time` if the time is ambigeous
AMBIGUOUS_TIME = -1

# Bits of the `flags` byte inside a node in the file format
DIRSTATE_V2_WDIR_TRACKED = 1 << 0
DIRSTATE_V2_P1_TRACKED = 1 << 1
DIRSTATE_V2_P2_INFO = 1 << 2
DIRSTATE_V2_MODE_EXEC_PERM = 1 << 3
DIRSTATE_V2_MODE_IS_SYMLINK = 1 << 4
DIRSTATE_V2_HAS_FALLBACK_EXEC = 1 << 5
DIRSTATE_V2_FALLBACK_EXEC = 1 << 6
DIRSTATE_V2_HAS_FALLBACK_SYMLINK = 1 << 7
DIRSTATE_V2_FALLBACK_SYMLINK = 1 << 8
DIRSTATE_V2_EXPECTED_STATE_IS_MODIFIED = 1 << 9
DIRSTATE_V2_HAS_MODE_AND_SIZE = 1 << 10
DIRSTATE_V2_HAS_MTIME = 1 << 11
DIRSTATE_V2_MTIME_SECOND_AMBIGUOUS = 1 << 12
DIRSTATE_V2_DIRECTORY = 1 << 13
DIRSTATE_V2_ALL_UNKNOWN_RECORDED = 1 << 14
DIRSTATE_V2_ALL_IGNORED_RECORDED = 1 << 15


@attr.s(slots=True, init=False)
class DirstateItem:
    """represent a dirstate entry

    It hold multiple attributes

    # about file tracking
    - wc_tracked: is the file tracked by the working copy
    - p1_tracked: is the file tracked in working copy first parent
    - p2_info: the file has been involved in some merge operation. Either
               because it was actually merged, or because the p2 version was
               ahead, or because some rename moved it there. In either case
               `hg status` will want it displayed as modified.

    # about the file state expected from p1 manifest:
    - mode: the file mode in p1
    - size: the file size in p1

    These value can be set to None, which mean we don't have a meaningful value
    to compare with. Either because we don't really care about them as there
    `status` is known without having to look at the disk or because we don't
    know these right now and a full comparison will be needed to find out if
    the file is clean.

    # about the file state on disk last time we saw it:
    - mtime: the last known clean mtime for the file.

    This value can be set to None if no cachable state exist. Either because we
    do not care (see previous section) or because we could not cache something
    yet.
    """

    _wc_tracked = attr.ib()
    _p1_tracked = attr.ib()
    _p2_info = attr.ib()
    _mode = attr.ib()
    _size = attr.ib()
    _mtime_s = attr.ib()
    _mtime_ns = attr.ib()
    _fallback_exec = attr.ib()
    _fallback_symlink = attr.ib()
    _mtime_second_ambiguous = attr.ib()

    def __init__(
        self,
        wc_tracked=False,
        p1_tracked=False,
        p2_info=False,
        has_meaningful_data=True,
        has_meaningful_mtime=True,
        parentfiledata=None,
        fallback_exec=None,
        fallback_symlink=None,
    ):
        self._wc_tracked = wc_tracked
        self._p1_tracked = p1_tracked
        self._p2_info = p2_info

        self._fallback_exec = fallback_exec
        self._fallback_symlink = fallback_symlink

        self._mode = None
        self._size = None
        self._mtime_s = None
        self._mtime_ns = None
        self._mtime_second_ambiguous = False
        if parentfiledata is None:
            has_meaningful_mtime = False
            has_meaningful_data = False
        elif parentfiledata[2] is None:
            has_meaningful_mtime = False
        if has_meaningful_data:
            self._mode = parentfiledata[0]
            self._size = parentfiledata[1]
        if has_meaningful_mtime:
            (
                self._mtime_s,
                self._mtime_ns,
                self._mtime_second_ambiguous,
            ) = parentfiledata[2]

    @classmethod
    def from_v2_data(cls, flags, size, mtime_s, mtime_ns):
        """Build a new DirstateItem object from V2 data"""
        has_mode_size = bool(flags & DIRSTATE_V2_HAS_MODE_AND_SIZE)
        has_meaningful_mtime = bool(flags & DIRSTATE_V2_HAS_MTIME)
        mode = None

        if flags & +DIRSTATE_V2_EXPECTED_STATE_IS_MODIFIED:
            # we do not have support for this flag in the code yet,
            # force a lookup for this file.
            has_mode_size = False
            has_meaningful_mtime = False

        fallback_exec = None
        if flags & DIRSTATE_V2_HAS_FALLBACK_EXEC:
            fallback_exec = flags & DIRSTATE_V2_FALLBACK_EXEC

        fallback_symlink = None
        if flags & DIRSTATE_V2_HAS_FALLBACK_SYMLINK:
            fallback_symlink = flags & DIRSTATE_V2_FALLBACK_SYMLINK

        if has_mode_size:
            assert stat.S_IXUSR == 0o100
            if flags & DIRSTATE_V2_MODE_EXEC_PERM:
                mode = 0o755
            else:
                mode = 0o644
            if flags & DIRSTATE_V2_MODE_IS_SYMLINK:
                mode |= stat.S_IFLNK
            else:
                mode |= stat.S_IFREG

        second_ambiguous = flags & DIRSTATE_V2_MTIME_SECOND_AMBIGUOUS
        return cls(
            wc_tracked=bool(flags & DIRSTATE_V2_WDIR_TRACKED),
            p1_tracked=bool(flags & DIRSTATE_V2_P1_TRACKED),
            p2_info=bool(flags & DIRSTATE_V2_P2_INFO),
            has_meaningful_data=has_mode_size,
            has_meaningful_mtime=has_meaningful_mtime,
            parentfiledata=(mode, size, (mtime_s, mtime_ns, second_ambiguous)),
            fallback_exec=fallback_exec,
            fallback_symlink=fallback_symlink,
        )

    @classmethod
    def from_v1_data(cls, state, mode, size, mtime):
        """Build a new DirstateItem object from V1 data

        Since the dirstate-v1 format is frozen, the signature of this function
        is not expected to change, unlike the __init__ one.
        """
        if state == b'm':
            return cls(wc_tracked=True, p1_tracked=True, p2_info=True)
        elif state == b'a':
            return cls(wc_tracked=True)
        elif state == b'r':
            if size == NONNORMAL:
                p1_tracked = True
                p2_info = True
            elif size == FROM_P2:
                p1_tracked = False
                p2_info = True
            else:
                p1_tracked = True
                p2_info = False
            return cls(p1_tracked=p1_tracked, p2_info=p2_info)
        elif state == b'n':
            if size == FROM_P2:
                return cls(wc_tracked=True, p2_info=True)
            elif size == NONNORMAL:
                return cls(wc_tracked=True, p1_tracked=True)
            elif mtime == AMBIGUOUS_TIME:
                return cls(
                    wc_tracked=True,
                    p1_tracked=True,
                    has_meaningful_mtime=False,
                    parentfiledata=(mode, size, (42, 0, False)),
                )
            else:
                return cls(
                    wc_tracked=True,
                    p1_tracked=True,
                    parentfiledata=(mode, size, (mtime, 0, False)),
                )
        else:
            raise RuntimeError('unknown state: %s' % pycompat.sysstr(state))

    def set_possibly_dirty(self):
        """Mark a file as "possibly dirty"

        This means the next status call will have to actually check its content
        to make sure it is correct.
        """
        self._mtime_s = None
        self._mtime_ns = None

    def set_clean(self, mode, size, mtime):
        """mark a file as "clean" cancelling potential "possibly dirty call"

        Note: this function is a descendant of `dirstate.normal` and is
        currently expected to be call on "normal" entry only. There are not
        reason for this to not change in the future as long as the ccode is
        updated to preserve the proper state of the non-normal files.
        """
        self._wc_tracked = True
        self._p1_tracked = True
        self._mode = mode
        self._size = size
        self._mtime_s, self._mtime_ns, self._mtime_second_ambiguous = mtime

    def set_tracked(self):
        """mark a file as tracked in the working copy

        This will ultimately be called by command like `hg add`.
        """
        self._wc_tracked = True
        # `set_tracked` is replacing various `normallookup` call. So we mark
        # the files as needing lookup
        #
        # Consider dropping this in the future in favor of something less broad.
        self._mtime_s = None
        self._mtime_ns = None

    def set_untracked(self):
        """mark a file as untracked in the working copy

        This will ultimately be called by command like `hg remove`.
        """
        self._wc_tracked = False
        self._mode = None
        self._size = None
        self._mtime_s = None
        self._mtime_ns = None

    def drop_merge_data(self):
        """remove all "merge-only" information from a DirstateItem

        This is to be call by the dirstatemap code when the second parent is dropped
        """
        if self._p2_info:
            self._p2_info = False
            self._mode = None
            self._size = None
            self._mtime_s = None
            self._mtime_ns = None

    @property
    def mode(self):
        return self._v1_mode()

    @property
    def size(self):
        return self._v1_size()

    @property
    def mtime(self):
        return self._v1_mtime()

    def mtime_likely_equal_to(self, other_mtime):
        self_sec = self._mtime_s
        if self_sec is None:
            return False
        self_ns = self._mtime_ns
        other_sec, other_ns, second_ambiguous = other_mtime
        if self_sec != other_sec:
            # seconds are different theses mtime are definitly not equal
            return False
        elif other_ns == 0 or self_ns == 0:
            # at least one side as no nano-seconds information

            if self._mtime_second_ambiguous:
                # We cannot trust the mtime in this case
                return False
            else:
                # the "seconds" value was reliable on its own. We are good to go.
                return True
        else:
            # We have nano second information, let us use them !
            return self_ns == other_ns

    @property
    def state(self) -> bytes:
        """
        States are:
          n  normal
          m  needs merging
          r  marked for removal
          a  marked for addition

        XXX This "state" is a bit obscure and mostly a direct expression of the
        dirstatev1 format. It would make sense to ultimately deprecate it in
        favor of the more "semantic" attributes.
        """
        if not self.any_tracked:
            return b'?'
        return self._v1_state()

    @property
    def has_fallback_exec(self):
        """True if "fallback" information are available for the "exec" bit

        Fallback information can be stored in the dirstate to keep track of
        filesystem attribute tracked by Mercurial when the underlying file
        system or operating system does not support that property, (e.g.
        Windows).

        Not all version of the dirstate on-disk storage support preserving this
        information.
        """
        return self._fallback_exec is not None

    @property
    def fallback_exec(self):
        """ "fallback" information for the executable bit

        True if the file should be considered executable when we cannot get
        this information from the files system. False if it should be
        considered non-executable.

        See has_fallback_exec for details."""
        return self._fallback_exec

    @fallback_exec.setter
    def set_fallback_exec(self, value):
        """control "fallback" executable bit

        Set to:
        - True if the file should be considered executable,
        - False if the file should be considered non-executable,
        - None if we do not have valid fallback data.

        See has_fallback_exec for details."""
        if value is None:
            self._fallback_exec = None
        else:
            self._fallback_exec = bool(value)

    @property
    def has_fallback_symlink(self):
        """True if "fallback" information are available for symlink status

        Fallback information can be stored in the dirstate to keep track of
        filesystem attribute tracked by Mercurial when the underlying file
        system or operating system does not support that property, (e.g.
        Windows).

        Not all version of the dirstate on-disk storage support preserving this
        information."""
        return self._fallback_symlink is not None

    @property
    def fallback_symlink(self):
        """ "fallback" information for symlink status

        True if the file should be considered executable when we cannot get
        this information from the files system. False if it should be
        considered non-executable.

        See has_fallback_exec for details."""
        return self._fallback_symlink

    @fallback_symlink.setter
    def set_fallback_symlink(self, value):
        """control "fallback" symlink status

        Set to:
        - True if the file should be considered a symlink,
        - False if the file should be considered not a symlink,
        - None if we do not have valid fallback data.

        See has_fallback_symlink for details."""
        if value is None:
            self._fallback_symlink = None
        else:
            self._fallback_symlink = bool(value)

    @property
    def tracked(self):
        """True is the file is tracked in the working copy"""
        return self._wc_tracked

    @property
    def any_tracked(self):
        """True is the file is tracked anywhere (wc or parents)"""
        return self._wc_tracked or self._p1_tracked or self._p2_info

    @property
    def added(self):
        """True if the file has been added"""
        return self._wc_tracked and not (self._p1_tracked or self._p2_info)

    @property
    def modified(self):
        """True if the file has been modified"""
        return self._wc_tracked and self._p1_tracked and self._p2_info

    @property
    def maybe_clean(self):
        """True if the file has a chance to be in the "clean" state"""
        if not self._wc_tracked:
            return False
        elif not self._p1_tracked:
            return False
        elif self._p2_info:
            return False
        return True

    @property
    def p1_tracked(self):
        """True if the file is tracked in the first parent manifest"""
        return self._p1_tracked

    @property
    def p2_info(self):
        """True if the file needed to merge or apply any input from p2

        See the class documentation for details.
        """
        return self._wc_tracked and self._p2_info

    @property
    def removed(self):
        """True if the file has been removed"""
        return not self._wc_tracked and (self._p1_tracked or self._p2_info)

    def v2_data(self):
        """Returns (flags, mode, size, mtime) for v2 serialization"""
        flags = 0
        if self._wc_tracked:
            flags |= DIRSTATE_V2_WDIR_TRACKED
        if self._p1_tracked:
            flags |= DIRSTATE_V2_P1_TRACKED
        if self._p2_info:
            flags |= DIRSTATE_V2_P2_INFO
        if self._mode is not None and self._size is not None:
            flags |= DIRSTATE_V2_HAS_MODE_AND_SIZE
            if self.mode & stat.S_IXUSR:
                flags |= DIRSTATE_V2_MODE_EXEC_PERM
            if stat.S_ISLNK(self.mode):
                flags |= DIRSTATE_V2_MODE_IS_SYMLINK
        if self._mtime_s is not None:
            flags |= DIRSTATE_V2_HAS_MTIME
        if self._mtime_second_ambiguous:
            flags |= DIRSTATE_V2_MTIME_SECOND_AMBIGUOUS

        if self._fallback_exec is not None:
            flags |= DIRSTATE_V2_HAS_FALLBACK_EXEC
            if self._fallback_exec:
                flags |= DIRSTATE_V2_FALLBACK_EXEC

        if self._fallback_symlink is not None:
            flags |= DIRSTATE_V2_HAS_FALLBACK_SYMLINK
            if self._fallback_symlink:
                flags |= DIRSTATE_V2_FALLBACK_SYMLINK

        # Note: we do not need to do anything regarding
        # DIRSTATE_V2_ALL_UNKNOWN_RECORDED and DIRSTATE_V2_ALL_IGNORED_RECORDED
        # since we never set _DIRSTATE_V2_HAS_DIRCTORY_MTIME
        return (flags, self._size or 0, self._mtime_s or 0, self._mtime_ns or 0)

    def _v1_state(self) -> bytes:
        """return a "state" suitable for v1 serialization"""
        if not self.any_tracked:
            # the object has no state to record, this is -currently-
            # unsupported
            raise RuntimeError('untracked item')
        elif self.removed:
            return b'r'
        elif self._p1_tracked and self._p2_info:
            return b'm'
        elif self.added:
            return b'a'
        else:
            return b'n'

    def _v1_mode(self):
        """return a "mode" suitable for v1 serialization"""
        return self._mode if self._mode is not None else 0

    def _v1_size(self):
        """return a "size" suitable for v1 serialization"""
        if not self.any_tracked:
            # the object has no state to record, this is -currently-
            # unsupported
            raise RuntimeError('untracked item')
        elif self.removed and self._p1_tracked and self._p2_info:
            return NONNORMAL
        elif self._p2_info:
            return FROM_P2
        elif self.removed:
            return 0
        elif self.added:
            return NONNORMAL
        elif self._size is None:
            return NONNORMAL
        else:
            return self._size

    def _v1_mtime(self):
        """return a "mtime" suitable for v1 serialization"""
        if not self.any_tracked:
            # the object has no state to record, this is -currently-
            # unsupported
            raise RuntimeError('untracked item')
        elif self.removed:
            return 0
        elif self._mtime_s is None:
            return AMBIGUOUS_TIME
        elif self._p2_info:
            return AMBIGUOUS_TIME
        elif not self._p1_tracked:
            return AMBIGUOUS_TIME
        elif self._mtime_second_ambiguous:
            return AMBIGUOUS_TIME
        else:
            return self._mtime_s


def gettype(q):
    return int(q & 0xFFFF)


class BaseIndex(abc.ABC):
    # Can I be passed to an algorithme implemented in Rust ?
    rust_ext_compat = 0
    # Size of a C unsigned long long int, platform independent
    big_int_size = struct.calcsize(b'>Q')
    # Size of a C long int, platform independent
    int_size = struct.calcsize(b'>i')
    # An empty index entry, used as a default value to be overridden, or nullrev
    null_item = (
        0,
        0,
        0,
        -1,
        -1,
        -1,
        -1,
        sha1nodeconstants.nullid,
        0,
        0,
        revlog_constants.COMP_MODE_INLINE,
        revlog_constants.COMP_MODE_INLINE,
        revlog_constants.RANK_UNKNOWN,
    )

    # These aren't needed for rust
    _data: ByteString
    _extra: list[bytes]
    _lgt: int

    def __init__(
        self,
        uses_generaldelta=False,
    ):
        self._uses_general_delta = uses_generaldelta
        self._bundle_repo_start_idx = None

    @util.propertycache
    def _nodemap(self):
        nodemap = nodemaputil.NodeMap({sha1nodeconstants.nullid: nullrev})
        for r in range(0, len(self)):
            n = self._entry(r)[7]
            nodemap[n] = r
        return nodemap

    def has_node(self, node):
        """return True if the node exist in the index"""
        return node in self._nodemap

    def rev(self, node):
        """return a revision for a node

        If the node is unknown, raise a RevlogError"""
        return self._nodemap[node]

    def get_rev(self, node):
        """return a revision for a node

        If the node is unknown, return None"""
        return self._nodemap.get(node)

    def parents(self, rev):
        """return (p1, p2) for a rev"""
        entry = self._entry(rev)
        return (entry[5], entry[6])

    _parents_raw = parents

    def linkrev(self, rev):
        return self._entry(rev)[4]

    def flags(self, rev):
        """the revision level flag for a revision"""
        return self._entry(rev)[0] & 0xFFFF

    def raw_delta_base(self, rev) -> RevnumT:
        """access the raw delta-base value

        Used by debug and rewrite codes"""
        return self._entry(rev)[3]

    def raw_size(self, rev) -> int | None:
        """the raw size of the revision data

        The "raw data" is stored content because flag processing and with
        optionnal metadata attached.
        """
        size = self._entry(rev)[2]
        if size < 0:
            return None
        return size

    def data_chunk_start(self, rev):
        """return the starting offsset of the data chunk of a rev"""
        return int(self._entry(rev)[0] >> 16)

    def data_chunk_length(self, rev):
        """return the length of the data chunk of a rev"""
        return self._entry(rev)[1]

    def data_chunk_uncompressed_length(self, rev):
        """return the length of the uncompressed data chunk of a rev"""
        return self._entry(rev)[
            revlog_constants.INDEX_ENTRY_V2_IDX_UNCOMPRESSED_LENGTH
        ]

    def data_chunk_compression_mode(self, rev):
        """the type of compression used a revision data chunk"""
        return self._entry(rev)[10]

    def delta_base(self, rev) -> RevnumT | None:
        """The revision to which apply the delta stored for <rev>

        When <rev> is stored as a delta, the delta-base is the revision that
        stored delta applies to in order to retrieve the full content of <rev>.

        If <rev> is stored as a full snapshot, `None` is returned instead.
        """
        base = self._entry(rev)[3]
        if base == rev:
            return None
        elif self._uses_general_delta:
            return base
        elif (idx := self._bundle_repo_start_idx) is not None and idx <= rev:
            return base
        else:
            return rev - 1

    def deltachain(self, rev, stoprev=None) -> tuple[list[RevnumT], bool]:
        # Alias to prevent attribute lookup in tight loop.
        generaldelta = self._uses_general_delta

        chain = []
        iterrev = rev
        e = self._entry(iterrev)
        while iterrev != e[3] and iterrev != stoprev:
            if e[1] > 0:
                # skip over empty delta in the chain
                chain.append(iterrev)
            if generaldelta:
                iterrev = e[3]
            else:
                iterrev -= 1
            e = self._entry(iterrev)

        if iterrev == stoprev:
            stopped = True
        else:
            chain.append(iterrev)
            stopped = False

        chain.reverse()
        return chain, stopped

    def sidedata_chunk_offset(self, rev):
        """the offset of the sidedata chunk if any"""
        return self._entry(rev)[8]

    def sidedata_chunk_length(self, rev):
        """the offset of the sidedata chunk if any"""
        return self._entry(rev)[9]

    def sidedata_chunk_compression_mode(self, rev):
        """the offset of the sidedata chunk if any"""
        return self._entry(rev)[11]

    def changed_files_offset(self, rev: RevnumT) -> int:
        """The byte offset of the serialized ChangedFiles data

        Only relevant for index that actually store ChangedFiles data.
        """
        return 0

    def changed_files_length(self, rev: RevnumT) -> int:
        """The number of bytes of the serialized ChangedFiles data

        Only relevant for index that actually store ChangedFiles data.
        """
        return 0

    def update_changed_files(
        self,
        rev: RevnumT,
        has_copies_info: bool,
        offset: int,
        length: int,
    ):
        """Update entery value related to "changed-filed" information

        Only relevant for index having the feature
        """
        raise error.ProgrammingError("lacking support for ChangedFiles data")

    def children(self, rev: RevnumT) -> None | list[RevnumT]:
        c1 = self.child_p1(rev)
        if c1 is None:
            return None
        c2 = self.child_p2(rev)
        if c2 is None:
            return None
        children_p1 = set()
        while c1 != nullrev:
            children_p1.add(c1)
            next = self.sibling_p1(c1)
            assert next not in children_p1
            assert next is not None
            c1 = next
        children_p2 = set()
        while c2 != nullrev:
            children_p2.add(c2)
            next = self.sibling_p2(c2)
            assert next not in children_p2
            assert next is not None
            c2 = next
        return list(sorted(children_p1 | children_p2))

    def child_p1(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using `rev` as p1.

        The returned revision should be the origin of the linked list created
        by `sibling_p1`.

        return nullrev is no such revision exists

        return None if the feature is unsupported
        """
        return None

    def child_p2(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using `rev` as p2.

        The returned revision should be the origin of the linked list created
        by `sibling_p2`.

        return nullrev is no such revision exists

        return None if the feature is unsupported
        """
        return None

    def sibling_p1(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using the same `p1` as `rev`

        Following all sibling_p1 value from the first on (pointed by p1's
        child_p1) will yield all p1-children of `p1` until `nullrev` is reach

        return nullrev is this revision is the last in the chain.

        return None if the feature is unsupported
        """
        return None

    def sibling_p2(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using the same `p2` as `rev`

        Following all sibling_p2 value from the first on (pointed by p2's
        child_p2) will yield all p2-children of `p2` until `nullrev` is reach

        return nullrev is this revision is the last in the chain.

        return None if the feature is unsupported
        """
        return None

    def lazy_rank(self, rev):
        """return the rank of <rev> if known

        return `revlog_constants.RANK_UNKNOWN` otherwise.
        """
        return self._entry(rev)[12]

    def rank(self, rev):
        """return the rank of <rev>

        raise a ProgrammingError if the rank is unknown.
        """
        rank = self._entry(rev)[12]
        if rank == revlog_constants.RANK_UNKNOWN:
            msg = b"should not call `rank(rev)` if rank might be unknown"
            raise error.ProgrammingError(msg)
        return rank

    def node(self, rev: int) -> bytes:
        """return the node of a revision"""
        return self._entry(rev)[7]

    def _stripnodes(self, start):
        if '_nodemap' in vars(self):
            for r in range(start, len(self)):
                n = self._entry(r)[7]
                del self._nodemap[n]

    def clearcaches(self):
        self.__dict__.pop('_nodemap', None)

    def __len__(self) -> int:
        return self._lgt + len(self._extra)

    def start_bundle_repo(self):
        """Signal the start of adding revision from a bundle

        We need to be aware of when such operation happens because their delta
        base might be different."""
        self._bundle_repo_start_idx = len(self)

    @abc.abstractmethod
    def add_entry(self, entry: revlogutils.RevlogEntry) -> None:
        ...

    def _check_index(self, i: RevnumT):
        if not isinstance(i, int):
            raise TypeError("expecting int indexes")
        if i < 0 or i >= len(self):
            raise IndexError(i)

    def _calculate_index(self, i: int) -> int:
        # This isn't @abstractmethod because it is only used in __getitem__().
        # The revlog.RustIndexProxy implementation provides its own, so there's
        # no reason to force it to implement an unused method.
        raise NotImplementedError

    @abc.abstractmethod
    def _entry(self, i: RevnumT) -> revlogutils.EntryTupleT:
        """return the stored values for a revision"""
        ...

    def __delitem__(self, i):
        raise NotImplementedError()

    def pack_header(self, header):
        """pack header information as binary"""
        v_fmt = revlog_constants.INDEX_HEADER
        return v_fmt.pack(header)

    def headrevs(self, excluded_revs=None, stop_rev=None) -> list[int]:
        count = len(self)
        if stop_rev is not None:
            count = min(count, stop_rev)
        if not count:
            return [nullrev]
        # we won't iter over filtered rev so nobody is a head at start
        ishead = [0] * (count + 1)
        revs = range(count)
        if excluded_revs is not None:
            revs = (r for r in revs if r not in excluded_revs)

        for r in revs:
            ishead[r] = 1  # I may be an head
            e = self._entry(r)
            ishead[e[5]] = ishead[e[6]] = 0  # my parent are not
        return [r for r, val in enumerate(ishead) if val]


class MonoBlockIndex(BaseIndex):
    # Format of an index entry according to Python's `struct` language
    index_format: struct.Struct = revlog_constants.INDEX_ENTRY_V1

    @util.propertycache
    def entry_size(self):
        return self.index_format.size

    def entry_binary(self, rev) -> bytes:
        """return the raw binary string representing a revision"""
        entry = self._entry(rev)
        p = revlog_constants.INDEX_ENTRY_V1.pack(*entry[:8])
        if rev == 0:
            p = p[revlog_constants.INDEX_HEADER.size :]
        return p

    def add_entry(self, entry: revlogutils.RevlogEntry) -> None:
        self._append(entry.as_tuple())

    def _append(self, tup: revlogutils.EntryTupleT) -> None:
        if '_nodemap' in vars(self):
            self._nodemap[tup[7]] = len(self)
        data = self._pack_entry(len(self), tup)
        self._extra.append(data)

    def _entry(self, i: RevnumT) -> revlogutils.EntryTupleT:
        if i == -1:
            return self.null_item
        self._check_index(i)
        if i >= self._lgt:
            data = self._extra[i - self._lgt]
        else:
            index = self._calculate_index(i)
            data = self._data[index : index + self.entry_size]
        r = self._unpack_entry(i, data)
        if self._lgt and i == 0:
            offset = revlogutils.offset_type(0, gettype(r[0]))
            r = cast(revlogutils.EntryTupleT, (offset,) + r[1:])
        return r

    def _pack_entry(self, rev: RevnumT, entry: revlogutils.EntryTupleT):
        assert entry[8] == 0
        assert entry[9] == 0
        return self.index_format.pack(*entry[:8])

    def _unpack_entry(
        self, rev: RevnumT, data: bytes
    ) -> revlogutils.EntryTupleT:
        r = self.index_format.unpack(data)
        r = r + (
            0,
            0,
            revlog_constants.COMP_MODE_INLINE,
            revlog_constants.COMP_MODE_INLINE,
            revlog_constants.RANK_UNKNOWN,
        )
        return cast(revlogutils.EntryTupleT, r)

    def __delitem__(self, i):
        if not isinstance(i, slice) or not i.stop == -1 or i.step is not None:
            raise ValueError("deleting slices only supports a:-1 with step 1")
        i = i.start
        self._check_index(i)
        self._stripnodes(i)
        if i < self._lgt:
            self._del_stored(i)
            self._lgt = i
            self._extra = []
        else:
            self._extra = self._extra[: i - self._lgt]

    # not an abstractmethod because it would confuse RustIndexProxy
    def _del_stored(self, rev: RevnumT) -> None:
        """delete reference to a stored entry"""


class Index(MonoBlockIndex):
    def __init__(
        self, data: ByteString, uses_generaldelta=False, uses_delta_info=False
    ):
        assert len(data) % self.entry_size == 0, (
            len(data),
            self.entry_size,
            len(data) % self.entry_size,
        )
        self._data = data
        self._lgt = len(data) // self.entry_size
        self._extra = []
        super().__init__(uses_generaldelta=uses_generaldelta)

    def _calculate_index(self, i: int) -> int:
        return i * self.entry_size

    def _del_stored(self, rev: RevnumT) -> None:
        """delete reference to a stored entry"""
        self._data = self._data[: rev * self.entry_size]


class PersistentNodeMapIndex(Index):
    """a Debug oriented class to test persistent nodemap

    We need a simple python object to test API and higher level behavior. See
    the Rust implementation for  more serious usage. This should be used only
    through the dedicated `devel.persistent-nodemap` config.
    """

    # TODO: add type info
    _nm_docket: Any  # TODO: could be None, but need to handle .tip_rev below
    _nm_max_idx: int | None
    _nm_root: nodemaputil.Block | None

    def nodemap_data_all(self):
        """Return bytes containing a full serialization of a nodemap

        The nodemap should be valid for the full set of revisions in the
        index."""
        return nodemaputil.persistent_data(self)

    def nodemap_data_incremental(self):
        """Return bytes containing a incremental update to persistent nodemap

        This containst the data for an append-only update of the data provided
        in the last call to `update_nodemap_data`.
        """
        if self._nm_root is None:
            return None
        docket = self._nm_docket
        changed, data = nodemaputil.update_persistent_data(
            self, self._nm_root, self._nm_max_idx, self._nm_docket.tip_rev
        )

        self._nm_root = self._nm_max_idx = self._nm_docket = None
        return docket, changed, data

    def update_nodemap_data(self, docket, nm_data):
        """provide full block of persisted binary data for a nodemap

        The data are expected to come from disk. See `nodemap_data_all` for a
        produceur of such data."""
        if nm_data is not None:
            self._nm_root, self._nm_max_idx = nodemaputil.parse_data(nm_data)
            if self._nm_root:
                self._nm_docket = docket
            else:
                self._nm_root = self._nm_max_idx = self._nm_docket = None


class InlinedIndex(MonoBlockIndex):
    def __init__(self, data, uses_generaldelta=False, uses_delta_info=False):
        self._data = data
        self._lgt = self._inline_scan(None)
        self._inline_scan(self._lgt)
        self._extra = []
        super().__init__(uses_generaldelta=uses_generaldelta)

    def _inline_scan(self, lgt):
        off = 0
        if lgt is not None:
            self._offsets = [0] * lgt
        count = 0
        while off <= len(self._data) - self.entry_size:
            start = off + self.big_int_size
            (s,) = struct.unpack(
                b'>i',
                self._data[start : start + self.int_size],
            )
            if lgt is not None:
                self._offsets[count] = off
            count += 1
            off += self.entry_size + s
        if off != len(self._data):
            raise ValueError("corrupted data")
        return count

    def _calculate_index(self, i: int) -> int:
        return self._offsets[i]

    def _del_stored(self, rev: RevnumT) -> None:
        """delete reference to stored entry from ``rev``"""
        self._offsets = self._offsets[:rev]


def parse_index2(
    data: ByteString,
    inlined,
    uses_generaldelta,
    uses_delta_info,
    format=revlog_constants.REVLOGV1,
) -> tuple[Index | InlinedIndex, tuple[int, ByteString] | None]:
    if not inlined:
        return Index(data, uses_generaldelta, uses_delta_info), None
    else:
        index = InlinedIndex(data, uses_generaldelta, uses_delta_info)
        return index, (0, data)


def parse_index_v2(data: tuple[ByteString, ...]) -> Index2:
    return Index2(data)


def parse_index_cl_v2(data: tuple[ByteString, ...]) -> IndexChangelogV2:
    return IndexChangelogV2(data)


class MultiBlockIndex(BaseIndex):
    _index_formats: tuple[struct.Struct, ...]

    def __init__(
        self,
        data: tuple[ByteString, ...],
        uses_generaldelta,
    ):
        assert len(data) == len(self._index_formats)
        count = []
        for idx, f in enumerate(self._index_formats):
            entry_size = f.size
            len_data = len(data[idx])
            assert (len_data % entry_size) == 0
            count.append(len_data // entry_size)
        assert len(set(count)) == 1, count

        data = tuple(bytearray(d) for d in data)

        self._data = data
        self._lgt = count[0]
        self._extra: list[tuple[bytes, ...]] = []
        super().__init__(uses_generaldelta=uses_generaldelta)

    def __delitem__(self, i):
        i = i.start
        self._check_index(i)
        self._stripnodes(i)
        if i < self._lgt:
            self._data = tuple(
                block[: i * entry_size]
                for entry_size, block in zip(self.entry_sizes, self._data)
            )
            self._lgt = i
            self._extra = []
        else:
            self._extra = self._extra[: i - self._lgt]

    def pack_header(self, header):
        """pack header information as binary"""
        msg = 'version header should go in the docket, not the index: %d'
        msg %= header
        raise error.ProgrammingError(msg)

    def add_entry(self, entry: revlogutils.RevlogEntry) -> None:
        if '_nodemap' in vars(self):
            self._nodemap[entry.node_id] = len(self)
        data = self._pack_entry(len(self), entry)
        self._extra.append(data)

    @util.propertycache
    def entry_sizes(self):
        return tuple(f.size for f in self._index_formats)

    def entry_binaries(self, rev: RevnumT) -> tuple[bytes, ...]:
        """return the raw binary strings representing a revision

        Each index pieces will have its own bytes
        """
        self._check_index(rev)
        if rev >= self._lgt:
            return self._extra[rev - self._lgt]
        else:
            return tuple(
                data[rev * size : (rev + 1) * size]
                for data, size in zip(self._data, self.entry_sizes)
            )

    def _entry(self, rev: RevnumT) -> revlogutils.EntryTupleT:
        if rev == -1:
            return self.null_item
        return self._rich_entry(rev).as_tuple()

    def _rich_entry(self, rev: RevnumT) -> revlogutils.RevlogEntry:
        self._check_index(rev)
        data = self.entry_binaries(rev)
        return self._unpack_entry(rev, data)

    @classmethod
    @abc.abstractmethod
    def _pack_entry(
        cls,
        rev: RevnumT,
        entry: revlogutils.RevlogEntry,
    ) -> tuple[bytes, ...]:
        ...

    @classmethod
    @abc.abstractmethod
    def _unpack_entry(
        cls,
        rev: RevnumT,
        data: tuple[bytes, ...],
    ) -> revlogutils.RevlogEntry:
        ...

    def update_child_p1(self, rev: RevnumT, child: RevnumT):
        """update the "child_p1" field of a revision

        return updated binary blob for that revision
        """
        raise NotImplementedError

    def update_child_p2(self, rev: RevnumT, child: RevnumT):
        """update the "child_p2" field of a revision

        return updated binary blob for that revision
        """
        raise NotImplementedError

    def update_sibling_p1(self, rev: RevnumT, sibling: RevnumT):
        """update the "sibling_p1" field of a revision

        return updated binary blob for that revision
        """
        raise NotImplementedError

    def update_sibling_p2(self, rev: RevnumT, sibling: RevnumT):
        """update the "sibling_p2" field of a revision

        return updated binary blob for that revision
        """
        raise NotImplementedError

    def _update(
        self,
        rev: RevnumT,
        entry: revlogutils.RevlogEntry,
        block_mask: tuple[bool, ...] | None = None,
    ) -> tuple[bytes | None, ...]:
        """update the currently stored for `rev` with the one from `entry`

        If `block_mask` is provided, the update only affect some of the index
        block. The `block_mask` should be as long as the bumber of block used
        in this MultiBlockIndex. The index set to `True` are impacted the one
        set to `False are unchanged`.

        This method result the updated binary blobs for that revision as a
        tuple. It is the responsability of the caller (typically inner-revlog
        code) to update the on-disk storage. Untouched binary blobs will be set
        to `None`.
        """
        all_bins = self._pack_entry(rev, entry)
        if block_mask is None:
            updated_bins = all_bins
        else:
            # zip(…, strict=True) was added in Python 3.10
            nb_bins = len(all_bins)
            nb_masks = len(block_mask)
            assert nb_bins == nb_masks, (nb_bins, nb_masks)
            updated_bins = tuple(
                bin if mask else None
                for (bin, mask) in zip(all_bins, block_mask)
            )
        if rev >= self._lgt:
            self._extra[rev - self._lgt] = all_bins
        else:
            for bin, data in zip(updated_bins, self._data):
                if bin is None:
                    continue
                else:
                    size = len(bin)
                    offset = rev * size
                    data[offset : offset + size] = bin
        return updated_bins

    def update_data(
        self,
        rev: RevnumT,
        offset: int,
        chunk_size: int,
        uncompressed_chunk_size: int,
        compression: revlogutils.CompModeT,
        censored: bool,
        delta_base: RevnumT | None,
    ) -> tuple[bytes | None, ...]:
        """update field related to the revision data

        Used when censoring revision.

        The API might evolve in the future. For example, to "track delta
        quality" information.  Or if we starts using it to "re-encode" delta
        tree in the future.
        """
        entry = self._rich_entry(rev)
        entry.data_offset = offset
        entry.data_compressed_length = chunk_size
        entry.data_uncompressed_length = uncompressed_chunk_size
        entry.data_compression_mode = compression
        flags = entry.flags
        if censored:
            flags |= revlog_constants.REVIDX_ISCENSORED
            # the censored revison are expected to be full snapshot
            #
            # NOTE: this may change in the future
            assert delta_base is None

        if delta_base is None:
            entry.data_delta_base = rev
        else:
            entry.data_delta_base = delta_base

        # for now we don't expect this to be used on a revlog with delta
        # quality information, this might change in the future.
        assert not flags & revlog_constants.REVIDX_DELTA_IS_SNAPSHOT
        assert not flags & revlog_constants.FLAG_FILELOG_META
        assert not flags & revlog_constants.REVIDX_DELTA_QUALITY
        assert not flags & revlog_constants.REVIDX_DELTA_GOOD
        assert not flags & revlog_constants.REVIDX_DELTA_P1_SMALL
        assert not flags & revlog_constants.REVIDX_DELTA_P2_SMALL
        entry.flags = flags
        return self._update(rev, entry, (True, True))


class Index2(MultiBlockIndex):
    _index_formats = revlog_constants.INDEX_ENTRY_V2

    def __init__(
        self,
        data: tuple[ByteString, ...],
        uses_generaldelta: bool = True,
    ):
        # turn the data into something mutable, this is needlessly expensive
        # and memory hungry, but keep things simple for the reference Python
        # implementation
        super().__init__(data, uses_generaldelta=uses_generaldelta)

    def replace_sidedata_info(
        self,
        rev,
        sidedata_offset,
        sidedata_length,
        added_flags,
        dropped_flags,
        compression_mode,
    ):
        """
        Replace an existing index entry's sidedata offset and length with new
        ones.
        This cannot be used outside of the context of sidedata rewriting,
        inside the transaction that creates the revision `rev`.
        """
        if rev < 0:
            raise KeyError
        self._check_index(rev)
        if rev < self._lgt:
            msg = "cannot rewrite entries outside of this transaction"
            raise KeyError(msg)
        else:
            assert not (added_flags & dropped_flags)
            entry = self._rich_entry(rev)
            entry.flags = entry.flags | added_flags & ~dropped_flags
            entry.sidedata_offset = sidedata_offset
            entry.sidedata_compressed_length = sidedata_length
            entry.sidedata_compression_mode = compression_mode
            return self._update(rev, entry)

    @classmethod
    def _unpack_entry(
        cls,
        rev: RevnumT,
        data: tuple[bytes, ...],
    ) -> revlogutils.RevlogEntry:
        pieces = tuple(f.unpack(d) for f, d in zip(cls._index_formats, data))
        data_comp = pieces[1][2] & 3
        sidedata_comp = (pieces[1][2] & (3 << 2)) >> 2

        return revlogutils.RevlogEntry(
            flags=pieces[0][0] & 0xFFFF,
            data_offset=pieces[0][0] >> 16,
            data_compressed_length=pieces[0][1],
            data_uncompressed_length=pieces[0][2],
            data_delta_base=pieces[0][3],
            link_rev=pieces[0][4],
            parent_rev_1=pieces[0][5],
            parent_rev_2=pieces[0][6],
            node_id=pieces[0][7],
            sidedata_offset=pieces[1][0],
            sidedata_compressed_length=pieces[1][1],
            data_compression_mode=data_comp,
            sidedata_compression_mode=sidedata_comp,
        )

    @classmethod
    def _pack_entry(
        cls,
        rev: RevnumT,
        entry: revlogutils.RevlogEntry,
    ) -> tuple[bytes, ...]:
        pieces = (
            (
                revlogutils.offset_type(entry.data_offset, entry.flags),
                entry.data_compressed_length,
                entry.data_uncompressed_length,
                entry.data_delta_base,
                entry.link_rev,
                entry.parent_rev_1,
                entry.parent_rev_2,
                entry.node_id,
            ),
            (
                entry.sidedata_offset,
                entry.sidedata_compressed_length,
                (entry.data_compression_mode & 3)
                | ((entry.sidedata_compression_mode & 3) << 2),
            ),
        )
        return tuple(f.pack(*d) for f, d in zip(cls._index_formats, pieces))


class IndexChangelogV2(Index2):
    _index_formats = revlog_constants.INDEX_ENTRY_CL_V2

    null_item = (
        Index2.null_item[: revlog_constants.ENTRY_RANK]
        + (0,)  # rank of null is 0
        + Index2.null_item[revlog_constants.ENTRY_RANK :]
    )

    def __init__(
        self,
        data: tuple[ByteString, ...],
    ):
        super().__init__(data, uses_generaldelta=False)

    def changed_files_offset(self, rev: RevnumT) -> int:
        """The byte offset of the serialized ChangedFiles data"""
        if rev == nullrev:
            return 0
        return self._rich_entry(rev).changed_files_offset

    def changed_files_length(self, rev: RevnumT) -> int:
        """The number of bytes of the serialized ChangedFiles data"""
        if rev == nullrev:
            return 0
        return self._rich_entry(rev).changed_files_length

    @classmethod
    def _unpack_entry(
        cls,
        rev: RevnumT,
        data: tuple[bytes, ...],
    ) -> revlogutils.RevlogEntry:
        items = sum(
            (f.unpack(d) for f, d in zip(cls._index_formats, data)),
            start=(),
        )
        return revlogutils.RevlogEntry(
            flags=items[revlog_constants.INDEX_ENTRY_V2_IDX_OFFSET] & 0xFFFF,
            data_offset=items[revlog_constants.INDEX_ENTRY_V2_IDX_OFFSET] >> 16,
            data_compressed_length=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_COMPRESSED_LENGTH
            ],
            data_uncompressed_length=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_UNCOMPRESSED_LENGTH
            ],
            data_delta_base=rev,
            link_rev=rev,
            parent_rev_1=items[revlog_constants.INDEX_ENTRY_V2_IDX_PARENT_1],
            parent_rev_2=items[revlog_constants.INDEX_ENTRY_V2_IDX_PARENT_2],
            node_id=items[revlog_constants.INDEX_ENTRY_V2_IDX_NODEID],
            child_p1=items[revlog_constants.INDEX_ENTRY_V2_IDX_CHILD_P1],
            child_p2=items[revlog_constants.INDEX_ENTRY_V2_IDX_CHILD_P2],
            sibling_p1=items[revlog_constants.INDEX_ENTRY_V2_IDX_SIBLING_P1],
            sibling_p2=items[revlog_constants.INDEX_ENTRY_V2_IDX_SIBLING_P2],
            sidedata_offset=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_SIDEDATA_OFFSET
            ],
            sidedata_compressed_length=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_SIDEDATA_COMPRESSED_LENGTH
            ],
            data_compression_mode=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_COMPRESSION_MODE
            ]
            & 3,
            sidedata_compression_mode=(
                items[revlog_constants.INDEX_ENTRY_V2_IDX_COMPRESSION_MODE] >> 2
            )
            & 3,
            rank=items[revlog_constants.INDEX_ENTRY_V2_IDX_RANK],
            changed_files_offset=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_CGF_OFFSET
            ],
            changed_files_length=items[
                revlog_constants.INDEX_ENTRY_V2_IDX_CGF_LENGTH
            ],
        )

    @classmethod
    def _pack_entry(
        cls,
        rev: RevnumT,
        entry: revlogutils.RevlogEntry,
    ) -> tuple[bytes, ...]:
        base = entry.data_delta_base
        link_rev = entry.link_rev
        assert base == rev, (base, rev)
        assert link_rev == rev, (link_rev, rev)
        pieces = (
            (
                revlogutils.offset_type(entry.data_offset, entry.flags),
                entry.data_compressed_length,
                entry.data_uncompressed_length,
                entry.parent_rev_1,
                entry.parent_rev_2,
                entry.node_id,
                entry.child_p1,
                entry.child_p2,
                entry.sibling_p1,
                entry.sibling_p2,
                (entry.data_compression_mode & 3)
                | ((entry.sidedata_compression_mode & 3) << 2),
            ),
            (
                entry.sidedata_offset,
                entry.sidedata_compressed_length,
                entry.rank,
                entry.changed_files_offset,
                entry.changed_files_length,
            ),
        )
        return tuple(f.pack(*d) for f, d in zip(cls._index_formats, pieces))

    def update_changed_files(
        self,
        rev: RevnumT,
        has_copies_info: bool,
        offset: int,
        length: int,
    ) -> tuple[bytes | None, ...]:
        """Update entery value related to "changed-filed" information

        This only update the in-memory state of the object, updating the
        on-disk states is the caller responsability.

        This assume the "changed-files" information were previously
        missing for the `rev` revision.

        This also assume the revision that is being updated is part of a
        pending transaction and wasn't fully committed to disk yet. As a
        result, the revision entry is not part of the "from disk" data of this
        index.
        """
        assert rev >= self._lgt, (rev, self._lgt)
        e = self._rich_entry(rev)
        if has_copies_info:
            e.flags |= revlog_constants.REVIDX_HASCOPIESINFO
        assert e.changed_files_length == 0
        assert length != 1, (rev, offset)
        e.changed_files_offset = offset
        e.changed_files_length = length
        # first piece hold the flag that might change
        # second piece hold the offset and size
        mask = (has_copies_info, True)
        return self._update(rev, e, mask)

    def child_p1(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using `rev` as p1.

        The returned revision should be the origin of the linked list created
        by `sibling_p1`.

        return nullrev is no such revision exists

        return None if the feature is unsupported
        """
        if rev == nullrev:
            if len(self) == 0:
                return nullrev
            else:
                return 0
        child = self._rich_entry(rev).child_p1
        if child <= rev or child >= len(self) or self.parents(child)[0] != rev:
            # point to stripped revision, ignores them for now
            return nullrev
        return child

    def child_p2(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using `rev` as p2.

        The returned revision should be the origin of the linked list created
        by `sibling_p2`.

        return nullrev is no such revision exists

        return None if the feature is unsupported
        """
        if rev == nullrev:
            return nullrev
        child = self._rich_entry(rev).child_p2
        if child <= rev or child >= len(self) or self.parents(child)[1] != rev:
            # point to stripped revision, ignores them for now
            return nullrev
        return child

    def sibling_p1(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using the same `p1` as `rev`

        Following all sibling_p1 value from the first on (pointed by p1's
        child_p1) will yield all p1-children of `p1` until `nullrev` is reach

        return nullrev is this revision is the last in the chain.

        return None if the feature is unsupported
        """
        if rev == nullrev:
            return nullrev
        sibling = self._rich_entry(rev).sibling_p1
        if (
            sibling <= rev
            or sibling >= len(self)
            or self.parents(sibling)[0] != self.parents(rev)[0]
        ):
            # point to stripped revision, ignores them for now
            return nullrev
        return sibling

    def sibling_p2(self, rev: RevnumT) -> RevnumT | None:
        """return the revision using the same `p2` as `rev`

        Following all sibling_p2 value from the first on (pointed by p2's
        child_p2) will yield all p2-children of `p2` until `nullrev` is reach

        return nullrev is this revision is the last in the chain.

        return None if the feature is unsupported
        """
        if rev == nullrev:
            return nullrev
        sibling = self._rich_entry(rev).sibling_p2
        if (
            sibling <= rev
            or sibling >= len(self)
            or self.parents(sibling)[1] != self.parents(rev)[1]
        ):
            # point to stripped revision, ignores them for now
            return nullrev
        return sibling

    def _update_children_attr(self, rev: RevnumT, attr: str, value: RevnumT):
        e = self._rich_entry(rev)
        setattr(e, attr, value)
        return self._update(rev, e, (True, False))

    def update_child_p1(self, rev: RevnumT, child: RevnumT):
        """update the "child_p1" field of a revision

        return updated binary blob for that revision
        """
        return self._update_children_attr(rev, "child_p1", child)

    def update_child_p2(self, rev: RevnumT, child: RevnumT):
        """update the "child_p2" field of a revision

        return updated binary blob for that revision
        """
        return self._update_children_attr(rev, "child_p2", child)

    def update_sibling_p1(self, rev: RevnumT, sibling: RevnumT):
        """update the "sibling_p1" field of a revision

        return updated binary blob for that revision
        """
        return self._update_children_attr(rev, "sibling_p1", sibling)

    def update_sibling_p2(self, rev: RevnumT, sibling: RevnumT):
        """update the "sibling_p2" field of a revision

        return updated binary blob for that revision
        """
        return self._update_children_attr(rev, "sibling_p2", sibling)


def parse_index_devel_nodemap(data, inline, uses_generaldelta, uses_delta_info):
    """like parse_index2, but always return a PersistentNodeMapIndex"""
    return (
        PersistentNodeMapIndex(data, uses_generaldelta, uses_delta_info),
        None,
    )


def parse_dirstate(dmap, copymap, st):
    parents = [st[:20], st[20:40]]
    # dereference fields so they will be local in loop
    format = b">cllll"
    e_size = struct.calcsize(format)
    pos1 = 40
    l = len(st)

    # the inner loop
    while pos1 < l:
        pos2 = pos1 + e_size
        e = _unpack(b">cllll", st[pos1:pos2])  # a literal here is faster
        pos1 = pos2 + e[4]
        f = st[pos2:pos1]
        if b'\0' in f:
            f, c = f.split(b'\0')
            copymap[f] = c
        dmap[f] = DirstateItem.from_v1_data(*e[:4])
    return parents


def pack_dirstate(dmap, copymap, pl):
    cs = stringio()
    write = cs.write
    write(b"".join(pl))
    for f, e in dmap.items():
        if f in copymap:
            f = b"%s\0%s" % (f, copymap[f])
        e = _pack(
            b">cllll",
            e._v1_state(),
            e._v1_mode(),
            e._v1_size(),
            e._v1_mtime(),
            len(f),
        )
        write(e)
        write(f)
    return cs.getvalue()
