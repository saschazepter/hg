# revlog.py - storage back-end for mercurial
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

"""Storage back-end for Mercurial.

This provides efficient delta storage with O(1) retrieve and append
and O(changes) merge between branches.
"""

from __future__ import annotations

import binascii
import collections
import contextlib
import io
import os
import struct
import typing
import weakref
import zlib

from typing import (
    Iterable,
    Iterator,
    Optional,
)

# import stuff from node for others to import from revlog
from .node import (
    bin,
    hex,
    nullrev,
    sha1nodeconstants,
    short,
    wdirrev,
)
from .i18n import _
from .revlogutils.constants import (
    ALL_KINDS,
    CHANGELOGV2,
    COMP_MODE_DEFAULT,
    COMP_MODE_INLINE,
    COMP_MODE_PLAIN,
    DELTA_BASE_REUSE_NO,
    DELTA_BASE_REUSE_TRY,
    ENTRY_RANK,
    FEATURES_BY_VERSION,
    FILELOG_HASMETA_DOWNGRADE as HM_DOWN,
    FILELOG_HASMETA_UPGRADE as HM_UP,
    FLAG_DELTA_INFO,
    FLAG_FILELOG_META,
    FLAG_GENERALDELTA,
    FLAG_INLINE_DATA,
    INDEX_HEADER,
    KIND_CHANGELOG,
    KIND_FILELOG,
    META_MARKER,
    META_MARKER_SIZE,
    RANK_UNKNOWN,
    REVLOGV0,
    REVLOGV1,
    REVLOGV1_FLAGS,
    REVLOGV2,
    REVLOGV2_FLAGS,
    REVLOG_DEFAULT_FLAGS,
    REVLOG_DEFAULT_FORMAT,
    REVLOG_DEFAULT_VERSION,
    SUPPORTED_FLAGS,
)
from .revlogutils.flagutil import (
    REVIDX_DEFAULT_FLAGS,
    REVIDX_DELTA_IS_SNAPSHOT,
    REVIDX_ELLIPSIS,
    REVIDX_EXTSTORED,
    REVIDX_FLAGS_ORDER,
    REVIDX_HASCOPIESINFO,
    REVIDX_HASMETA,
    REVIDX_ISCENSORED,
    REVIDX_RAWTEXT_CHANGING_FLAGS,
)
from .thirdparty import attr
from .revlogutils import config as revlog_config

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr
    from .pure.parsers import BaseIndexObject

    from .interfaces.types import (
        NodeIdT,
    )

from . import (
    ancestor,
    dagop,
    error,
    mdiff,
    policy,
    pycompat,
    revlogutils,
    templatefilters,
    util,
    vfs as vfsmod,
)
from .interfaces import (
    repository,
)

from .revlogutils import (
    deltas as deltautil,
    docket as docketutil,
    flagutil,
    nodemap as nodemaputil,
    randomaccessfile,
    revlogv0,
    rewrite,
    sidedata as sidedatautil,
)
from .utils import (
    storageutil,
    stringutil,
)

# blanked usage of all the name to prevent pyflakes constraints
# We need these name available in the module for extensions.

REVLOGV0
REVLOGV1
REVLOGV2
CHANGELOGV2
FLAG_INLINE_DATA
FLAG_GENERALDELTA
REVLOG_DEFAULT_FLAGS
REVLOG_DEFAULT_FORMAT
REVLOG_DEFAULT_VERSION
REVLOGV1_FLAGS
REVLOGV2_FLAGS
REVIDX_ISCENSORED
REVIDX_ELLIPSIS
REVIDX_HASCOPIESINFO
REVIDX_EXTSTORED
REVIDX_DEFAULT_FLAGS
REVIDX_FLAGS_ORDER
REVIDX_RAWTEXT_CHANGING_FLAGS

parsers = policy.importmod('parsers')
rustancestor = policy.importrust('ancestor')
rustdagop = policy.importrust('dagop')
rustrevlog = policy.importrust('revlog')

# Aliased for performance.
_zlibdecompress = zlib.decompress

# max size of inline data embedded into a revlog
_maxinline = 131072


# Flag processors for REVIDX_ELLIPSIS.
def ellipsisreadprocessor(rl, text):
    return text, False


def ellipsiswriteprocessor(rl, text):
    return text, False


def ellipsisrawprocessor(rl, text):
    return False


ellipsisprocessor = (
    ellipsisreadprocessor,
    ellipsiswriteprocessor,
    ellipsisrawprocessor,
)


def _verify_revision(rl, skipflags, state, node):
    """Verify the integrity of the given revlog ``node`` while providing a hook
    point for extensions to influence the operation."""
    if skipflags:
        state[b'skipread'].add(node)
    else:
        # Side-effect: read content and verify hash.
        rl.revision(node)


# True if a fast implementation for persistent-nodemap is available
#
# We also consider we have a "fast" implementation in "pure" python because
# people using pure don't really have performance consideration (and a
# wheelbarrow of other slowness source)
HAS_FAST_PERSISTENT_NODEMAP = rustrevlog is not None or hasattr(
    parsers, 'BaseIndexObject'
)


@attr.s(slots=True)
class revlogrevisiondelta(repository.irevisiondelta):
    node = attr.ib(type=bytes)
    p1node = attr.ib(type=bytes)
    p2node = attr.ib(type=bytes)
    basenode = attr.ib(type=bytes)
    flags = attr.ib(type=int)
    baserevisionsize = attr.ib(type=Optional[int])
    revision = attr.ib(type=Optional[bytes])
    delta = attr.ib(type=Optional[bytes])
    sidedata = attr.ib(type=Optional[bytes])
    protocol_flags = attr.ib(type=int)
    linknode = attr.ib(default=None, type=Optional[bytes])
    snapshot_level = attr.ib(default=None, type=Optional[int])


@attr.s(frozen=True)
class revlogproblem(repository.iverifyproblem):
    warning = attr.ib(default=None, type=Optional[bytes])
    error = attr.ib(default=None, type=Optional[bytes])
    node = attr.ib(default=None, type=Optional[bytes])


def parse_index_v1(
    data,
    inline,
    uses_generaldelta,
    uses_delta_info,
):
    # call the C implementation to parse the index data
    index, cache = parsers.parse_index2(
        data,
        inline,
        uses_generaldelta,
        uses_delta_info,
    )
    return index, cache


def parse_index_v2(
    data,
    inline,
    uses_generaldelta,
    uses_delta_info,
):
    # call the C implementation to parse the index data
    index, cache = parsers.parse_index2(
        data,
        inline,
        uses_generaldelta,
        uses_delta_info,
        format=REVLOGV2,
    )
    return index, cache


def parse_index_cl_v2(
    data,
    inline,
    uses_generaldelta,
    uses_delta_info,
):
    # call the C implementation to parse the index data
    index, cache = parsers.parse_index2(
        data,
        inline,
        uses_generaldelta,
        uses_delta_info,
        format=CHANGELOGV2,
    )
    return index, cache


if hasattr(parsers, 'parse_index_devel_nodemap'):

    def parse_index_v1_nodemap(
        data,
        inline,
        uses_generaldelta,
        uses_delta_info,
    ):
        index, cache = parsers.parse_index_devel_nodemap(
            data,
            inline,
            uses_generaldelta,
            uses_delta_info,
        )
        return index, cache

else:
    parse_index_v1_nodemap = None


# corresponds to uncompressed length of indexformatng (2 gigs, 4-byte
# signed integer)
_maxentrysize = 0x7FFFFFFF

FILE_TOO_SHORT_MSG = _(
    b'cannot read from revlog %s;'
    b'  expected %d bytes from offset %d, data size is %d'
)

hexdigits = b'0123456789abcdefABCDEF'


class _InnerRevlog:
    """An inner layer of the revlog object

    That layer exist to be able to delegate some operation to Rust, its
    boundaries are arbitrary and based on what we can delegate to Rust.
    """

    opener: vfsmod.vfs

    def __init__(
        self,
        opener: vfsmod.vfs,
        index,
        index_file,
        data_file,
        sidedata_file,
        inline,
        data_config,
        delta_config,
        feature_config,
        chunk_cache,
        default_compression_header,
    ):
        self.opener = opener
        self.index: BaseIndexObject = index

        self.index_file = index_file
        self.data_file = data_file
        self.sidedata_file = sidedata_file
        self.inline = inline
        self.data_config = data_config
        self.delta_config = delta_config
        self.feature_config = feature_config

        # used during diverted write.
        self._orig_index_file = None

        self._default_compression_header = default_compression_header

        # index

        # 3-tuple of file handles being used for active writing.
        self._writinghandles = None

        self._segmentfile = randomaccessfile.randomaccessfile(
            self.opener,
            (self.index_file if self.inline else self.data_file),
            self.data_config.chunk_cache_size,
            chunk_cache,
        )
        self._segmentfile_sidedata = randomaccessfile.randomaccessfile(
            self.opener,
            self.sidedata_file,
            self.data_config.chunk_cache_size,
        )

        # revlog header -> revlog compressor
        self._decompressors = {}
        # 3-tuple of (node, rev, text) for a raw revision.
        self._revisioncache = None

        # cache some uncompressed chunks
        # rev → uncompressed_chunk
        #
        # the max cost is dynamically updated to be proportionnal to the
        # size of revision we actually encounter.
        self._uncompressed_chunk_cache = None
        if self.data_config.uncompressed_cache_factor is not None:
            self._uncompressed_chunk_cache = util.lrucachedict(
                self.data_config.uncompressed_cache_count,
                maxcost=65536,  # some arbitrary initial value
            )

        self._delay_buffer = None

    def __len__(self):
        return len(self.index)

    def clear_cache(self):
        assert not self.is_delaying
        self._revisioncache = None
        if self._uncompressed_chunk_cache is not None:
            self._uncompressed_chunk_cache.clear()
        self._segmentfile.clear_cache()
        self._segmentfile_sidedata.clear_cache()

    @property
    def canonical_index_file(self):
        if self._orig_index_file is not None:
            return self._orig_index_file
        return self.index_file

    @property
    def is_delaying(self):
        """is the revlog is currently delaying the visibility of written data?

        The delaying mechanism can be either in-memory or written on disk in a
        side-file."""
        return (self._delay_buffer is not None) or (
            self._orig_index_file is not None
        )

    # Derived from index values.

    def start(self, rev):
        """the offset of the data chunk for this revision"""
        return int(self.index[rev][0] >> 16)

    def length(self, rev):
        """the length of the data chunk for this revision"""
        return self.index[rev][1]

    def end(self, rev):
        """the end of the data chunk for this revision"""
        return self.start(rev) + self.length(rev)

    def deltaparent(self, rev):
        """return deltaparent of the given revision"""
        base = self.index[rev][3]
        if base == rev:
            return nullrev
        elif self.delta_config.general_delta:
            return base
        else:
            return rev - 1

    def issnapshot(self, rev):
        """tells whether rev is a snapshot"""
        if not self.delta_config.sparse_revlog:
            return self.deltaparent(rev) == nullrev
        elif hasattr(self.index, 'issnapshot'):
            # directly assign the method to cache the testing and access
            self.issnapshot = self.index.issnapshot
            return self.issnapshot(rev)
        elif self.data_config.delta_info:
            flags = self.index[rev][0] & 0xFFFF
            return flags & REVIDX_DELTA_IS_SNAPSHOT
        if rev == nullrev:
            return True
        entry = self.index[rev]
        base = entry[3]
        if base == rev:
            return True
        if base == nullrev:
            return True
        p1 = entry[5]
        while self.length(p1) == 0:
            b = self.deltaparent(p1)
            if b == p1:
                break
            p1 = b
        p2 = entry[6]
        while self.length(p2) == 0:
            b = self.deltaparent(p2)
            if b == p2:
                break
            p2 = b
        if base == p1 or base == p2:
            return False
        return self.issnapshot(base)

    def _deltachain(self, rev, stoprev=None):
        """Obtain the delta chain for a revision.

        ``stoprev`` specifies a revision to stop at. If not specified, we
        stop at the base of the chain.

        Returns a 2-tuple of (chain, stopped) where ``chain`` is a list of
        revs in ascending order and ``stopped`` is a bool indicating whether
        ``stoprev`` was hit.
        """
        # Try C implementation.
        try:
            return self.index.deltachain(
                rev, stoprev
            )  # pytype: disable=attribute-error
        except AttributeError:
            pass

        chain = []

        # Alias to prevent attribute lookup in tight loop.
        index = self.index
        generaldelta = self.delta_config.general_delta

        iterrev = rev
        e = index[iterrev]
        while iterrev != e[3] and iterrev != stoprev:
            chain.append(iterrev)
            if generaldelta:
                iterrev = e[3]
            else:
                iterrev -= 1
            e = index[iterrev]

        if iterrev == stoprev:
            stopped = True
        else:
            chain.append(iterrev)
            stopped = False

        chain.reverse()
        return chain, stopped

    @util.propertycache
    def _compressor(self):
        engine = util.compengines[self.feature_config.compression_engine]
        return engine.revlogcompressor(
            self.feature_config.compression_engine_options
        )

    @util.propertycache
    def _decompressor(self):
        """the default decompressor"""
        if self._default_compression_header is None:
            return None
        t = self._default_compression_header
        c = self._get_decompressor(t)
        return c.decompress

    def _get_decompressor(self, t: bytes):
        try:
            compressor = self._decompressors[t]
        except KeyError:
            try:
                engine = util.compengines.forrevlogheader(t)
                compressor = engine.revlogcompressor(
                    self.feature_config.compression_engine_options
                )
                self._decompressors[t] = compressor
            except KeyError:
                raise error.RevlogError(
                    _(b'unknown compression type %s') % binascii.hexlify(t)
                )
        return compressor

    def compress(self, data: bytes) -> tuple[bytes, bytes]:
        """Generate a possibly-compressed representation of data."""
        if not data:
            return b'', data

        compressed = self._compressor.compress(data)

        if compressed:
            # The revlog compressor added the header in the returned data.
            return b'', compressed

        if data[0:1] == b'\0':
            return b'', data
        return b'u', data

    def decompress(self, data: bytes):
        """Decompress a revlog chunk.

        The chunk is expected to begin with a header identifying the
        format type so it can be routed to an appropriate decompressor.
        """
        if not data:
            return data

        # Revlogs are read much more frequently than they are written and many
        # chunks only take microseconds to decompress, so performance is
        # important here.
        #
        # We can make a few assumptions about revlogs:
        #
        # 1) the majority of chunks will be compressed (as opposed to inline
        #    raw data).
        # 2) decompressing *any* data will likely by at least 10x slower than
        #    returning raw inline data.
        # 3) we want to prioritize common and officially supported compression
        #    engines
        #
        # It follows that we want to optimize for "decompress compressed data
        # when encoded with common and officially supported compression engines"
        # case over "raw data" and "data encoded by less common or non-official
        # compression engines." That is why we have the inline lookup first
        # followed by the compengines lookup.
        #
        # According to `hg perfrevlogchunks`, this is ~0.5% faster for zlib
        # compressed chunks. And this matters for changelog and manifest reads.
        t = data[0:1]

        if t == b'x':
            try:
                return _zlibdecompress(data)
            except zlib.error as e:
                raise error.RevlogError(
                    _(b'revlog decompress error: %s')
                    % stringutil.forcebytestr(e)
                )
        # '\0' is more common than 'u' so it goes first.
        elif t == b'\0':
            return data
        elif t == b'u':
            return util.buffer(data, 1)

        compressor = self._get_decompressor(t)

        return compressor.decompress(data)

    @contextlib.contextmanager
    def reading(self):
        """Context manager that keeps data and sidedata files open for reading"""
        if len(self.index) == 0:
            yield  # nothing to be read
        elif self._delay_buffer is not None and self.inline:
            msg = "revlog with delayed write should not be inline"
            raise error.ProgrammingError(msg)
        else:
            with self._segmentfile.reading():
                with self._segmentfile_sidedata.reading():
                    yield

    @property
    def is_writing(self):
        """True is a writing context is open"""
        return self._writinghandles is not None

    @property
    def is_open(self):
        """True if any file handle is being held

        Used for assert and debug in the python code"""
        return self._segmentfile.is_open or self._segmentfile_sidedata.is_open

    @contextlib.contextmanager
    def writing(self, transaction, data_end=None, sidedata_end=None):
        """Open the revlog files for writing

        Add content to a revlog should be done within such context.
        """
        if self.is_writing:
            yield
        else:
            ifh = dfh = sdfh = None
            try:
                r = len(self.index)
                # opening the data file.
                dsize = 0
                if r:
                    dsize = self.end(r - 1)
                dfh = None
                if not self.inline:
                    try:
                        dfh = self.opener(self.data_file, mode=b"r+")
                        if data_end is None:
                            dfh.seek(0, os.SEEK_END)
                        else:
                            dfh.seek(data_end, os.SEEK_SET)
                    except FileNotFoundError:
                        dfh = self.opener(self.data_file, mode=b"w+")
                    transaction.add(self.data_file, dsize)
                if self.sidedata_file is not None:
                    assert sidedata_end is not None
                    # revlog-v2 does not inline, help Pytype
                    assert dfh is not None
                    try:
                        sdfh = self.opener(self.sidedata_file, mode=b"r+")
                        dfh.seek(sidedata_end, os.SEEK_SET)
                    except FileNotFoundError:
                        sdfh = self.opener(self.sidedata_file, mode=b"w+")
                    transaction.add(self.sidedata_file, sidedata_end)

                # opening the index file.
                isize = r * self.index.entry_size
                ifh = self.__index_write_fp()
                if self.inline:
                    transaction.add(self.index_file, dsize + isize)
                else:
                    transaction.add(self.index_file, isize)
                # exposing all file handle for writing.
                self._writinghandles = (ifh, dfh, sdfh)
                self._segmentfile.writing_handle = ifh if self.inline else dfh
                self._segmentfile_sidedata.writing_handle = sdfh
                yield
            finally:
                self._writinghandles = None
                self._segmentfile.writing_handle = None
                self._segmentfile_sidedata.writing_handle = None
                if dfh is not None:
                    dfh.close()
                if sdfh is not None:
                    sdfh.close()
                # closing the index file last to avoid exposing referent to
                # potential unflushed data content.
                if ifh is not None:
                    ifh.close()

    def __index_write_fp(self, index_end=None):
        """internal method to open the index file for writing

        You should not use this directly and use `_writing` instead
        """
        try:
            if self._delay_buffer is None:
                f = self.opener(
                    self.index_file,
                    mode=b"r+",
                    checkambig=self.data_config.check_ambig,
                )
            else:
                # check_ambig affect we way we open file for writing, however
                # here, we do not actually open a file for writting as write
                # will appened to a delay_buffer. So check_ambig is not
                # meaningful and unneeded here.
                f = randomaccessfile.appender(
                    self.opener, self.index_file, b"r+", self._delay_buffer
                )
            if index_end is None:
                f.seek(0, os.SEEK_END)
            else:
                f.seek(index_end, os.SEEK_SET)
            return f
        except FileNotFoundError:
            if self._delay_buffer is None:
                return self.opener(
                    self.index_file,
                    mode=b"w+",
                    checkambig=self.data_config.check_ambig,
                )
            else:
                return randomaccessfile.appender(
                    self.opener, self.index_file, b"w+", self._delay_buffer
                )

    def __index_new_fp(self):
        """internal method to create a new index file for writing

        You should not use this unless you are upgrading from inline revlog
        """
        return self.opener(
            self.index_file,
            mode=b"w",
            checkambig=self.data_config.check_ambig,
        )

    def split_inline(self, tr, header, new_index_file_path=None):
        """split the data of an inline revlog into an index and a data file"""
        assert self._delay_buffer is None
        existing_handles = False
        if self._writinghandles is not None:
            existing_handles = True
            fp = self._writinghandles[0]
            fp.flush()
            fp.close()
            # We can't use the cached file handle after close(). So prevent
            # its usage.
            self._writinghandles = None
            self._segmentfile.writing_handle = None
            # No need to deal with sidedata writing handle as it is only
            # relevant with revlog-v2 which is never inline, not reaching
            # this code

        new_dfh = self.opener(self.data_file, mode=b"w+")
        new_dfh.truncate(0)  # drop any potentially existing data
        try:
            with self.reading():
                for r in range(len(self.index)):
                    new_dfh.write(self.get_segment_for_revs(r, r)[1])
                new_dfh.flush()

            if new_index_file_path is not None:
                self.index_file = new_index_file_path
            with self.__index_new_fp() as fp:
                self.inline = False
                for i in range(len(self.index)):
                    e = self.index.entry_binary(i)
                    if i == 0:
                        packed_header = self.index.pack_header(header)
                        e = packed_header + e
                    fp.write(e)

                # If we don't use side-write, the temp file replace the real
                # index when we exit the context manager

            self._segmentfile = randomaccessfile.randomaccessfile(
                self.opener,
                self.data_file,
                self.data_config.chunk_cache_size,
            )

            if existing_handles:
                # switched from inline to conventional reopen the index
                ifh = self.__index_write_fp()
                self._writinghandles = (ifh, new_dfh, None)
                self._segmentfile.writing_handle = new_dfh
                new_dfh = None
                # No need to deal with sidedata writing handle as it is only
                # relevant with revlog-v2 which is never inline, not reaching
                # this code
        finally:
            if new_dfh is not None:
                new_dfh.close()
        return self.index_file

    def get_segment_for_revs(self, startrev, endrev):
        """Obtain a segment of raw data corresponding to a range of revisions.

        Accepts the start and end revisions and an optional already-open
        file handle to be used for reading. If the file handle is read, its
        seek position will not be preserved.

        Requests for data may be satisfied by a cache.

        Returns a 2-tuple of (offset, data) for the requested range of
        revisions. Offset is the integer offset from the beginning of the
        revlog and data is a str or buffer of the raw byte data.

        Callers will need to call ``self.start(rev)`` and ``self.length(rev)``
        to determine where each revision's data begins and ends.

        API: we should consider making this a private part of the InnerRevlog
        at some point.
        """
        # Inlined self.start(startrev) & self.end(endrev) for perf reasons
        # (functions are expensive).
        index = self.index
        istart = index[startrev]
        start = int(istart[0] >> 16)
        if startrev == endrev:
            end = start + istart[1]
        else:
            iend = index[endrev]
            end = int(iend[0] >> 16) + iend[1]

        if self.inline:
            start += (startrev + 1) * self.index.entry_size
            end += (endrev + 1) * self.index.entry_size
        length = end - start

        return start, self._segmentfile.read_chunk(start, length)

    def _chunk(self, rev):
        """Obtain a single decompressed chunk for a revision.

        Accepts an integer revision and an optional already-open file handle
        to be used for reading. If used, the seek position of the file will not
        be preserved.

        Returns a str holding uncompressed data for the requested revision.
        """
        if self._uncompressed_chunk_cache is not None:
            uncomp = self._uncompressed_chunk_cache.get(rev)
            if uncomp is not None:
                return uncomp

        compression_mode = self.index[rev][10]
        data = self.get_segment_for_revs(rev, rev)[1]
        if compression_mode == COMP_MODE_PLAIN:
            uncomp = data
        elif compression_mode == COMP_MODE_DEFAULT:
            uncomp = self._decompressor(data)
        elif compression_mode == COMP_MODE_INLINE:
            uncomp = self.decompress(data)
        else:
            msg = b'unknown compression mode %d'
            msg %= compression_mode
            raise error.RevlogError(msg)
        if self._uncompressed_chunk_cache is not None:
            self._uncompressed_chunk_cache.insert(rev, uncomp, cost=len(uncomp))
        return uncomp

    def _chunks(self, revs, targetsize=None):
        """Obtain decompressed chunks for the specified revisions.

        Accepts an iterable of numeric revisions that are assumed to be in
        ascending order.

        This function is similar to calling ``self._chunk()`` multiple times,
        but is faster.

        Returns a list with decompressed data for each requested revision.
        """
        if not revs:
            return []
        start = self.start
        length = self.length
        inline = self.inline
        iosize = self.index.entry_size
        buffer = util.buffer

        fetched_revs = []
        fadd = fetched_revs.append

        chunks = []
        ladd = chunks.append

        if self._uncompressed_chunk_cache is None:
            fetched_revs = revs
        else:
            for rev in revs:
                cached_value = self._uncompressed_chunk_cache.get(rev)
                if cached_value is None:
                    fadd(rev)
                else:
                    ladd((rev, cached_value))

        if not fetched_revs:
            slicedchunks = ()
        elif not self.data_config.with_sparse_read:
            slicedchunks = (fetched_revs,)
        else:
            slicedchunks = deltautil.slicechunk(
                self,
                fetched_revs,
                targetsize=targetsize,
            )

        for revschunk in slicedchunks:
            firstrev = revschunk[0]
            # Skip trailing revisions with empty diff
            for lastrev in revschunk[::-1]:
                if length(lastrev) != 0:
                    break

            try:
                offset, data = self.get_segment_for_revs(firstrev, lastrev)
            except OverflowError:
                # issue4215 - we can't cache a run of chunks greater than
                # 2G on Windows
                for rev in revschunk:
                    ladd((rev, self._chunk(rev)))

            decomp = self.decompress
            # self._decompressor might be None, but will not be used in that case
            def_decomp = self._decompressor
            for rev in revschunk:
                chunkstart = start(rev)
                if inline:
                    chunkstart += (rev + 1) * iosize
                chunklength = length(rev)
                comp_mode = self.index[rev][10]
                c = buffer(data, chunkstart - offset, chunklength)
                if comp_mode == COMP_MODE_PLAIN:
                    c = c
                elif comp_mode == COMP_MODE_INLINE:
                    c = decomp(c)
                elif comp_mode == COMP_MODE_DEFAULT:
                    c = def_decomp(c)
                else:
                    msg = b'unknown compression mode %d'
                    msg %= comp_mode
                    raise error.RevlogError(msg)
                ladd((rev, c))
                if self._uncompressed_chunk_cache is not None:
                    self._uncompressed_chunk_cache.insert(rev, c, len(c))

        chunks.sort()
        return [x[1] for x in chunks]

    def raw_text(self, node, rev) -> bytes:
        """return the possibly unvalidated rawtext for a revision

        returns rawtext
        """

        # revision in the cache (could be useful to apply delta)
        cachedrev = None
        # An intermediate text to apply deltas to
        basetext = None

        # Check if we have the entry in cache
        # The cache entry looks like (node, rev, rawtext)
        if self._revisioncache:
            cachedrev = self._revisioncache[1]

        chain, stopped = self._deltachain(rev, stoprev=cachedrev)
        if stopped:
            basetext = self._revisioncache[2]

        # drop cache to save memory, the caller is expected to
        # update self._inner._revisioncache after validating the text
        self._revisioncache = None

        targetsize = None
        rawsize = self.index[rev][2]
        if 0 <= rawsize:
            targetsize = 4 * rawsize

        if self._uncompressed_chunk_cache is not None:
            # dynamically update the uncompressed_chunk_cache size to the
            # largest revision we saw in this revlog.
            factor = self.data_config.uncompressed_cache_factor
            candidate_size = rawsize * factor
            if candidate_size > self._uncompressed_chunk_cache.maxcost:
                self._uncompressed_chunk_cache.maxcost = candidate_size

        bins = self._chunks(chain, targetsize=targetsize)
        if basetext is None:
            basetext = bytes(bins[0])
            bins = bins[1:]

        rawtext = mdiff.patches(basetext, bins)
        del basetext  # let us have a chance to free memory early
        return rawtext

    def sidedata(self, rev, sidedata_end):
        """Return the sidedata for a given revision number."""
        index_entry = self.index[rev]
        sidedata_offset = index_entry[8]
        sidedata_size = index_entry[9]

        if self.inline:
            sidedata_offset += self.index.entry_size * (1 + rev)
        if sidedata_size == 0:
            return {}

        if sidedata_end < sidedata_offset + sidedata_size:
            filename = self.sidedata_file
            end = sidedata_end
            offset = sidedata_offset
            length = sidedata_size
            m = FILE_TOO_SHORT_MSG % (filename, length, offset, end)
            raise error.RevlogError(m)

        comp_segment = self._segmentfile_sidedata.read_chunk(
            sidedata_offset, sidedata_size
        )

        comp = self.index[rev][11]
        if comp == COMP_MODE_PLAIN:
            segment = comp_segment
        elif comp == COMP_MODE_DEFAULT:
            segment = self._decompressor(comp_segment)
        elif comp == COMP_MODE_INLINE:
            segment = self.decompress(comp_segment)
        else:
            msg = b'unknown compression mode %d'
            msg %= comp
            raise error.RevlogError(msg)

        sidedata = sidedatautil.deserialize_sidedata(segment)
        return sidedata

    def write_entry(
        self,
        transaction,
        entry,
        data,
        link,
        offset,
        sidedata,
        sidedata_offset,
        index_end,
        data_end,
        sidedata_end,
    ):
        # Files opened in a+ mode have inconsistent behavior on various
        # platforms. Windows requires that a file positioning call be made
        # when the file handle transitions between reads and writes. See
        # 3686fa2b8eee and the mixedfilemodewrapper in windows.py. On other
        # platforms, Python or the platform itself can be buggy. Some versions
        # of Solaris have been observed to not append at the end of the file
        # if the file was seeked to before the end. See issue4943 for more.
        #
        # We work around this issue by inserting a seek() before writing.
        # Note: This is likely not necessary on Python 3. However, because
        # the file handle is reused for reads and may be seeked there, we need
        # to be careful before changing this.
        if self._writinghandles is None:
            msg = b'adding revision outside `revlog._writing` context'
            raise error.ProgrammingError(msg)
        ifh, dfh, sdfh = self._writinghandles
        if index_end is None:
            ifh.seek(0, os.SEEK_END)
        else:
            ifh.seek(index_end, os.SEEK_SET)
        if dfh:
            if data_end is None:
                dfh.seek(0, os.SEEK_END)
            else:
                dfh.seek(data_end, os.SEEK_SET)
        if sdfh:
            sdfh.seek(sidedata_end, os.SEEK_SET)

        curr = len(self.index) - 1
        if not self.inline:
            transaction.add(self.data_file, offset)
            if self.sidedata_file:
                transaction.add(self.sidedata_file, sidedata_offset)
            transaction.add(self.canonical_index_file, curr * len(entry))
            if data[0]:
                dfh.write(data[0])
            dfh.write(data[1])
            if sidedata:
                sdfh.write(sidedata)
            if self._delay_buffer is None:
                ifh.write(entry)
            else:
                self._delay_buffer.append(entry)
        elif self._delay_buffer is not None:
            msg = b'invalid delayed write on inline revlog'
            raise error.ProgrammingError(msg)
        else:
            offset += curr * self.index.entry_size
            transaction.add(self.canonical_index_file, offset)
            assert not sidedata
            ifh.write(entry)
            ifh.write(data[0])
            ifh.write(data[1])
        return (
            ifh.tell(),
            dfh.tell() if dfh else None,
            sdfh.tell() if sdfh else None,
        )

    def _divert_index(self):
        index_file = self.index_file
        # when we encounter a legacy inline-changelog, split it. However it is
        # important to use the expected filename for pending content
        # (<radix>.a) otherwise hooks won't be seeing the content of the
        # pending transaction.
        if index_file.endswith(b'.s'):
            index_file = self.index_file[:-2]
        return index_file + b'.a'

    def delay(self):
        assert not self.is_open
        if self.inline:
            msg = "revlog with delayed write should not be inline"
            raise error.ProgrammingError(msg)
        if self._delay_buffer is not None or self._orig_index_file is not None:
            # delay or divert already in place
            return None
        elif len(self.index) == 0:
            self._orig_index_file = self.index_file
            self.index_file = self._divert_index()
            assert self._orig_index_file is not None
            assert self.index_file is not None
            if self.opener.exists(self.index_file):
                self.opener.unlink(self.index_file)
            return self.index_file
        else:
            self._delay_buffer = []
            return None

    def write_pending(self):
        assert not self.is_open
        if self.inline:
            msg = "revlog with delayed write should not be inline"
            raise error.ProgrammingError(msg)
        if self._orig_index_file is not None:
            return None, True
        any_pending = False
        pending_index_file = self._divert_index()
        if self.opener.exists(pending_index_file):
            self.opener.unlink(pending_index_file)
        util.copyfile(
            self.opener.join(self.index_file),
            self.opener.join(pending_index_file),
        )
        if self._delay_buffer:
            with self.opener(pending_index_file, b'r+') as ifh:
                ifh.seek(0, os.SEEK_END)
                ifh.write(b"".join(self._delay_buffer))
            any_pending = True
        self._delay_buffer = None
        self._orig_index_file = self.index_file
        self.index_file = pending_index_file
        return self.index_file, any_pending

    def finalize_pending(self):
        assert not self.is_open
        if self.inline:
            msg = "revlog with delayed write should not be inline"
            raise error.ProgrammingError(msg)

        delay = self._delay_buffer is not None
        divert = self._orig_index_file is not None

        if delay and divert:
            assert False, "unreachable"
        elif delay:
            if self._delay_buffer:
                with self.opener(self.index_file, b'r+') as ifh:
                    ifh.seek(0, os.SEEK_END)
                    ifh.write(b"".join(self._delay_buffer))
            self._delay_buffer = None
        elif divert:
            if self.opener.exists(self.index_file):
                self.opener.rename(
                    self.index_file,
                    self._orig_index_file,
                    checkambig=True,
                )
            self.index_file = self._orig_index_file
            self._orig_index_file = None
        else:
            msg = b"not delay or divert found on this revlog"
            raise error.ProgrammingError(msg)
        return self.canonical_index_file


if typing.TYPE_CHECKING:
    # Tell Pytype what kind of object we expect
    ProxyBase = BaseIndexObject
else:
    ProxyBase = object


class RustIndexProxy(ProxyBase):
    """Wrapper around the Rust index to fake having direct access to the index.

    Rust enforces xor mutability (one mutable reference XOR 1..n non-mutable),
    so we can't expose the index from Rust directly, since the `InnerRevlog`
    already has ownership of the index. This object redirects all calls to the
    index through the Rust-backed `InnerRevlog` glue which defines all
    necessary forwarding methods.
    """

    def __init__(self, inner):
        # Do not rename as it's being used to access the index from Rust
        self.inner = inner

        # Direct reforwards since `__getattr__` is *expensive*
        self.get_rev = self.inner._index_get_rev
        self.rev = self.inner._index_rev
        self.has_node = self.inner._index_has_node
        self.shortest = self.inner._index_shortest
        self.partialmatch = self.inner._index_partialmatch
        self.append = self.inner._index_append
        self.ancestors = self.inner._index_ancestors
        self.commonancestorsheads = self.inner._index_commonancestorsheads
        self.clearcaches = self.inner._index_clearcaches
        self.entry_binary = self.inner._index_entry_binary
        self.pack_header = self.inner._index_pack_header
        self.computephasesmapsets = self.inner._index_computephasesmapsets
        self.reachableroots2 = self.inner._index_reachableroots2
        self.headrevs = self.inner._index_headrevs
        self.head_node_ids = self.inner._index_head_node_ids
        self.headrevsdiff = self.inner._index_headrevsdiff
        self.issnapshot = self.inner._index_issnapshot
        self.findsnapshots = self.inner._index_findsnapshots
        self.deltachain = self.inner._index_deltachain
        self.slicechunktodensity = self.inner._index_slicechunktodensity
        self.nodemap_data_all = self.inner._index_nodemap_data_all
        self.nodemap_data_incremental = (
            self.inner._index_nodemap_data_incremental
        )
        self.update_nodemap_data = self.inner._index_update_nodemap_data
        self.entry_size = self.inner._index_entry_size
        self.rust_ext_compat = self.inner._index_rust_ext_compat
        self._is_rust = self.inner._index_is_rust

    # Magic methods need to be defined explicitely
    def __len__(self):
        return self.inner._index___len__()

    def __getitem__(self, key):
        return self.inner._index___getitem__(key)

    def __contains__(self, key):
        return self.inner._index___contains__(key)

    def __delitem__(self, key):
        return self.inner._index___delitem__(key)


class RustVFSWrapper:
    """Used to wrap a Python VFS to pass it to Rust to lower the overhead of
    calling back multiple times into Python.
    """

    def __init__(self, inner):
        self.inner = inner

    def __call__(
        self,
        path: bytes,
        mode: bytes = b"rb",
        atomictemp=False,
        checkambig=False,
    ):
        fd = self.inner.__call__(
            path=path, mode=mode, atomictemp=atomictemp, checkambig=checkambig
        )
        # Information that Rust needs to get ownership of the file that's
        # being opened.
        return (os.dup(fd.fileno()), fd._tempname if atomictemp else None)

    def __getattr__(self, name):
        return getattr(self.inner, name)


class revlog:
    """
    the underlying revision storage object

    A revlog consists of two parts, an index and the revision data.

    The index is a file with a fixed record size containing
    information on each revision, including its nodeid (hash), the
    nodeids of its parents, the position and offset of its data within
    the data file, and the revision it's based on. Finally, each entry
    contains a linkrev entry that can serve as a pointer to external
    data.

    The revision data itself is a linear collection of data chunks.
    Each chunk represents a revision and is usually represented as a
    delta against the previous chunk. To bound lookup time, runs of
    deltas are limited to about 2 times the length of the original
    version data. This makes retrieval of a version proportional to
    its size, or O(1) relative to the number of revisions.

    Both pieces of the revlog are written to in an append-only
    fashion, which means we never need to rewrite a file to insert or
    remove data, and can use some simple techniques to avoid the need
    for locking while reading.

    If checkambig, indexfile is opened with checkambig=True at
    writing, to avoid file stat ambiguity.

    If mmaplargeindex is True, and an mmapindexthreshold is set, the
    index will be mmapped rather than read if it is larger than the
    configured threshold.

    If censorable is True, the revlog can have censored revisions.

    If `upperboundcomp` is not None, this is the expected maximal gain from
    compression for the data content.

    `concurrencychecker` is an optional function that receives 3 arguments: a
    file handle, a filename, and an expected position. It should check whether
    the current position in the file handle is valid, and log/warn/fail (by
    raising).

    See mercurial/revlogutils/contants.py for details about the content of an
    index entry.
    """

    _flagserrorclass = error.RevlogError
    _inner: _InnerRevlog

    opener: vfsmod.vfs

    @staticmethod
    def is_inline_index(header_bytes):
        """Determine if a revlog is inline from the initial bytes of the index"""
        if len(header_bytes) == 0:
            return True

        header = INDEX_HEADER.unpack(header_bytes)[0]

        _format_flags = header & ~0xFFFF
        _format_version = header & 0xFFFF

        features = FEATURES_BY_VERSION[_format_version]
        return features['inline'](_format_flags)

    _docket_file: bytes | None

    def __init__(
        self,
        opener: vfsmod.vfs,
        target,
        radix,
        postfix=None,  # only exist for `tmpcensored` now
        checkambig=False,
        mmaplargeindex=False,
        censorable=False,
        upperboundcomp=None,
        persistentnodemap=False,
        concurrencychecker=None,
        trypending=False,
        try_split=False,
        canonical_parent_order=True,
        data_config=None,
        delta_config=None,
        feature_config=None,
        may_inline=True,  # may inline new revlog
        writable: Optional[
            bool
        ] = None,  # None is "unspecified" and allow writing
    ):
        """
        create a revlog object

        opener is a function that abstracts the file opening operation
        and can be used to implement COW semantics or the like.

        `target`: a (KIND, ID) tuple that identify the content stored in
        this revlog. It help the rest of the code to understand what the revlog
        is about without having to resort to heuristic and index filename
        analysis. Note: that this must be reliably be set by normal code, but
        that test, debug, or performance measurement code might not set this to
        accurate value.
        """

        self.radix = radix

        self._docket_file = None
        self._indexfile = None
        self._datafile = None
        self._sidedatafile = None
        self._nodemap_file = None
        self.postfix = postfix
        self._trypending = trypending
        self._try_split = try_split
        self._may_inline = may_inline
        self.uses_rust = False
        self.opener = opener
        if persistentnodemap:
            self._nodemap_file = nodemaputil.get_nodemap_file(self)

        assert target[0] in ALL_KINDS
        assert len(target) == 2
        self.target = target
        if writable is None:
            if target[0] == KIND_FILELOG:
                msg = b"filelog need explicit value for `writable` parameter"
                util.nouideprecwarn(msg, b'7.1')
            self._writable = True
        else:
            self._writable = bool(writable)
        if feature_config is not None:
            self.feature_config = feature_config.copy()
        elif b'feature-config' in self.opener.options:
            self.feature_config = self.opener.options[b'feature-config'].copy()
        else:
            self.feature_config = revlog_config.FeatureConfig()
        self.feature_config.censorable = censorable
        self.feature_config.canonical_parent_order = canonical_parent_order
        if data_config is not None:
            self.data_config = data_config.copy()
        elif b'data-config' in self.opener.options:
            self.data_config = self.opener.options[b'data-config'].copy()
        else:
            self.data_config = revlog_config.DataConfig()
        self.data_config.check_ambig = checkambig
        self.data_config.mmap_large_index = mmaplargeindex
        if delta_config is not None:
            self.delta_config = delta_config.copy()
        elif b'delta-config' in self.opener.options:
            self.delta_config = self.opener.options[b'delta-config'].copy()
        else:
            self.delta_config = revlog_config.DeltaConfig()
        self.delta_config.upper_bound_comp = upperboundcomp

        # Maps rev to chain base rev.
        self._chainbasecache = util.lrucachedict(100)

        self.index: BaseIndexObject | None = None
        self._docket = None
        self._nodemap_docket = None
        # Mapping of partial identifiers to full nodes.
        self._pcache = {}

        # other optionnals features

        # Make copy of flag processors so each revlog instance can support
        # custom flags.
        self._flagprocessors = dict(flagutil.flagprocessors)
        # prevent nesting of addgroup
        self._adding_group = None

        index, chunk_cache = self._loadindex()
        self._load_inner(index, chunk_cache)
        self._concurrencychecker = concurrencychecker

    def _init_opts(self):
        """process options (from above/config) to setup associated default revlog mode

        These values might be affected when actually reading on disk information.

        The relevant values are returned for use in _loadindex().

        * newversionflags:
            version header to use if we need to create a new revlog

        * mmapindexthreshold:
            minimal index size for start to use mmap

        * force_nodemap:
            force the usage of a "development" version of the nodemap code
        """
        opts = self.opener.options

        if b'changelogv2' in opts and self.revlog_kind == KIND_CHANGELOG:
            new_header = CHANGELOGV2
            compute_rank = opts.get(b'changelogv2.compute-rank', True)
            self.feature_config.compute_rank = compute_rank
        elif b'revlogv2' in opts:
            new_header = REVLOGV2
        elif b'revlogv1' in opts:
            new_header = REVLOGV1
            if self._may_inline:
                new_header |= FLAG_INLINE_DATA
            if b'generaldelta' in opts:
                new_header |= FLAG_GENERALDELTA
                if opts.get(b'delta-info-flags'):
                    new_header |= FLAG_DELTA_INFO
            if (
                self.revlog_kind == KIND_FILELOG
                and b'filelog_hasmeta_flag' in opts
            ):
                new_header |= FLAG_FILELOG_META
        elif b'revlogv0' in self.opener.options:
            new_header = REVLOGV0
        else:
            new_header = REVLOG_DEFAULT_VERSION

        mmapindexthreshold = None
        if self.data_config.mmap_large_index:
            mmapindexthreshold = self.data_config.mmap_index_threshold
        if self.feature_config.enable_ellipsis:
            self._flagprocessors[REVIDX_ELLIPSIS] = ellipsisprocessor

        # revlog v0 doesn't have flag processors
        for flag, processor in opts.get(b'flagprocessors', {}).items():
            flagutil.insertflagprocessor(flag, processor, self._flagprocessors)

        chunk_cache_size = self.data_config.chunk_cache_size
        if chunk_cache_size <= 0:
            raise error.RevlogError(
                _(b'revlog chunk cache size %r is not greater than 0')
                % chunk_cache_size
            )
        elif chunk_cache_size & (chunk_cache_size - 1):
            raise error.RevlogError(
                _(b'revlog chunk cache size %r is not a power of 2')
                % chunk_cache_size
            )
        force_nodemap = opts.get(b'devel-force-nodemap', False)
        return new_header, mmapindexthreshold, force_nodemap

    def _get_data(self, filepath, mmap_threshold, size=None):
        """return a file content with or without mmap

        If the file is missing return the empty string"""
        try:
            with self.opener(filepath) as fp:
                if mmap_threshold is not None:
                    file_size = self.opener.fstat(fp).st_size
                    if (
                        file_size >= mmap_threshold
                        and self.opener.is_mmap_safe(filepath)
                    ):
                        if size is not None:
                            # avoid potentiel mmap crash
                            size = min(file_size, size)
                        # TODO: should .close() to release resources without
                        # relying on Python GC
                        if size is None:
                            return util.buffer(util.mmapread(fp))
                        else:
                            return util.buffer(util.mmapread(fp, size))
                if size is None:
                    return fp.read()
                else:
                    return fp.read(size)
        except FileNotFoundError:
            return b''

    def get_streams(self, max_linkrev, force_inline=False):
        """return a list of streams that represent this revlog

        This is used by stream-clone to do bytes to bytes copies of a repository.

        This streams data for all revisions that refer to a changelog revision up
        to `max_linkrev`.

        If `force_inline` is set, it enforces that the stream will represent an inline revlog.

        It returns is a list of three-tuple:

            [
                (filename, bytes_stream, stream_size),
                …
            ]
        """
        n = len(self)
        index = self.index
        while n > 0:
            linkrev = index[n - 1][4]
            if linkrev < max_linkrev:
                break
            # note: this loop will rarely go through multiple iterations, since
            # it only traverses commits created during the current streaming
            # pull operation.
            #
            # If this become a problem, using a binary search should cap the
            # runtime of this.
            n = n - 1
        if n == 0:
            # no data to send
            return []
        index_size = n * index.entry_size
        data_size = self.end(n - 1)

        # XXX we might have been split (or stripped) since the object
        # initialization, We need to close this race too, but having a way to
        # pre-open the file we feed to the revlog and never closing them before
        # we are done streaming.

        if self._inline:

            def get_stream():
                with self.opener(self._indexfile, mode=b"r") as fp:
                    yield None
                    size = index_size + data_size
                    if size <= 65536:
                        yield fp.read(size)
                    else:
                        yield from util.filechunkiter(fp, limit=size)

            inline_stream = get_stream()
            next(inline_stream)
            return [
                (self._indexfile, inline_stream, index_size + data_size),
            ]
        elif force_inline:

            def get_stream():
                with self.reading():
                    yield None

                    for rev in range(n):
                        idx = self.index.entry_binary(rev)
                        if rev == 0 and self._docket is None:
                            # re-inject the inline flag
                            header = self._format_flags
                            header |= self._format_version
                            header |= FLAG_INLINE_DATA
                            header = self.index.pack_header(header)
                            idx = header + idx
                        yield idx
                        yield self._inner.get_segment_for_revs(rev, rev)[1]

            inline_stream = get_stream()
            next(inline_stream)
            return [
                (self._indexfile, inline_stream, index_size + data_size),
            ]
        else:

            def get_index_stream():
                with self.opener(self._indexfile, mode=b"r") as fp:
                    yield None
                    if index_size <= 65536:
                        yield fp.read(index_size)
                    else:
                        yield from util.filechunkiter(fp, limit=index_size)

            def get_data_stream():
                with self._datafp() as fp:
                    yield None
                    if data_size <= 65536:
                        yield fp.read(data_size)
                    else:
                        yield from util.filechunkiter(fp, limit=data_size)

            index_stream = get_index_stream()
            next(index_stream)
            data_stream = get_data_stream()
            next(data_stream)
            return [
                (self._datafile, data_stream, data_size),
                (self._indexfile, index_stream, index_size),
            ]

    def _loadindex(self, docket=None):
        new_header, mmapindexthreshold, force_nodemap = self._init_opts()

        if self.postfix is not None:
            entry_point = b'%s.i.%s' % (self.radix, self.postfix)
        elif self._trypending and self.opener.exists(b'%s.i.a' % self.radix):
            entry_point = b'%s.i.a' % self.radix
        elif self._try_split and self.opener.exists(self._split_index_file):
            entry_point = self._split_index_file
        else:
            entry_point = b'%s.i' % self.radix

        if docket is not None:
            self._docket = docket
            self._docket_file = entry_point
        else:
            self._initempty = True
            entry_data = self._get_data(entry_point, mmapindexthreshold)
            if len(entry_data) > 0:
                header = INDEX_HEADER.unpack(entry_data[:4])[0]
                self._initempty = False
            else:
                header = new_header

            self._format_flags = header & ~0xFFFF
            self._format_version = header & 0xFFFF

            supported_flags = SUPPORTED_FLAGS.get(self._format_version)
            if supported_flags is None:
                msg = _(b'unknown version (%d) in revlog %s')
                msg %= (self._format_version, self.display_id)
                raise error.RevlogError(msg)
            elif self._format_flags & ~supported_flags:
                msg = _(b'unknown flags (%#04x) in version %d revlog %s')
                display_flag = self._format_flags >> 16
                msg %= (display_flag, self._format_version, self.display_id)
                raise error.RevlogError(msg)

            features = FEATURES_BY_VERSION[self._format_version]
            self._inline = features['inline'](self._format_flags)
            self.delta_config.general_delta = features['generaldelta'](
                self._format_flags
            )
            self.delta_config.delta_info = features['delta_info'](
                self._format_flags
            )
            self.data_config.generaldelta = self.delta_config.general_delta
            self.data_config.delta_info = self.delta_config.delta_info
            self.feature_config.has_side_data = features['sidedata']
            self.feature_config.hasmeta_flag = features['hasmeta_flag'](
                self._format_flags
            )

            if not features['docket']:
                self._indexfile = entry_point
                index_data = entry_data
            else:
                self._docket_file = entry_point
                if self._initempty:
                    self._docket = docketutil.default_docket(self, header)
                else:
                    self._docket = docketutil.parse_docket(
                        self, entry_data, use_pending=self._trypending
                    )

        if self._docket is not None:
            self._indexfile = self._docket.index_filepath()
            index_data = b''
            index_size = self._docket.index_end
            if index_size > 0:
                index_data = self._get_data(
                    self._indexfile, mmapindexthreshold, size=index_size
                )
                if len(index_data) < index_size:
                    msg = _(b'too few index data for %s: got %d, expected %d')
                    msg %= (self.display_id, len(index_data), index_size)
                    raise error.RevlogError(msg)

            self._inline = False
            # generaldelta implied by version 2 revlogs.
            self.delta_config.general_delta = True
            self.data_config.generaldelta = True
            # the logic for persistent nodemap will be dealt with within the
            # main docket, so disable it for now.
            self._nodemap_file = None

        if self._docket is not None:
            self._datafile = self._docket.data_filepath()
            self._sidedatafile = self._docket.sidedata_filepath()
        elif self.postfix is None:
            self._datafile = b'%s.d' % self.radix
        else:
            self._datafile = b'%s.d.%s' % (self.radix, self.postfix)

        self.nodeconstants = sha1nodeconstants
        self.nullid = self.nodeconstants.nullid

        # sparse-revlog can't be on without general-delta (issue6056)
        if not self.delta_config.general_delta:
            self.delta_config.sparse_revlog = False

        self._storedeltachains = True

        devel_nodemap = (
            self._nodemap_file
            and force_nodemap
            and parse_index_v1_nodemap is not None
        )

        use_rust_index = False
        rust_applicable = self._nodemap_file is not None
        rust_applicable = rust_applicable or self.target[0] == KIND_FILELOG
        rust_applicable = rust_applicable and getattr(
            self.opener, "rust_compatible", True
        )
        if rustrevlog is not None and rust_applicable:
            # we would like to use the rust_index in all case, especially
            # because it is necessary for AncestorsIterator and LazyAncestors
            # since the 6.7 cycle.
            #
            # However, the performance impact of inconditionnaly building the
            # nodemap is currently a problem for non-persistent nodemap
            # repository.
            use_rust_index = True

            if self._format_version != REVLOGV1:
                use_rust_index = False

        if hasattr(self.opener, "fncache"):
            vfs = self.opener.vfs
            if (
                not self.opener.uses_dotencode
                and not self.opener.uses_plain_encode
            ):
                use_rust_index = False
            if not isinstance(vfs, vfsmod.vfs):
                # Be cautious since we don't support other vfs
                use_rust_index = False
        else:
            # Rust only supports repos with fncache
            use_rust_index = False

        self._parse_index = parse_index_v1
        if self._format_version == REVLOGV0:
            self._parse_index = revlogv0.parse_index_v0
        elif self._format_version == REVLOGV2:
            self._parse_index = parse_index_v2
        elif self._format_version == CHANGELOGV2:
            self._parse_index = parse_index_cl_v2
        elif devel_nodemap:
            self._parse_index = parse_index_v1_nodemap

        if use_rust_index:
            # Let the Rust code parse its own index
            index, chunkcache = (index_data, None)
            self.uses_rust = True
        else:
            try:
                d = self._parse_index(
                    index_data,
                    self._inline,
                    self.delta_config.general_delta,
                    self.delta_config.delta_info,
                )
                index, chunkcache = d
                self._register_nodemap_info(index)
            except (ValueError, IndexError):
                raise error.RevlogError(
                    _(b"index %s is corrupted") % self.display_id
                )
        # revnum -> (chain-length, sum-delta-length)
        self._chaininfocache = util.lrucachedict(500)

        return index, chunkcache

    def _load_inner(self, index, chunk_cache):
        if self._docket is None:
            default_compression_header = None
        else:
            default_compression_header = self._docket.default_compression_header

        if self.uses_rust:
            vfs_is_readonly = False
            fncache = None

            if hasattr(self.opener, "vfs"):
                vfs = self.opener
                if isinstance(vfs, vfsmod.readonlyvfs):
                    vfs_is_readonly = True
                    vfs = vfs.vfs
                fncache = vfs.fncache
                vfs = vfs.vfs
            else:
                vfs = self.opener

            vfs_base = vfs.base
            assert fncache is not None, "Rust only supports repos with fncache"

            self._inner = rustrevlog.InnerRevlog(
                vfs_base=vfs_base,
                fncache=fncache,
                vfs_is_readonly=vfs_is_readonly,
                index_data=index,
                index_file=self._indexfile,
                data_file=self._datafile,
                sidedata_file=self._sidedatafile,
                inline=self._inline,
                data_config=self.data_config,
                delta_config=self.delta_config,
                feature_config=self.feature_config,
                chunk_cache=chunk_cache,
                default_compression_header=default_compression_header,
                revlog_type=self.target[0],
                use_persistent_nodemap=self._nodemap_file is not None,
                use_plain_encoding=self.opener.uses_plain_encode,
            )
            self.index = RustIndexProxy(self._inner)
            self._register_nodemap_info(self.index)
            self.uses_rust = True
        else:
            self._inner = _InnerRevlog(
                opener=self.opener,
                index=index,
                index_file=self._indexfile,
                data_file=self._datafile,
                sidedata_file=self._sidedatafile,
                inline=self._inline,
                data_config=self.data_config,
                delta_config=self.delta_config,
                feature_config=self.feature_config,
                chunk_cache=chunk_cache,
                default_compression_header=default_compression_header,
            )
            self.index = self._inner.index

    def _register_nodemap_info(self, index):
        use_nodemap = (
            not self._inline
            and self._nodemap_file is not None
            and hasattr(index, 'update_nodemap_data')
        )
        if use_nodemap:
            nodemap_data = nodemaputil.persisted_data(self)
            if nodemap_data is not None:
                docket = nodemap_data[0]
                if (
                    len(index) > docket.tip_rev
                    and index[docket.tip_rev][7] == docket.tip_node
                ):
                    # no changelog tampering
                    self._nodemap_docket = docket
                    index.update_nodemap_data(
                        *nodemap_data
                    )  # pytype: disable=attribute-error

    def get_revlog(self):
        """simple function to mirror API of other not-really-revlog API"""
        return self

    @util.propertycache
    def revlog_kind(self):
        return self.target[0]

    @util.propertycache
    def display_id(self):
        """The public facing "ID" of the revlog that we use in message"""
        if self.revlog_kind == KIND_FILELOG:
            # Reference the file without the "data/" prefix, so it is familiar
            # to the user.
            return self.target[1]
        else:
            return self.radix

    def _datafp(self, mode=b'r'):
        """file object for the revlog's data file"""
        return self.opener(self._datafile, mode=mode)

    def tiprev(self):
        return len(self.index) - 1

    def tip(self):
        return self.node(self.tiprev())

    def __contains__(self, rev):
        return 0 <= rev < len(self)

    def __len__(self):
        return len(self.index)

    def __iter__(self) -> Iterator[int]:
        return iter(range(len(self)))

    def revs(self, start=0, stop=None):
        """iterate over all rev in this revlog (from start to stop)"""
        return storageutil.iterrevs(len(self), start=start, stop=stop)

    def hasnode(self, node):
        try:
            self.rev(node)
            return True
        except KeyError:
            return False

    def _candelta(self, baserev, rev):
        """whether two revisions (baserev, rev) can be delta-ed or not"""
        # Disable delta if either rev requires a content-changing flag
        # processor (ex. LFS). This is because such flag processor can alter
        # the rawtext content that the delta will be based on, and two clients
        # could have a same revlog node with different flags (i.e. different
        # rawtext contents) and the delta could be incompatible.
        if (self.flags(baserev) & REVIDX_RAWTEXT_CHANGING_FLAGS) or (
            self.flags(rev) & REVIDX_RAWTEXT_CHANGING_FLAGS
        ):
            return False
        return True

    def update_caches(self, transaction):
        """update on disk cache

        If a transaction is passed, the update may be delayed to transaction
        commit."""
        if self._nodemap_file is not None:
            if transaction is None:
                nodemaputil.update_persistent_nodemap(self)
            else:
                nodemaputil.setup_persistent_nodemap(transaction, self)

    def clearcaches(self, clear_persisted_data: bool = False) -> None:
        """Clear in-memory caches"""
        self._chainbasecache.clear()
        self._inner.clear_cache()
        self._pcache = {}
        self._nodemap_docket = None
        self.index.clearcaches()
        # The python code is the one responsible for validating the docket, we
        # end up having to refresh it here.
        use_nodemap = (
            not self._inline
            and self._nodemap_file is not None
            and hasattr(self.index, 'update_nodemap_data')
        )
        if use_nodemap:
            nodemap_data = nodemaputil.persisted_data(self)
            if nodemap_data is not None:
                self._nodemap_docket = nodemap_data[0]
                self.index.update_nodemap_data(
                    *nodemap_data
                )  # pytype: disable=attribute-error

    def rev(self, node):
        """return the revision number associated with a <nodeid>"""
        try:
            return self.index.rev(node)
        except TypeError:
            raise
        except error.RevlogError:
            # parsers.c radix tree lookup failed
            if (
                node == self.nodeconstants.wdirid
                or node in self.nodeconstants.wdirfilenodeids
            ):
                raise error.WdirUnsupported
            raise error.LookupError(node, self.display_id, _(b'no node'))

    # Accessors for index entries.

    # First tuple entry is 8 bytes. First 6 bytes are offset. Last 2 bytes
    # are flags.
    def start(self, rev):
        return int(self.index[rev][0] >> 16)

    def sidedata_cut_off(self, rev):
        sd_cut_off = self.index[rev][8]
        if sd_cut_off != 0:
            return sd_cut_off
        # This is some annoying dance, because entries without sidedata
        # currently use 0 as their ofsset. (instead of previous-offset +
        # previous-size)
        #
        # We should reconsider this sidedata → 0 sidata_offset policy.
        # In the meantime, we need this.
        while 0 <= rev:
            e = self.index[rev]
            if e[9] != 0:
                return e[8] + e[9]
            rev -= 1
        return 0

    def flags(self, rev):
        return self.index[rev][0] & 0xFFFF

    def length(self, rev):
        return self.index[rev][1]

    def sidedata_length(self, rev):
        if not self.feature_config.has_side_data:
            return 0
        return self.index[rev][9]

    def rawsize(self, rev):
        """return the length of the uncompressed text for a given revision"""
        l = self.index[rev][2]
        if l >= 0:
            return l

        t = self.rawdata(rev)
        return len(t)

    def size(self, rev):
        """length of non-raw text (processed by a "read" flag processor)"""
        # fast path: if no "read" flag processor could change the content,
        # size is rawsize. note: ELLIPSIS is known to not change the content.
        flags = self.flags(rev)
        if flags & (flagutil.REVIDX_KNOWN_FLAGS ^ REVIDX_ELLIPSIS) == 0:
            return self.rawsize(rev)

        return len(self.revision(rev))

    def fast_rank(self, rev):
        """Return the rank of a revision if already known, or None otherwise.

        The rank of a revision is the size of the sub-graph it defines as a
        head. Equivalently, the rank of a revision `r` is the size of the set
        `ancestors(r)`, `r` included.

        This method returns the rank retrieved from the revlog in constant
        time. It makes no attempt at computing unknown values for versions of
        the revlog which do not persist the rank.
        """
        rank = self.index[rev][ENTRY_RANK]
        if self._format_version != CHANGELOGV2 or rank == RANK_UNKNOWN:
            return None
        if rev == nullrev:
            return 0  # convention
        return rank

    def chainbase(self, rev):
        base = self._chainbasecache.get(rev)
        if base is not None:
            return base

        index = self.index
        iterrev = rev
        base = index[iterrev][3]
        while base != iterrev:
            iterrev = base
            base = index[iterrev][3]

        self._chainbasecache[rev] = base
        return base

    def linkrev(self, rev):
        return self.index[rev][4]

    def parentrevs(self, rev):
        try:
            entry = self.index[rev]
        except IndexError:
            if rev == wdirrev:
                raise error.WdirUnsupported
            raise

        if self.feature_config.canonical_parent_order and entry[5] == nullrev:
            return entry[6], entry[5]
        else:
            return entry[5], entry[6]

    # fast parentrevs(rev) where rev isn't filtered
    _uncheckedparentrevs = parentrevs

    def node(self, rev):
        try:
            return self.index[rev][7]
        except IndexError:
            if rev == wdirrev:
                raise error.WdirUnsupported
            raise

    # Derived from index values.

    def end(self, rev):
        return self.start(rev) + self.length(rev)

    def parents(self, node: NodeIdT) -> tuple[NodeIdT, NodeIdT]:
        i = self.index
        d = i[self.rev(node)]
        # inline node() to avoid function call overhead
        if self.feature_config.canonical_parent_order and d[5] == self.nullid:
            return i[d[6]][7], i[d[5]][7]
        else:
            return i[d[5]][7], i[d[6]][7]

    def chainlen(self, rev):
        return self._chaininfo(rev)[0]

    def _chaininfo(self, rev):
        chaininfocache = self._chaininfocache
        if rev in chaininfocache:
            return chaininfocache[rev]
        index = self.index
        generaldelta = self.delta_config.general_delta
        iterrev = rev
        e = index[iterrev]
        clen = 0
        compresseddeltalen = 0
        while iterrev != e[3]:
            clen += 1
            compresseddeltalen += e[1]
            if generaldelta:
                iterrev = e[3]
            else:
                iterrev -= 1
            if iterrev in chaininfocache:
                t = chaininfocache[iterrev]
                clen += t[0]
                compresseddeltalen += t[1]
                break
            e = index[iterrev]
        else:
            # Add text length of base since decompressing that also takes
            # work. For cache hits the length is already included.
            compresseddeltalen += e[1]
        r = (clen, compresseddeltalen)
        chaininfocache[rev] = r
        return r

    def _deltachain(self, rev, stoprev=None):
        return self._inner._deltachain(rev, stoprev=stoprev)

    def ancestors(self, revs, stoprev=0, inclusive=False):
        """Generate the ancestors of 'revs' in reverse revision order.
        Does not generate revs lower than stoprev.

        See the documentation for ancestor.lazyancestors for more details."""

        # first, make sure start revisions aren't filtered
        revs = list(revs)
        checkrev = self.node
        for r in revs:
            checkrev(r)
        # and we're sure ancestors aren't filtered as well

        if rustancestor is not None and self.index.rust_ext_compat:
            lazyancestors = rustancestor.LazyAncestors
            arg = self.index
        else:
            lazyancestors = ancestor.lazyancestors
            arg = self._uncheckedparentrevs
        return lazyancestors(arg, revs, stoprev=stoprev, inclusive=inclusive)

    def descendants(self, revs):
        return dagop.descendantrevs(revs, self.revs, self.parentrevs)

    def findcommonmissing(self, common=None, heads=None):
        """Return a tuple of the ancestors of common and the ancestors of heads
        that are not ancestors of common. In revset terminology, we return the
        tuple:

          ::common, (::heads) - (::common)

        The list is sorted by revision number, meaning it is
        topologically sorted.

        'heads' and 'common' are both lists of node IDs.  If heads is
        not supplied, uses all of the revlog's heads.  If common is not
        supplied, uses nullid."""
        if common is None:
            common = [self.nullid]
        if heads is None:
            heads = self.heads()

        common = [self.rev(n) for n in common]
        heads = [self.rev(n) for n in heads]

        # we want the ancestors, but inclusive
        class lazyset:
            def __init__(self, lazyvalues):
                self.addedvalues = set()
                self.lazyvalues = lazyvalues

            def __contains__(self, value):
                return value in self.addedvalues or value in self.lazyvalues

            def __iter__(self):
                added = self.addedvalues
                for r in added:
                    yield r
                for r in self.lazyvalues:
                    if not r in added:
                        yield r

            def add(self, value):
                self.addedvalues.add(value)

            def update(self, values):
                self.addedvalues.update(values)

        has = lazyset(self.ancestors(common))
        has.add(nullrev)
        has.update(common)

        # take all ancestors from heads that aren't in has
        missing = set()
        visit = collections.deque(r for r in heads if r not in has)
        while visit:
            r = visit.popleft()
            if r in missing:
                continue
            else:
                missing.add(r)
                for p in self.parentrevs(r):
                    if p not in has:
                        visit.append(p)
        missing = list(missing)
        missing.sort()
        return has, [self.node(miss) for miss in missing]

    def incrementalmissingrevs(self, common=None):
        """Return an object that can be used to incrementally compute the
        revision numbers of the ancestors of arbitrary sets that are not
        ancestors of common. This is an ancestor.incrementalmissingancestors
        object.

        'common' is a list of revision numbers. If common is not supplied, uses
        nullrev.
        """
        if common is None:
            common = [nullrev]

        if rustancestor is not None and self.index.rust_ext_compat:
            return rustancestor.MissingAncestors(self.index, common)
        return ancestor.incrementalmissingancestors(self.parentrevs, common)

    def findmissingrevs(self, common=None, heads=None):
        """Return the revision numbers of the ancestors of heads that
        are not ancestors of common.

        More specifically, return a list of revision numbers corresponding to
        nodes N such that every N satisfies the following constraints:

          1. N is an ancestor of some node in 'heads'
          2. N is not an ancestor of any node in 'common'

        The list is sorted by revision number, meaning it is
        topologically sorted.

        'heads' and 'common' are both lists of revision numbers.  If heads is
        not supplied, uses all of the revlog's heads.  If common is not
        supplied, uses nullid."""
        if common is None:
            common = [nullrev]
        if heads is None:
            heads = self.headrevs()

        inc = self.incrementalmissingrevs(common=common)
        return inc.missingancestors(heads)

    def findmissing(self, common=None, heads=None):
        """Return the ancestors of heads that are not ancestors of common.

        More specifically, return a list of nodes N such that every N
        satisfies the following constraints:

          1. N is an ancestor of some node in 'heads'
          2. N is not an ancestor of any node in 'common'

        The list is sorted by revision number, meaning it is
        topologically sorted.

        'heads' and 'common' are both lists of node IDs.  If heads is
        not supplied, uses all of the revlog's heads.  If common is not
        supplied, uses nullid."""
        if common is None:
            common = [self.nullid]
        if heads is None:
            heads = self.heads()

        common = [self.rev(n) for n in common]
        heads = [self.rev(n) for n in heads]

        inc = self.incrementalmissingrevs(common=common)
        return [self.node(r) for r in inc.missingancestors(heads)]

    def nodesbetween(self, roots=None, heads=None):
        """Return a topological path from 'roots' to 'heads'.

        Return a tuple (nodes, outroots, outheads) where 'nodes' is a
        topologically sorted list of all nodes N that satisfy both of
        these constraints:

          1. N is a descendant of some node in 'roots'
          2. N is an ancestor of some node in 'heads'

        Every node is considered to be both a descendant and an ancestor
        of itself, so every reachable node in 'roots' and 'heads' will be
        included in 'nodes'.

        'outroots' is the list of reachable nodes in 'roots', i.e., the
        subset of 'roots' that is returned in 'nodes'.  Likewise,
        'outheads' is the subset of 'heads' that is also in 'nodes'.

        'roots' and 'heads' are both lists of node IDs.  If 'roots' is
        unspecified, uses nullid as the only root.  If 'heads' is
        unspecified, uses list of all of the revlog's heads."""
        nonodes = ([], [], [])
        if roots is not None:
            roots = list(roots)
            if not roots:
                return nonodes
            lowestrev = min([self.rev(n) for n in roots])
        else:
            roots = [self.nullid]  # Everybody's a descendant of nullid
            lowestrev = nullrev
        if (lowestrev == nullrev) and (heads is None):
            # We want _all_ the nodes!
            return (
                [self.node(r) for r in self],
                [self.nullid],
                list(self.heads()),
            )
        if heads is None:
            # All nodes are ancestors, so the latest ancestor is the last
            # node.
            highestrev = len(self) - 1
            # Set ancestors to None to signal that every node is an ancestor.
            ancestors = None
            # Set heads to an empty dictionary for later discovery of heads
            heads = {}
        else:
            heads = list(heads)
            if not heads:
                return nonodes
            ancestors = set()
            # Turn heads into a dictionary so we can remove 'fake' heads.
            # Also, later we will be using it to filter out the heads we can't
            # find from roots.
            heads = dict.fromkeys(heads, False)
            # Start at the top and keep marking parents until we're done.
            nodestotag = set(heads)
            # Remember where the top was so we can use it as a limit later.
            highestrev = max([self.rev(n) for n in nodestotag])
            while nodestotag:
                # grab a node to tag
                n = nodestotag.pop()
                # Never tag nullid
                if n == self.nullid:
                    continue
                # A node's revision number represents its place in a
                # topologically sorted list of nodes.
                r = self.rev(n)
                if r >= lowestrev:
                    if n not in ancestors:
                        # If we are possibly a descendant of one of the roots
                        # and we haven't already been marked as an ancestor
                        ancestors.add(n)  # Mark as ancestor
                        # Add non-nullid parents to list of nodes to tag.
                        nodestotag.update(
                            [p for p in self.parents(n) if p != self.nullid]
                        )
                    elif n in heads:  # We've seen it before, is it a fake head?
                        # So it is, real heads should not be the ancestors of
                        # any other heads.
                        heads.pop(n)
            if not ancestors:
                return nonodes
            # Now that we have our set of ancestors, we want to remove any
            # roots that are not ancestors.

            # If one of the roots was nullid, everything is included anyway.
            if lowestrev > nullrev:
                # But, since we weren't, let's recompute the lowest rev to not
                # include roots that aren't ancestors.

                # Filter out roots that aren't ancestors of heads
                roots = [root for root in roots if root in ancestors]
                # Recompute the lowest revision
                if roots:
                    lowestrev = min([self.rev(root) for root in roots])
                else:
                    # No more roots?  Return empty list
                    return nonodes
            else:
                # We are descending from nullid, and don't need to care about
                # any other roots.
                lowestrev = nullrev
                roots = [self.nullid]
        # Transform our roots list into a set.
        descendants = set(roots)
        # Also, keep the original roots so we can filter out roots that aren't
        # 'real' roots (i.e. are descended from other roots).
        roots = descendants.copy()
        # Our topologically sorted list of output nodes.
        orderedout = []
        # Don't start at nullid since we don't want nullid in our output list,
        # and if nullid shows up in descendants, empty parents will look like
        # they're descendants.
        for r in self.revs(start=max(lowestrev, 0), stop=highestrev + 1):
            n = self.node(r)
            isdescendant = False
            if lowestrev == nullrev:  # Everybody is a descendant of nullid
                isdescendant = True
            elif n in descendants:
                # n is already a descendant
                isdescendant = True
                # This check only needs to be done here because all the roots
                # will start being marked is descendants before the loop.
                if n in roots:
                    # If n was a root, check if it's a 'real' root.
                    p = tuple(self.parents(n))
                    # If any of its parents are descendants, it's not a root.
                    if (p[0] in descendants) or (p[1] in descendants):
                        roots.remove(n)
            else:
                p = tuple(self.parents(n))
                # A node is a descendant if either of its parents are
                # descendants.  (We seeded the dependents list with the roots
                # up there, remember?)
                if (p[0] in descendants) or (p[1] in descendants):
                    descendants.add(n)
                    isdescendant = True
            if isdescendant and ((ancestors is None) or (n in ancestors)):
                # Only include nodes that are both descendants and ancestors.
                orderedout.append(n)
                if (ancestors is not None) and (n in heads):
                    # We're trying to figure out which heads are reachable
                    # from roots.
                    # Mark this head as having been reached
                    heads[n] = True
                elif ancestors is None:
                    # Otherwise, we're trying to discover the heads.
                    # Assume this is a head because if it isn't, the next step
                    # will eventually remove it.
                    heads[n] = True
                    # But, obviously its parents aren't.
                    for p in self.parents(n):
                        heads.pop(p, None)
        heads = [head for head, flag in heads.items() if flag]
        roots = list(roots)
        assert orderedout
        assert roots
        assert heads
        return (orderedout, roots, heads)

    def headrevs(self, revs=None, stop_rev=None):
        if revs is None:
            return self.index.headrevs(None, stop_rev)
        if rustdagop is not None and self.index.rust_ext_compat:
            return rustdagop.headrevs(self.index, revs)
        return dagop.headrevs(revs, self._uncheckedparentrevs)

    def headrevsdiff(self, start, stop):
        try:
            return self.index.headrevsdiff(
                start, stop
            )  # pytype: disable=attribute-error
        except AttributeError:
            return dagop.headrevsdiff(self._uncheckedparentrevs, start, stop)

    def computephases(self, roots):
        return self.index.computephasesmapsets(
            roots
        )  # pytype: disable=attribute-error

    def _head_node_ids(self):
        try:
            return self.index.head_node_ids()  # pytype: disable=attribute-error
        except AttributeError:
            return [self.node(r) for r in self.headrevs()]

    def heads(self, start=None, stop=None):
        """return the list of all nodes that have no children

        if start is specified, only heads that are descendants of
        start will be returned
        if stop is specified, it will consider all the revs from stop
        as if they had no children
        """
        if start is None and stop is None:
            if not len(self):
                return [self.nullid]
            return self._head_node_ids()
        if start is None:
            start = nullrev
        else:
            start = self.rev(start)

        stoprevs = {self.rev(n) for n in stop or []}

        revs = dagop.headrevssubset(
            self.revs, self.parentrevs, startrev=start, stoprevs=stoprevs
        )

        return [self.node(rev) for rev in revs]

    def diffheads(self, start, stop):
        """return the nodes that make up the difference between
        heads of revs before `start` and heads of revs before `stop`"""
        removed, added = self.headrevsdiff(start, stop)
        return [self.node(r) for r in removed], [self.node(r) for r in added]

    def children(self, node):
        """find the children of a given node"""
        c = []
        p = self.rev(node)
        for r in self.revs(start=p + 1):
            prevs = [pr for pr in self.parentrevs(r) if pr != nullrev]
            if prevs:
                for pr in prevs:
                    if pr == p:
                        c.append(self.node(r))
            elif p == nullrev:
                c.append(self.node(r))
        return c

    def commonancestorsheads(self, a, b):
        """calculate all the heads of the common ancestors of nodes a and b"""
        a, b = self.rev(a), self.rev(b)
        ancs = self._commonancestorsheads(a, b)
        return pycompat.maplist(self.node, ancs)

    def _commonancestorsheads(self, *revs):
        """calculate all the heads of the common ancestors of revs"""
        try:
            ancs = self.index.commonancestorsheads(
                *revs
            )  # pytype: disable=attribute-error
        except (AttributeError, OverflowError):  # C implementation failed
            ancs = ancestor.commonancestorsheads(self.parentrevs, *revs)
        return ancs

    def isancestor(self, a, b):
        """return True if node a is an ancestor of node b

        A revision is considered an ancestor of itself."""
        a, b = self.rev(a), self.rev(b)
        return self.isancestorrev(a, b)

    def isancestorrev(self, a, b):
        """return True if revision a is an ancestor of revision b

        A revision is considered an ancestor of itself.

        The implementation of this is trivial but the use of
        reachableroots is not."""
        if a == nullrev:
            return True
        elif a == b:
            return True
        elif a > b:
            return False
        return bool(self.reachableroots(a, [b], [a], includepath=False))

    def reachableroots(self, minroot, heads, roots, includepath=False):
        """return (heads(::(<roots> and <roots>::<heads>)))

        If includepath is True, return (<roots>::<heads>)."""
        try:
            return self.index.reachableroots2(
                minroot, heads, roots, includepath
            )  # pytype: disable=attribute-error
        except AttributeError:
            return dagop._reachablerootspure(
                self.parentrevs, minroot, roots, heads, includepath
            )

    def ancestor(self, a, b):
        """calculate the "best" common ancestor of nodes a and b"""

        a, b = self.rev(a), self.rev(b)
        try:
            ancs = self.index.ancestors(a, b)  # pytype: disable=attribute-error
        except (AttributeError, OverflowError):
            ancs = ancestor.ancestors(self.parentrevs, a, b)
        if ancs:
            # choose a consistent winner when there's a tie
            return min(map(self.node, ancs))
        return self.nullid

    def _match(self, id):
        if isinstance(id, int):
            # rev
            return self.node(id)
        if len(id) == self.nodeconstants.nodelen:
            # possibly a binary node
            # odds of a binary node being all hex in ASCII are 1 in 10**25
            try:
                node = id
                self.rev(node)  # quick search the index
                return node
            except error.LookupError:
                pass  # may be partial hex id
        try:
            # str(rev)
            rev = int(id)
            if b"%d" % rev != id:
                raise ValueError
            if rev < 0:
                rev = len(self) + rev
            if rev < 0 or rev >= len(self):
                raise ValueError
            return self.node(rev)
        except (ValueError, OverflowError):
            pass
        if len(id) == 2 * self.nodeconstants.nodelen:
            try:
                # a full hex nodeid?
                node = bin(id)
                self.rev(node)
                return node
            except (binascii.Error, error.LookupError):
                pass

    def _partialmatch(self, id):
        # we don't care wdirfilenodeids as they should be always full hash
        maybewdir = self.nodeconstants.wdirhex.startswith(id)
        ambiguous = False
        try:
            partial = self.index.partialmatch(
                id
            )  # pytype: disable=attribute-error
            if partial and self.hasnode(partial):
                if maybewdir:
                    # single 'ff...' match in radix tree, ambiguous with wdir
                    ambiguous = True
                else:
                    return partial
            elif maybewdir:
                # no 'ff...' match in radix tree, wdir identified
                raise error.WdirUnsupported
            else:
                return None
        except error.RevlogError:
            # parsers.c radix tree lookup gave multiple matches
            # fast path: for unfiltered changelog, radix tree is accurate
            if not getattr(self, 'filteredrevs', None):
                ambiguous = True
            # fall through to slow path that filters hidden revisions
        except (AttributeError, ValueError):
            # we are pure python, or key is not hex
            pass
        if ambiguous:
            raise error.AmbiguousPrefixLookupError(
                id, self.display_id, _(b'ambiguous identifier')
            )

        if id in self._pcache:
            return self._pcache[id]

        if len(id) <= 40:
            # hex(node)[:...]
            l = len(id) // 2 * 2  # grab an even number of digits
            try:
                # we're dropping the last digit, so let's check that it's hex,
                # to avoid the expensive computation below if it's not
                if len(id) % 2 > 0:
                    if not (id[-1] in hexdigits):
                        return None
                prefix = bin(id[:l])
            except binascii.Error:
                pass
            else:
                nl = [e[7] for e in self.index if e[7].startswith(prefix)]
                nl = [
                    n for n in nl if hex(n).startswith(id) and self.hasnode(n)
                ]
                if self.nodeconstants.nullhex.startswith(id):
                    nl.append(self.nullid)
                if len(nl) > 0:
                    if len(nl) == 1 and not maybewdir:
                        self._pcache[id] = nl[0]
                        return nl[0]
                    raise error.AmbiguousPrefixLookupError(
                        id, self.display_id, _(b'ambiguous identifier')
                    )
                if maybewdir:
                    raise error.WdirUnsupported
                return None

    def lookup(self, id):
        """locate a node based on:
        - revision number or str(revision number)
        - nodeid or subset of hex nodeid
        """
        n = self._match(id)
        if n is not None:
            return n
        n = self._partialmatch(id)
        if n:
            return n

        raise error.LookupError(id, self.display_id, _(b'no match found'))

    def shortest(self, node, minlength=1):
        """Find the shortest unambiguous prefix that matches node."""

        def isvalid(prefix):
            try:
                matchednode = self._partialmatch(prefix)
            except error.AmbiguousPrefixLookupError:
                return False
            except error.WdirUnsupported:
                # single 'ff...' match
                return True
            if matchednode is None:
                raise error.LookupError(node, self.display_id, _(b'no node'))
            return True

        def maybewdir(prefix):
            return all(c == b'f' for c in pycompat.iterbytestr(prefix))

        hexnode = hex(node)

        def disambiguate(hexnode, minlength):
            """Disambiguate against wdirid."""
            for length in range(minlength, len(hexnode) + 1):
                prefix = hexnode[:length]
                if not maybewdir(prefix):
                    return prefix

        if not getattr(self, 'filteredrevs', None):
            try:
                shortest = self.index.shortest(
                    node
                )  # pytype: disable=attribute-error
                length = max(shortest, minlength)
                return disambiguate(hexnode, length)
            except error.RevlogError:
                if node != self.nodeconstants.wdirid:
                    raise error.LookupError(
                        node, self.display_id, _(b'no node')
                    )
            except AttributeError:
                # Fall through to pure code
                pass

        if node == self.nodeconstants.wdirid:
            for length in range(minlength, len(hexnode) + 1):
                prefix = hexnode[:length]
                if isvalid(prefix):
                    return prefix

        for length in range(minlength, len(hexnode) + 1):
            prefix = hexnode[:length]
            if isvalid(prefix):
                return disambiguate(hexnode, length)

    def cmp(self, node, text):
        """compare text with a given file revision

        returns True if text is different than what is stored.
        """
        p1, p2 = self.parents(node)
        return storageutil.hashrevisionsha1(text, p1, p2) != node

    def deltaparent(self, rev):
        """return deltaparent of the given revision"""
        base = self.index[rev][3]
        if base == rev:
            return nullrev
        elif self.delta_config.general_delta:
            return base
        else:
            return rev - 1

    def issnapshot(self, rev):
        """tells whether rev is a snapshot"""
        ret = self._inner.issnapshot(rev)
        self.issnapshot = self._inner.issnapshot
        return ret

    def snapshotdepth(self, rev):
        """number of snapshot in the chain before this one"""
        if not self.issnapshot(rev):
            raise error.ProgrammingError(b'revision %d not a snapshot')
        return len(self._inner._deltachain(rev)[0]) - 1

    def revdiff(self, rev1, rev2):
        """return or calculate a delta between two revisions

        The delta calculated is in binary form and is intended to be written to
        revlog data directly. So this function needs raw revision data.
        """
        if rev1 != nullrev and self.deltaparent(rev2) == rev1:
            return bytes(self._inner._chunk(rev2))

        return mdiff.textdiff(self.rawdata(rev1), self.rawdata(rev2))

    def revision(self, nodeorrev):
        """return an uncompressed revision of a given node or revision
        number.
        """
        return self._revisiondata(nodeorrev)

    def sidedata(self, nodeorrev):
        """a map of extra data related to the changeset but not part of the hash

        This function currently return a dictionary. However, more advanced
        mapping object will likely be used in the future for a more
        efficient/lazy code.
        """
        # deal with <nodeorrev> argument type
        if isinstance(nodeorrev, int):
            rev = nodeorrev
        else:
            rev = self.rev(nodeorrev)
        return self._sidedata(rev)

    def _rawtext(self, node, rev):
        """return the possibly unvalidated rawtext for a revision

        returns (rev, rawtext, validated)
        """
        # Check if we have the entry in cache
        # The cache entry looks like (node, rev, rawtext)
        if self._inner._revisioncache:
            if self._inner._revisioncache[0] == node:
                return (rev, self._inner._revisioncache[2], True)

        if rev is None:
            rev = self.rev(node)

        text = self._inner.raw_text(node, rev)
        return (rev, text, False)

    def _revisiondata(self, nodeorrev, raw=False, validate=True):
        # deal with <nodeorrev> argument type
        if isinstance(nodeorrev, int):
            rev = nodeorrev
            node = self.node(rev)
        else:
            node = nodeorrev
            rev = None

        # fast path the special `nullid` rev
        if node == self.nullid:
            return b""

        # ``rawtext`` is the text as stored inside the revlog. Might be the
        # revision or might need to be processed to retrieve the revision.
        rev, rawtext, validated = self._rawtext(node, rev)

        if raw and validated:
            # if we don't want to process the raw text and that raw
            # text is cached, we can exit early.
            return rawtext
        if rev is None:
            rev = self.rev(node)
        # the revlog's flag for this revision
        # (usually alter its state or content)
        flags = self.flags(rev)

        if validated and flags == REVIDX_DEFAULT_FLAGS:
            # no extra flags set, no flag processor runs, text = rawtext
            return rawtext

        if raw:
            validatehash = flagutil.processflagsraw(self, rawtext, flags)
            text = rawtext
        else:
            r = flagutil.processflagsread(self, rawtext, flags)
            text, validatehash = r
        if validate and validatehash:
            self.checkhash(text, node, rev=rev)
        if not validated:
            self._inner._revisioncache = (node, rev, rawtext)

        return text

    def _sidedata(self, rev):
        """Return the sidedata for a given revision number."""
        if self._sidedatafile is None:
            return {}
        sidedata_end = None
        if self._docket is not None:
            sidedata_end = self._docket.sidedata_end
        return self._inner.sidedata(rev, sidedata_end)

    def rawdata(self, nodeorrev, validate=True):
        """return an uncompressed raw data of a given node or revision number.

        The restored content will be typically have its content checked for
        integrity.  If `validate` is set to False, this won't be the case
        anymore.
        """
        return self._revisiondata(nodeorrev, raw=True, validate=validate)

    def hash(self, text, p1, p2):
        """Compute a node hash.

        Available as a function so that subclasses can replace the hash
        as needed.
        """
        return storageutil.hashrevisionsha1(text, p1, p2)

    def checkhash(self, text, node, p1=None, p2=None, rev=None):
        """Check node hash integrity.

        Available as a function so that subclasses can extend hash mismatch
        behaviors as needed.
        """
        try:
            if p1 is None and p2 is None:
                p1, p2 = self.parents(node)
            if node != self.hash(text, p1, p2):
                # Clear the revision cache on hash failure. The revision cache
                # only stores the raw revision and clearing the cache does have
                # the side-effect that we won't have a cache hit when the raw
                # revision data is accessed. But this case should be rare and
                # it is extra work to teach the cache about the hash
                # verification state.
                if (
                    self._inner._revisioncache
                    and self._inner._revisioncache[0] == node
                ):
                    self._inner._revisioncache = None

                revornode = rev
                if revornode is None:
                    revornode = templatefilters.short(hex(node))
                raise error.RevlogError(
                    _(b"integrity check failed on %s:%s")
                    % (self.display_id, pycompat.bytestr(revornode))
                )
        except error.RevlogError:
            if self.feature_config.censorable and storageutil.iscensoredtext(
                text
            ):
                raise error.CensoredNodeError(self.display_id, node, text)
            raise

    @property
    def _split_index_file(self):
        """the path where to expect the index of an ongoing splitting operation

        The file will only exist if a splitting operation is in progress, but
        it is always expected at the same location."""
        parts = self.radix.split(b'/')
        if len(parts) > 1:
            # adds a '-s' prefix to the ``data/` or `meta/` base
            head = parts[0] + b'-s'
            mids = parts[1:-1]
            tail = parts[-1] + b'.i'
            pieces = [head] + mids + [tail]
            return b'/'.join(pieces)
        else:
            # the revlog is stored at the root of the store (changelog or
            # manifest), no risk of collision.
            return self.radix + b'.i.s'

    def _enforceinlinesize(self, tr):
        """Check if the revlog is too big for inline and convert if so.

        This should be called after revisions are added to the revlog. If the
        revlog has grown too large to be an inline revlog, it will convert it
        to use multiple index and data files.
        """
        tiprev = len(self) - 1
        total_size = self.start(tiprev) + self.length(tiprev)
        if not self._inline or (self._may_inline and total_size < _maxinline):
            return

        if self._docket is not None:
            msg = b"inline revlog should not have a docket"
            raise error.ProgrammingError(msg)

        # In the common case, we enforce inline size because the revlog has
        # been appened too. And in such case, it must have an initial offset
        # recorded in the transaction.
        troffset = tr.findoffset(self._inner.canonical_index_file)
        pre_touched = troffset is not None
        if not pre_touched and self.target[0] != KIND_CHANGELOG:
            raise error.RevlogError(
                _(b"%s not found in the transaction") % self._indexfile
            )

        tr.addbackup(self._inner.canonical_index_file, for_offset=pre_touched)
        tr.add(self._datafile, 0)

        new_index_file_path = None
        old_index_file_path = self._indexfile
        new_index_file_path = self._split_index_file
        opener = self.opener
        weak_self = weakref.ref(self)

        # the "split" index replace the real index when the transaction is
        # finalized
        def finalize_callback(tr):
            opener.rename(
                new_index_file_path,
                old_index_file_path,
                checkambig=True,
            )
            maybe_self = weak_self()
            if maybe_self is not None:
                maybe_self._indexfile = old_index_file_path
                maybe_self._inner.index_file = maybe_self._indexfile

        def abort_callback(tr):
            maybe_self = weak_self()
            if maybe_self is not None:
                maybe_self._indexfile = old_index_file_path
                maybe_self._inner.inline = True
                maybe_self._inner.index_file = old_index_file_path

        tr.registertmp(new_index_file_path)
        # we use 001 here to make this this happens after the finalisation of
        # pending changelog write (using 000). Otherwise the two finalizer
        # would step over each other and delete the changelog.i file.
        if self.target[1] is not None:
            callback_id = b'001-revlog-split-%d-%s' % self.target
        else:
            callback_id = b'001-revlog-split-%d' % self.target[0]
        tr.addfinalize(callback_id, finalize_callback)
        tr.addabort(callback_id, abort_callback)

        self._format_flags &= ~FLAG_INLINE_DATA
        self._inner.split_inline(
            tr,
            self._format_flags | self._format_version,
            new_index_file_path=new_index_file_path,
        )

        self._inline = False
        if new_index_file_path is not None:
            self._indexfile = new_index_file_path

        nodemaputil.setup_persistent_nodemap(tr, self)

    def _nodeduplicatecallback(self, transaction, node):
        """called when trying to add a node already stored."""

    @contextlib.contextmanager
    def reading(self):
        with self._inner.reading():
            yield

    @contextlib.contextmanager
    def _writing(self, transaction):
        if not self._writable:
            msg = b'try to write in a revlog marked as non-writable: %s'
            msg %= self.display_id
            util.nouideprecwarn(msg, b'7.1')
        if self._trypending:
            msg = b'try to write in a `trypending` revlog: %s'
            msg %= self.display_id
            raise error.ProgrammingError(msg)
        if self._inner.is_writing:
            yield
        else:
            data_end = None
            sidedata_end = None
            if self._docket is not None:
                data_end = self._docket.data_end
                sidedata_end = self._docket.sidedata_end
            with self._inner.writing(
                transaction,
                data_end=data_end,
                sidedata_end=sidedata_end,
            ):
                yield
                if self._docket is not None:
                    self._write_docket(transaction)

    @property
    def is_delaying(self):
        return self._inner.is_delaying

    def _write_docket(self, transaction):
        """write the current docket on disk

        Exist as a method to help changelog to implement transaction logic

        We could also imagine using the same transaction logic for all revlog
        since docket are cheap."""
        self._docket.write(transaction)

    def addrevision(
        self,
        text,
        transaction,
        link,
        p1,
        p2,
        cachedelta: revlogutils.CachedDelta | None = None,
        node=None,
        flags=REVIDX_DEFAULT_FLAGS,
        deltacomputer=None,
        sidedata=None,
    ):
        """add a revision to the log

        text - the revision data to add
        transaction - the transaction object used for rollback
        link - the linkrev data to add
        p1, p2 - the parent nodeids of the revision
        cachedelta - an optional precomputed delta
        node - nodeid of revision; typically node is not specified, and it is
            computed by default as hash(text, p1, p2), however subclasses might
            use different hashing method (and override checkhash() in such case)
        flags - the known flags to set on the revision
        deltacomputer - an optional deltacomputer instance shared between
            multiple calls
        """
        if link == nullrev:
            raise error.RevlogError(
                _(b"attempted to add linkrev -1 to %s") % self.display_id
            )

        if sidedata is None:
            sidedata = {}
        elif sidedata and not self.feature_config.has_side_data:
            raise error.ProgrammingError(
                _(b"trying to add sidedata to a revlog who don't support them")
            )

        if flags:
            node = node or self.hash(text, p1, p2)

        rawtext, validatehash = flagutil.processflagswrite(self, text, flags)

        # If the flag processor modifies the revision data, ignore any provided
        # cachedelta.
        if rawtext != text:
            cachedelta = None

        if len(rawtext) > _maxentrysize:
            raise error.RevlogError(
                _(
                    b"%s: size of %d bytes exceeds maximum revlog storage of 2GiB"
                )
                % (self.display_id, len(rawtext))
            )

        node = node or self.hash(rawtext, p1, p2)
        rev = self.index.get_rev(node)
        if rev is not None:
            return rev

        if validatehash:
            self.checkhash(rawtext, node, p1=p1, p2=p2)

        return self.addrawrevision(
            rawtext,
            transaction,
            link,
            p1,
            p2,
            node,
            flags,
            cachedelta=cachedelta,
            deltacomputer=deltacomputer,
            sidedata=sidedata,
        )

    def addrawrevision(
        self,
        rawtext,
        transaction,
        link,
        p1,
        p2,
        node,
        flags,
        cachedelta: revlogutils.CachedDelta | None = None,
        deltacomputer=None,
        sidedata=None,
    ):
        """add a raw revision with known flags, node and parents
        useful when reusing a revision not stored in this revlog (ex: received
        over wire, or read from an external bundle).
        """
        with self._writing(transaction):
            return self._addrevision(
                node,
                rawtext,
                transaction,
                link,
                p1,
                p2,
                flags,
                cachedelta,
                deltacomputer=deltacomputer,
                sidedata=sidedata,
            )

    def compress(self, data: bytes) -> tuple[bytes, bytes]:
        return self._inner.compress(data)

    def decompress(self, data):
        return self._inner.decompress(data)

    def _addrevision(
        self,
        node,
        rawtext,
        transaction,
        link,
        p1,
        p2,
        flags,
        cachedelta: revlogutils.CachedDelta | None,
        alwayscache=False,
        deltacomputer=None,
        sidedata=None,
    ):
        """internal function to add revisions to the log

        see addrevision for argument descriptions.

        note: "addrevision" takes non-raw text, "_addrevision" takes raw text.

        if "deltacomputer" is not provided or None, a defaultdeltacomputer will
        be used.

        invariants:
        - rawtext is optional (can be None); if not set, cachedelta must be set.
          if both are set, they must correspond to each other.
        """
        if node == self.nullid:
            raise error.RevlogError(
                _(b"%s: attempt to add null revision") % self.display_id
            )
        if (
            node == self.nodeconstants.wdirid
            or node in self.nodeconstants.wdirfilenodeids
        ):
            raise error.RevlogError(
                _(b"%s: attempt to add wdir revision") % self.display_id
            )
        if not self._inner.is_writing:
            msg = b'adding revision outside `revlog._writing` context'
            raise error.ProgrammingError(msg)

        curr = len(self)
        prev = curr - 1

        offset = self._get_data_offset(prev)

        if self._concurrencychecker:
            ifh, dfh, sdfh = self._inner._writinghandles
            # XXX no checking for the sidedata file
            if self._inline:
                # offset is "as if" it were in the .d file, so we need to add on
                # the size of the entry metadata.
                self._concurrencychecker(
                    ifh, self._indexfile, offset + curr * self.index.entry_size
                )
            else:
                # Entries in the .i are a consistent size.
                self._concurrencychecker(
                    ifh, self._indexfile, curr * self.index.entry_size
                )
                self._concurrencychecker(dfh, self._datafile, offset)

        p1r, p2r = self.rev(p1), self.rev(p2)

        # full versions are inserted when the needed deltas
        # become comparable to the uncompressed text
        if rawtext is None:
            assert cachedelta is not None
            # need rawtext size, before changed by flag processors, which is
            # the non-raw size. use revlog explicitly to avoid filelog's extra
            # logic that might remove metadata size.
            textlen = mdiff.patchedsize(
                revlog.size(self, cachedelta.base), cachedelta.delta
            )
        else:
            textlen = len(rawtext)

        if deltacomputer is None:
            write_debug = None
            if self.delta_config.debug_delta:
                write_debug = transaction._report
            deltacomputer = deltautil.deltacomputer(
                self, write_debug=write_debug
            )

        if cachedelta is not None and cachedelta.reuse_policy is None:
            # If the cached delta has no information about how it should be
            # reused, add the default reuse instruction according to the
            # revlog's configuration.
            if (
                self.delta_config.general_delta
                and self.delta_config.lazy_delta_base
            ):
                delta_base_reuse = DELTA_BASE_REUSE_TRY
            else:
                delta_base_reuse = DELTA_BASE_REUSE_NO
            cachedelta.reuse_policy = delta_base_reuse

        revinfo = revlogutils.revisioninfo(
            node,
            p1,
            p2,
            rawtext,
            textlen,
            cachedelta,
            flags,
        )

        deltainfo = deltacomputer.finddeltainfo(revinfo)

        compression_mode = COMP_MODE_INLINE
        if self._docket is not None:
            default_comp = self._docket.default_compression_header
            r = deltautil.delta_compression(default_comp, deltainfo)
            compression_mode, deltainfo = r

        sidedata_compression_mode = COMP_MODE_INLINE
        if sidedata and self.feature_config.has_side_data:
            sidedata_compression_mode = COMP_MODE_PLAIN
            serialized_sidedata = sidedatautil.serialize_sidedata(sidedata)
            sidedata_offset = self._docket.sidedata_end
            h, comp_sidedata = self._inner.compress(serialized_sidedata)
            if (
                h != b'u'
                and comp_sidedata[0:1] != b'\0'
                and len(comp_sidedata) < len(serialized_sidedata)
            ):
                assert not h
                if (
                    comp_sidedata[0:1]
                    == self._docket.default_compression_header
                ):
                    sidedata_compression_mode = COMP_MODE_DEFAULT
                    serialized_sidedata = comp_sidedata
                else:
                    sidedata_compression_mode = COMP_MODE_INLINE
                    serialized_sidedata = comp_sidedata
        else:
            serialized_sidedata = b""
            # Don't store the offset if the sidedata is empty, that way
            # we can easily detect empty sidedata and they will be no different
            # than ones we manually add.
            sidedata_offset = 0

        # drop previouly existing flags
        flags &= ~REVIDX_DELTA_IS_SNAPSHOT
        if self.delta_config.delta_info and deltainfo.snapshotdepth is not None:
            flags |= REVIDX_DELTA_IS_SNAPSHOT

        rank = RANK_UNKNOWN
        if self.feature_config.compute_rank:
            if (p1r, p2r) == (nullrev, nullrev):
                rank = 1
            elif p1r != nullrev and p2r == nullrev:
                rank = 1 + self.fast_rank(p1r)
            elif p1r == nullrev and p2r != nullrev:
                rank = 1 + self.fast_rank(p2r)
            else:  # merge node
                if rustdagop is not None and self.index.rust_ext_compat:
                    rank = rustdagop.rank(self.index, p1r, p2r)
                else:
                    pmin, pmax = sorted((p1r, p2r))
                    rank = 1 + self.fast_rank(pmax)
                    rank += sum(1 for _ in self.findmissingrevs([pmax], [pmin]))

        e = revlogutils.entry(
            flags=flags,
            data_offset=offset,
            data_compressed_length=deltainfo.deltalen,
            data_uncompressed_length=textlen,
            data_compression_mode=compression_mode,
            data_delta_base=deltainfo.base,
            link_rev=link,
            parent_rev_1=p1r,
            parent_rev_2=p2r,
            node_id=node,
            sidedata_offset=sidedata_offset,
            sidedata_compressed_length=len(serialized_sidedata),
            sidedata_compression_mode=sidedata_compression_mode,
            rank=rank,
        )

        self.index.append(e)
        entry = self.index.entry_binary(curr)
        if curr == 0 and self._docket is None:
            header = self._format_flags | self._format_version
            header = self.index.pack_header(header)
            entry = header + entry
        self._writeentry(
            transaction,
            entry,
            deltainfo.data,
            link,
            offset,
            serialized_sidedata,
            sidedata_offset,
        )

        if alwayscache and revinfo.btext is None:
            rawtext = deltacomputer.buildtext(revinfo)

        if type(rawtext) is bytes:  # only accept immutable objects
            self._inner._revisioncache = (node, curr, rawtext)
        self._chainbasecache[curr] = deltainfo.chainbase
        return curr

    def _get_data_offset(self, prev):
        """Returns the current offset in the (in-transaction) data file.
        Versions < 2 of the revlog can get this 0(1), revlog v2 needs a docket
        file to store that information: since sidedata can be rewritten to the
        end of the data file within a transaction, you can have cases where, for
        example, rev `n` does not have sidedata while rev `n - 1` does, leading
        to `n - 1`'s sidedata being written after `n`'s data.

        TODO cache this in a docket file before getting out of experimental."""
        if self._docket is None:
            return self.end(prev)
        else:
            return self._docket.data_end

    def _writeentry(
        self,
        transaction,
        entry,
        data,
        link,
        offset,
        sidedata,
        sidedata_offset,
    ):
        # Files opened in a+ mode have inconsistent behavior on various
        # platforms. Windows requires that a file positioning call be made
        # when the file handle transitions between reads and writes. See
        # 3686fa2b8eee and the mixedfilemodewrapper in windows.py. On other
        # platforms, Python or the platform itself can be buggy. Some versions
        # of Solaris have been observed to not append at the end of the file
        # if the file was seeked to before the end. See issue4943 for more.
        #
        # We work around this issue by inserting a seek() before writing.
        # Note: This is likely not necessary on Python 3. However, because
        # the file handle is reused for reads and may be seeked there, we need
        # to be careful before changing this.
        index_end = data_end = sidedata_end = None
        if self._docket is not None:
            index_end = self._docket.index_end
            data_end = self._docket.data_end
            sidedata_end = self._docket.sidedata_end

        files_end = self._inner.write_entry(
            transaction,
            entry,
            data,
            link,
            offset,
            sidedata,
            sidedata_offset,
            index_end,
            data_end,
            sidedata_end,
        )
        self._enforceinlinesize(transaction)
        if self._docket is not None:
            self._docket.index_end = files_end[0]
            self._docket.data_end = files_end[1]
            self._docket.sidedata_end = files_end[2]

        nodemaputil.setup_persistent_nodemap(transaction, self)

    def addgroup(
        self,
        deltas: Iterator[revlogutils.InboundRevision],
        linkmapper,
        transaction,
        alwayscache=False,
        addrevisioncb=None,
        duplicaterevisioncb=None,
        debug_info=None,
        delta_base_reuse_policy=None,
    ):
        """
        add a delta group

        given a set of deltas, add them to the revision log. the
        first delta is against its parent, which should be in our
        log, the rest are against the previous delta.

        If ``addrevisioncb`` is defined, it will be called with arguments of
        this revlog and the node that was added.
        """

        if self._adding_group:
            raise error.ProgrammingError(b'cannot nest addgroup() calls')

        # read the default delta-base reuse policy from revlog config if the
        # group did not specify one.
        if delta_base_reuse_policy is None:
            if (
                self.delta_config.general_delta
                and self.delta_config.lazy_delta_base
            ):
                delta_base_reuse_policy = DELTA_BASE_REUSE_TRY
            else:
                delta_base_reuse_policy = DELTA_BASE_REUSE_NO

        self._adding_group = True
        empty = True
        try:
            with self._writing(transaction):
                write_debug = None
                if self.delta_config.debug_delta:
                    write_debug = transaction._report
                deltacomputer = deltautil.deltacomputer(
                    self,
                    write_debug=write_debug,
                    debug_info=debug_info,
                )
                # loop through our set of deltas
                for data in deltas:
                    rev = self.index.get_rev(data.node)
                    if rev is not None:
                        # this can happen if two branches make the same change
                        self._nodeduplicatecallback(transaction, rev)
                        if duplicaterevisioncb:
                            duplicaterevisioncb(self, rev)
                        empty = False
                        continue

                    for p in (data.p1, data.p2):
                        if not self.index.has_node(p):
                            raise error.LookupError(
                                p, self.radix, _(b'unknown parent')
                            )

                    if not self.index.has_node(data.delta_base):
                        raise error.LookupError(
                            data.delta_base,
                            self.display_id,
                            _(b'unknown delta base'),
                        )

                    baserev = self.rev(data.delta_base)

                    if baserev != nullrev and self.iscensored(baserev):
                        # if base is censored, delta must be full replacement in a
                        # single patch operation
                        hlen = struct.calcsize(b">lll")
                        oldlen = self.rawsize(baserev)
                        newlen = len(data.delta) - hlen
                        if data.delta[:hlen] != mdiff.replacediffheader(
                            oldlen, newlen
                        ):
                            raise error.CensoredBaseError(
                                self.display_id, self.node(baserev)
                            )

                    flags = data.flags or REVIDX_DEFAULT_FLAGS
                    if not data.has_censor_flag and self._peek_iscensored(
                        baserev, data.delta
                    ):
                        flags |= REVIDX_ISCENSORED

                    # We assume consumers of addrevisioncb will want to retrieve
                    # the added revision, which will require a call to
                    # revision(). revision() will fast path if there is a cache
                    # hit. So, we tell _addrevision() to always cache in this case.
                    # We're only using addgroup() in the context of changegroup
                    # generation so the revision data can always be handled as raw
                    # by the flagprocessor.
                    rev = self._addrevision(
                        data.node,
                        # raw text is usually None, but it might have been set
                        # by some pre-processing/checking code.
                        data.raw_text,
                        transaction,
                        linkmapper(data.link_node),
                        data.p1,
                        data.p2,
                        flags,
                        revlogutils.CachedDelta(
                            baserev,
                            data.delta,
                            delta_base_reuse_policy,
                            data.snapshot_level,
                        ),
                        alwayscache=alwayscache,
                        deltacomputer=deltacomputer,
                        sidedata=data.sidedata,
                    )

                    if addrevisioncb:
                        addrevisioncb(self, rev)
                    empty = False
        finally:
            self._adding_group = False
        return not empty

    def iscensored(self, rev):
        """Check if a file revision is censored."""
        if not self.feature_config.censorable:
            return False

        return self.flags(rev) & REVIDX_ISCENSORED

    def _peek_iscensored(self, baserev, delta):
        """Quickly check if a delta produces a censored revision."""
        if not self.feature_config.censorable:
            return False

        return storageutil.deltaiscensored(delta, baserev, self.rawsize)

    def getstrippoint(self, minlink):
        """find the minimum rev that must be stripped to strip the linkrev

        Returns a tuple containing the minimum rev and a set of all revs that
        have linkrevs that will be broken by this strip.
        """
        return storageutil.resolvestripinfo(
            minlink,
            len(self) - 1,
            self.headrevs(),
            self.linkrev,
            self.parentrevs,
        )

    def strip(self, minlink, transaction):
        """truncate the revlog on the first revision with a linkrev >= minlink

        This function is called when we're stripping revision minlink and
        its descendants from the repository.

        We have to remove all revisions with linkrev >= minlink, because
        the equivalent changelog revisions will be renumbered after the
        strip.

        So we truncate the revlog on the first of these revisions, and
        trust that the caller has saved the revisions that shouldn't be
        removed and that it'll re-add them after this truncation.
        """
        if len(self) == 0:
            return

        rev, _ = self.getstrippoint(minlink)
        if rev == len(self):
            return

        # first truncate the files on disk
        data_end = self.start(rev)
        if not self._inline:
            transaction.add(self._datafile, data_end)
            end = rev * self.index.entry_size
        else:
            end = data_end + (rev * self.index.entry_size)

        if self._sidedatafile:
            sidedata_end = self.sidedata_cut_off(rev)
            transaction.add(self._sidedatafile, sidedata_end)

        transaction.add(self._indexfile, end)
        if self._docket is not None:
            # XXX we could, leverage the docket while stripping. However it is
            # not powerfull enough at the time of this comment
            self._docket.index_end = end
            self._docket.data_end = data_end
            self._docket.sidedata_end = sidedata_end
            self._docket.write(transaction, stripping=True)

        # then reset internal state in memory to forget those revisions
        self._chaininfocache = util.lrucachedict(500)
        self._inner.clear_cache()

        del self.index[rev:-1]

    def checksize(self):
        """Check size of index and data files

        return a (dd, di) tuple.
        - dd: extra bytes for the "data" file
        - di: extra bytes for the "index" file

        A healthy revlog will return (0, 0).
        """
        expected = 0
        if len(self):
            expected = max(0, self.end(len(self) - 1))

        try:
            with self._datafp() as f:
                f.seek(0, io.SEEK_END)
                actual = f.tell()
            dd = actual - expected
        except FileNotFoundError:
            dd = 0

        try:
            f = self.opener(self._indexfile)
            f.seek(0, io.SEEK_END)
            actual = f.tell()
            f.close()
            s = self.index.entry_size
            i = max(0, actual // s)
            di = actual - (i * s)
            if self._inline:
                databytes = 0
                for r in self:
                    databytes += max(0, self.length(r))
                dd = 0
                di = actual - len(self) * s - databytes
        except FileNotFoundError:
            di = 0

        return (dd, di)

    def files(self):
        """return list of files that compose this revlog"""
        res = [self._indexfile]
        if self._docket_file is None:
            if not self._inline:
                res.append(self._datafile)
        else:
            res.append(self._docket_file)
            res.extend(self._docket.old_index_filepaths(include_empty=False))
            if self._docket.data_end:
                res.append(self._datafile)
            res.extend(self._docket.old_data_filepaths(include_empty=False))
            if self._docket.sidedata_end:
                res.append(self._sidedatafile)
            res.extend(self._docket.old_sidedata_filepaths(include_empty=False))
        return res

    def emitrevisions(
        self,
        nodes,
        nodesorder=None,
        revisiondata=False,
        assumehaveparentrevisions=False,
        deltamode=repository.CG_DELTAMODE_STD,
        sidedata_helpers=None,
        debug_info=None,
    ):
        if nodesorder not in (b'nodes', b'storage', b'linear', None):
            raise error.ProgrammingError(
                b'unhandled value for nodesorder: %s' % nodesorder
            )

        if nodesorder is None and not self.delta_config.general_delta:
            nodesorder = b'storage'

        if (
            not self._storedeltachains
            and deltamode != repository.CG_DELTAMODE_PREV
        ):
            deltamode = repository.CG_DELTAMODE_FULL

        snaplvl = lambda r: self.snapshotdepth(r) if self.issnapshot(r) else -1

        with self.reading():
            return storageutil.emitrevisions(
                self,
                nodes,
                nodesorder,
                revlogrevisiondelta,
                deltaparentfn=self.deltaparent,
                candeltafn=self._candelta,
                rawsizefn=self.rawsize,
                revdifffn=self.revdiff,
                flagsfn=self.flags,
                deltamode=deltamode,
                revisiondata=revisiondata,
                assumehaveparentrevisions=assumehaveparentrevisions,
                sidedata_helpers=sidedata_helpers,
                debug_info=debug_info,
                snap_lvl_fn=snaplvl,
            )

    DELTAREUSEALWAYS = b'always'
    DELTAREUSESAMEREVS = b'samerevs'
    DELTAREUSENEVER = b'never'

    DELTAREUSEFULLADD = b'fulladd'

    DELTAREUSEALL = {b'always', b'samerevs', b'never', b'fulladd'}

    def clone(
        self,
        tr,
        destrevlog,
        addrevisioncb=None,
        deltareuse=DELTAREUSESAMEREVS,
        forcedeltabothparents=None,
        sidedata_helpers=None,
        hasmeta_change=None,
    ):
        """Copy this revlog to another, possibly with format changes.

        The destination revlog will contain the same revisions and nodes.
        However, it may not be bit-for-bit identical due to e.g. delta encoding
        differences.

        The ``hasmeta_change`` argument can be used by filelog to signal change in the "hasmeta" flag usage:
        - None means no changes,
        - FILELOG_HASMETA_UPGRADE means the flag must be added when needed
        - FILELOG_HASMETA_DOWNGRADE means the flag must be dropped and parent adjusted

        The ``deltareuse`` argument control how deltas from the existing revlog
        are preserved in the destination revlog. The argument can have the
        following values:

        DELTAREUSEALWAYS
           Deltas will always be reused (if possible), even if the destination
           revlog would not select the same revisions for the delta. This is the
           fastest mode of operation.
        DELTAREUSESAMEREVS
           Deltas will be reused if the destination revlog would pick the same
           revisions for the delta. This mode strikes a balance between speed
           and optimization.
        DELTAREUSENEVER
           Deltas will never be reused. This is the slowest mode of execution.
           This mode can be used to recompute deltas (e.g. if the diff/delta
           algorithm changes).
        DELTAREUSEFULLADD
           Revision will be re-added as if their were new content. This is
           slower than DELTAREUSEALWAYS but allow more mechanism to kicks in.
           eg: large file detection and handling.

        Delta computation can be slow, so the choice of delta reuse policy can
        significantly affect run time.

        The default policy (``DELTAREUSESAMEREVS``) strikes a balance between
        two extremes. Deltas will be reused if they are appropriate. But if the
        delta could choose a better revision, it will do so. This means if you
        are converting a non-generaldelta revlog to a generaldelta revlog,
        deltas will be recomputed if the delta's parent isn't a parent of the
        revision.

        In addition to the delta policy, the ``forcedeltabothparents``
        argument controls whether to force compute deltas against both parents
        for merges. By default, the current default is used.

        See `revlogutil.sidedata.get_sidedata_helpers` for the doc on
        `sidedata_helpers`.
        """
        if deltareuse not in self.DELTAREUSEALL:
            raise ValueError(
                _(b'value for deltareuse invalid: %s') % deltareuse
            )

        if len(destrevlog):
            raise ValueError(_(b'destination revlog is not empty'))

        if getattr(self, 'filteredrevs', None):
            raise ValueError(_(b'source revlog has filtered revisions'))
        if getattr(destrevlog, 'filteredrevs', None):
            raise ValueError(_(b'destination revlog has filtered revisions'))

        # lazydelta and lazydeltabase controls whether to reuse a cached delta,
        # if possible.
        old_delta_config = destrevlog.delta_config
        # XXX Changing the deltaconfig of the revlog will not change the config
        # XXX of the inner revlog and even less the config used by Rust, so this
        # XXX overwrite will create problem as soon as the delta computation
        # XXX move at a lower level.
        destrevlog.delta_config = destrevlog.delta_config.copy()

        try:
            if deltareuse == self.DELTAREUSEALWAYS:
                destrevlog.delta_config.lazy_delta_base = True
                destrevlog.delta_config.lazy_delta = True
            elif deltareuse == self.DELTAREUSESAMEREVS:
                destrevlog.delta_config.lazy_delta_base = False
                destrevlog.delta_config.lazy_delta = True
            elif deltareuse == self.DELTAREUSENEVER:
                destrevlog.delta_config.lazy_delta_base = False
                destrevlog.delta_config.lazy_delta = False

            delta_both_parents = (
                forcedeltabothparents or old_delta_config.delta_both_parents
            )
            destrevlog.delta_config.delta_both_parents = delta_both_parents

            with self.reading(), destrevlog._writing(tr):
                self._clone(
                    tr,
                    destrevlog,
                    addrevisioncb,
                    deltareuse,
                    forcedeltabothparents,
                    sidedata_helpers,
                    hasmeta_change=hasmeta_change,
                )

        finally:
            destrevlog.delta_config = old_delta_config

    def _clone(
        self,
        tr,
        destrevlog,
        addrevisioncb,
        deltareuse,
        forcedeltabothparents,
        sidedata_helpers,
        hasmeta_change,
    ):
        """perform the core duty of `revlog.clone` after parameter processing"""
        write_debug = None
        if self.delta_config.debug_delta:
            write_debug = tr._report
        deltacomputer = deltautil.deltacomputer(
            destrevlog,
            write_debug=write_debug,
        )
        index = self.index

        has_meta_cache = {}

        for rev in self:
            entry = index[rev]

            # Some classes override linkrev to take filtered revs into
            # account. Use raw entry from index.
            flags = entry[0] & 0xFFFF
            linkrev = entry[4]
            p1 = index[entry[5]][7]
            p2 = index[entry[6]][7]
            node = entry[7]

            if hasmeta_change == HM_DOWN and flags & REVIDX_HASMETA:
                p1, p2 = p2, p1
                flags &= ~REVIDX_HASMETA
            if hasmeta_change == HM_UP:
                delta = self._inner._chunk(rev)

                delta_parent = self.deltaparent(rev)

                has_base = delta_parent >= 0

                hm = rewrite.delta_has_meta(delta, has_base)
                if hm == rewrite.HM_META:
                    rev_has_meta = True
                elif hm == rewrite.HM_NO_META:
                    rev_has_meta = False
                elif (
                    hm == rewrite.HM_INHERIT and delta_parent in has_meta_cache
                ):
                    rev_has_meta = has_meta_cache[delta_parent]
                else:
                    try:
                        revdata = self._revisiondata(
                            rev,
                            validate=False,
                        )
                    except error.CensoredNodeError:
                        rev_has_meta = False
                    else:
                        rev_has_meta = revdata[:META_MARKER_SIZE] == META_MARKER

                has_meta_cache[rev] = rev_has_meta
                if rev_has_meta:
                    flags |= REVIDX_HASMETA
                else:
                    flags &= ~REVIDX_HASMETA

                # We no longer use parent ordering as a trick, so order them
                # back to something less surprising.
                if p1 == nullrev and p2 != nullrev:
                    p1, p2 = p2, p1

            # We will let the encoding decide what is a snapshot
            #
            # The cached delta hold information about it being a snapshot, so
            # that information will be preserved if the a cached delta for a
            # snapshot is reused.
            flags &= ~REVIDX_DELTA_IS_SNAPSHOT

            # (Possibly) reuse the delta from the revlog if allowed and
            # the revlog chunk is a delta.
            cachedelta = None
            rawtext = None
            if deltareuse == self.DELTAREUSEFULLADD:
                text = self._revisiondata(rev)
                sidedata = self.sidedata(rev)

                if sidedata_helpers is not None:
                    (sidedata, new_flags) = sidedatautil.run_sidedata_helpers(
                        self, sidedata_helpers, sidedata, rev
                    )
                    flags = flags | new_flags[0] & ~new_flags[1]

                destrevlog.addrevision(
                    text,
                    tr,
                    linkrev,
                    p1,
                    p2,
                    cachedelta=cachedelta,
                    node=node,
                    flags=flags,
                    deltacomputer=deltacomputer,
                    sidedata=sidedata,
                )
            else:
                if destrevlog.delta_config.lazy_delta:
                    if (
                        self.delta_config.general_delta
                        and self.delta_config.lazy_delta_base
                    ):
                        delta_base_reuse = DELTA_BASE_REUSE_TRY
                    else:
                        delta_base_reuse = DELTA_BASE_REUSE_NO

                    if self.issnapshot(rev):
                        snapshotdepth = self.snapshotdepth(rev)
                    else:
                        snapshotdepth = -1
                    dp = self.deltaparent(rev)
                    if dp != nullrev:
                        cachedelta = revlogutils.CachedDelta(
                            dp,
                            bytes(self._inner._chunk(rev)),
                            delta_base_reuse,
                            snapshotdepth,
                        )

                sidedata = None
                if cachedelta is None:
                    try:
                        rawtext = self._revisiondata(rev, validate=False)
                    except error.CensoredNodeError as censored:
                        assert flags & REVIDX_ISCENSORED
                        rawtext = censored.tombstone
                    sidedata = self.sidedata(rev)
                if sidedata is None:
                    sidedata = self.sidedata(rev)

                if sidedata_helpers is not None:
                    (sidedata, new_flags) = sidedatautil.run_sidedata_helpers(
                        self, sidedata_helpers, sidedata, rev
                    )
                    flags = flags | new_flags[0] & ~new_flags[1]

                destrevlog._addrevision(
                    node,
                    rawtext,
                    tr,
                    linkrev,
                    p1,
                    p2,
                    flags,
                    cachedelta,
                    deltacomputer=deltacomputer,
                    sidedata=sidedata,
                )

            if addrevisioncb:
                addrevisioncb(self, rev, node)

    def censorrevision(self, tr, censor_nodes, tombstone=b''):
        if self._format_version == REVLOGV0:
            raise error.RevlogError(
                _(b'cannot censor with version %d revlogs')
                % self._format_version
            )
        elif self._format_version == REVLOGV1:
            rewrite.v1_censor(self, tr, censor_nodes, tombstone)
        else:
            rewrite.v2_censor(self, tr, censor_nodes, tombstone)

    def verifyintegrity(self, state) -> Iterable[repository.iverifyproblem]:
        """Verifies the integrity of the revlog.

        Yields ``revlogproblem`` instances describing problems that are
        found.
        """
        dd, di = self.checksize()
        if dd:
            yield revlogproblem(error=_(b'data length off by %d bytes') % dd)
        if di:
            yield revlogproblem(error=_(b'index contains %d extra bytes') % di)

        version = self._format_version

        # The verifier tells us what version revlog we should be.
        if version != state[b'expectedversion']:
            yield revlogproblem(
                warning=_(b"warning: '%s' uses revlog format %d; expected %d")
                % (self.display_id, version, state[b'expectedversion'])
            )

        state[b'skipread'] = set()
        state[b'safe_renamed'] = set()

        for rev in self:
            node = self.node(rev)

            # Verify contents. 4 cases to care about:
            #
            #   common: the most common case
            #   rename: with a rename
            #   meta: file content starts with b'\1\n', the metadata
            #         header defined in filelog.py, but without a rename
            #   ext: content stored externally
            #
            # More formally, their differences are shown below:
            #
            #                       | common | rename | meta  | ext
            #  -------------------------------------------------------
            #   flags()             | 0      | 0      | 0     | not 0
            #   renamed()           | False  | True   | False | ?
            #   rawtext[0:2]=='\1\n'| False  | True   | True  | ?
            #
            # "rawtext" means the raw text stored in revlog data, which
            # could be retrieved by "rawdata(rev)". "text"
            # mentioned below is "revision(rev)".
            #
            # There are 3 different lengths stored physically:
            #  1. L1: rawsize, stored in revlog index
            #  2. L2: len(rawtext), stored in revlog data
            #  3. L3: len(text), stored in revlog data if flags==0, or
            #     possibly somewhere else if flags!=0
            #
            # L1 should be equal to L2. L3 could be different from them.
            # "text" may or may not affect commit hash depending on flag
            # processors (see flagutil.addflagprocessor).
            #
            #              | common  | rename | meta  | ext
            # -------------------------------------------------
            #    rawsize() | L1      | L1     | L1    | L1
            #       size() | L1      | L2-LM  | L1(*) | L1 (?)
            # len(rawtext) | L2      | L2     | L2    | L2
            #    len(text) | L2      | L2     | L2    | L3
            #  len(read()) | L2      | L2-LM  | L2-LM | L3 (?)
            #
            # LM:  length of metadata, depending on rawtext
            # (*): not ideal, see comment in filelog.size
            # (?): could be "- len(meta)" if the resolved content has
            #      rename metadata
            #
            # Checks needed to be done:
            #  1. length check: L1 == L2, in all cases.
            #  2. hash check: depending on flag processor, we may need to
            #     use either "text" (external), or "rawtext" (in revlog).

            try:
                skipflags = state.get(b'skipflags', 0)
                if skipflags:
                    skipflags &= self.flags(rev)

                _verify_revision(self, skipflags, state, node)

                l1 = self.rawsize(rev)
                l2 = len(self.rawdata(node))

                if l1 != l2:
                    yield revlogproblem(
                        error=_(b'unpacked size is %d, %d expected') % (l2, l1),
                        node=node,
                    )

            except error.CensoredNodeError:
                if state[b'erroroncensored']:
                    yield revlogproblem(
                        error=_(b'censored file data'), node=node
                    )
                    state[b'skipread'].add(node)
            except Exception as e:
                yield revlogproblem(
                    error=_(b'unpacking %s: %s')
                    % (short(node), stringutil.forcebytestr(e)),
                    node=node,
                )
                state[b'skipread'].add(node)

    def storageinfo(
        self,
        exclusivefiles=False,
        sharedfiles=False,
        revisionscount=False,
        trackedsize=False,
        storedsize=False,
    ):
        d = {}

        if exclusivefiles:
            d[b'exclusivefiles'] = [(self.opener, self._indexfile)]
            if not self._inline:
                d[b'exclusivefiles'].append((self.opener, self._datafile))

        if sharedfiles:
            d[b'sharedfiles'] = []

        if revisionscount:
            d[b'revisionscount'] = len(self)

        if trackedsize:
            d[b'trackedsize'] = sum(map(self.rawsize, iter(self)))

        if storedsize:
            d[b'storedsize'] = sum(
                self.opener.stat(path).st_size for path in self.files()
            )

        return d

    def rewrite_sidedata(self, transaction, helpers, startrev, endrev):
        if not self.feature_config.has_side_data:
            return
        # revlog formats with sidedata support does not support inline
        assert not self._inline
        if not helpers[1] and not helpers[2]:
            # Nothing to generate or remove
            return

        new_entries = []
        # append the new sidedata
        with self._writing(transaction):
            ifh, dfh, sdfh = self._inner._writinghandles
            dfh.seek(self._docket.sidedata_end, os.SEEK_SET)

            current_offset = sdfh.tell()
            for rev in range(startrev, endrev + 1):
                entry = self.index[rev]
                new_sidedata, flags = sidedatautil.run_sidedata_helpers(
                    store=self,
                    sidedata_helpers=helpers,
                    sidedata={},
                    rev=rev,
                )

                serialized_sidedata = sidedatautil.serialize_sidedata(
                    new_sidedata
                )

                sidedata_compression_mode = COMP_MODE_INLINE
                if serialized_sidedata and self.feature_config.has_side_data:
                    sidedata_compression_mode = COMP_MODE_PLAIN
                    h, comp_sidedata = self._inner.compress(serialized_sidedata)
                    if (
                        h != b'u'
                        and comp_sidedata[0] != b'\0'
                        and len(comp_sidedata) < len(serialized_sidedata)
                    ):
                        assert not h
                        if (
                            comp_sidedata[0]
                            == self._docket.default_compression_header
                        ):
                            sidedata_compression_mode = COMP_MODE_DEFAULT
                            serialized_sidedata = comp_sidedata
                        else:
                            sidedata_compression_mode = COMP_MODE_INLINE
                            serialized_sidedata = comp_sidedata
                if entry[8] != 0 or entry[9] != 0:
                    # rewriting entries that already have sidedata is not
                    # supported yet, because it introduces garbage data in the
                    # revlog.
                    msg = b"rewriting existing sidedata is not supported yet"
                    raise error.Abort(msg)

                # Apply (potential) flags to add and to remove after running
                # the sidedata helpers
                new_offset_flags = entry[0] | flags[0] & ~flags[1]
                entry_update = (
                    current_offset,
                    len(serialized_sidedata),
                    new_offset_flags,
                    sidedata_compression_mode,
                )

                # the sidedata computation might have move the file cursors around
                sdfh.seek(current_offset, os.SEEK_SET)
                sdfh.write(serialized_sidedata)
                new_entries.append(entry_update)
                current_offset += len(serialized_sidedata)
                self._docket.sidedata_end = sdfh.tell()

            # rewrite the new index entries
            ifh.seek(startrev * self.index.entry_size)
            for i, e in enumerate(new_entries):
                rev = startrev + i
                self.index.replace_sidedata_info(
                    rev, *e
                )  # pytype: disable=attribute-error
                packed = self.index.entry_binary(rev)
                if rev == 0 and self._docket is None:
                    header = self._format_flags | self._format_version
                    header = self.index.pack_header(header)
                    packed = header + packed
                ifh.write(packed)
