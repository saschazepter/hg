# inner_revlog.py: pure python implementation of some revlog inner details
#
# Copyright 2023-2025 Octobus <contact@octobus.net>
"""The python implementation for the Inner revlog"""

from __future__ import annotations

import binascii
import contextlib
import os
import typing
import zlib

from typing import (
    cast,
)

# import stuff from node for others to import from revlog
from ..node import (
    nullrev,
)
from ..i18n import _
from ..interfaces.types import (
    RevnumT,
)
from ..revlogutils.constants import (
    COMP_MODE_DEFAULT,
    COMP_MODE_INLINE,
    COMP_MODE_PLAIN,
    KIND_MANIFESTLOG,
    REVIDX_DELTA_IS_SNAPSHOT,
)
from ..interfaces import compression as i_comp

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    from ..pure.parsers import BaseIndexObject

from .. import (
    error,
    mdiff,
    util,
    vfs as vfsmod,
)
from ..revlogutils import (
    deltas as deltautil,
    randomaccessfile,
    sidedata as sidedatautil,
)
from ..utils import (
    stringutil,
)


# Aliased for performance.
_zlibdecompress = zlib.decompress

FILE_TOO_SHORT_MSG = _(
    b'cannot read from revlog %s;'
    b'  expected %d bytes from offset %d, data size is %d'
)


class InnerRevlog:
    """An inner layer of the revlog object

    That layer exist to be able to delegate some operation to Rust, its
    boundaries are arbitrary and based on what we can delegate to Rust.
    """

    has_revdiff_extra = False
    """does this inner revlog support revdiff with an extra patch"""

    opener: vfsmod.vfs
    _default_compression_header: i_comp.RevlogCompHeader

    def __init__(
        self,
        opener: vfsmod.vfs,
        target: tuple[int, bytes],
        index,
        index_file,
        data_file,
        sidedata_file,
        inline,
        data_config,
        delta_config,
        feature_config,
        chunk_cache,
        default_compression_header: i_comp.RevlogCompHeader,
    ):
        self.opener = opener
        self.target = target
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

        if target[0] == KIND_MANIFESTLOG:
            self._diff_fn = mdiff.manifest_diff
        else:
            self._diff_fn = mdiff.storage_diff

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
        self._decompressors: dict[
            i_comp.RevlogCompHeader, i_comp.IRevlogCompressor
        ] = {}
        # 3-tuple of (rev, text, validated) for a raw revision.
        self._revision_cache: tuple[RevnumT, bytes, bool] = None

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
        self._revision_cache = None
        if self._uncompressed_chunk_cache is not None:
            self._uncompressed_chunk_cache.clear()
        self._segmentfile.clear_cache()
        self._segmentfile_sidedata.clear_cache()

    def seen_file_size(self, size):
        """signal that we have seen a file this big

        This might update the limit of underlying cache."""
        if self._uncompressed_chunk_cache is not None:
            factor = self.data_config.uncompressed_cache_factor
            candidate_size = size * factor
            if candidate_size > self._uncompressed_chunk_cache.maxcost:
                self._uncompressed_chunk_cache.maxcost = candidate_size

    def record_uncompressed_chunk(self, rev, u_data):
        """Record the uncompressed raw chunk for rev

        This is a noop if the cache is disabled."""
        if self._uncompressed_chunk_cache is not None:
            self._uncompressed_chunk_cache.insert(
                rev,
                u_data,
                cost=len(u_data),
            )

    def cache_revision_text(self, rev: RevnumT, data: bytes, validated: bool):
        """cache the full text of a revision (validated or not)"""
        if (
            self._revision_cache is None
            or self._revision_cache[0] != rev
            or not self._revision_cache[2]
        ):
            self._revision_cache = (rev, data, validated)

    def get_cached_text(
        self,
        rev: RevnumT,
    ) -> tuple[RevnumT, bytes, bool] | None:
        """return a cached value for this revision

        Return None if no value are found.
        Return (rev, text, validated) if a value is found.
        """
        assert rev is not None
        cache = self._revision_cache
        if cache is not None and cache[0] == rev:
            return cache

    def clear_cached_text(self, rev: RevnumT):
        """drop cached text for a revision"""
        cache = self._revision_cache
        if cache is not None and cache[0] == rev:
            self._revision_cache = None

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
        return self.index.data_chunk_start(rev)

    def length(self, rev):
        """the length of the data chunk for this revision"""
        return self.index.data_chunk_length(rev)

    def end(self, rev):
        """the end of the data chunk for this revision"""
        return self.start(rev) + self.length(rev)

    def deltaparent(self, rev):
        """return deltaparent of the given revision"""
        base = self.index.delta_base(rev)
        if base is None:
            base = nullrev
        return base

    def issnapshot(self, rev):
        """tells whether rev is a snapshot"""
        if not self.delta_config.sparse_revlog:
            return self.deltaparent(rev) == nullrev
        elif hasattr(self.index, 'issnapshot'):
            # directly assign the method to cache the testing and access
            self.issnapshot = self.index.issnapshot
            return self.issnapshot(rev)
        elif self.data_config.delta_info:
            flags = self.index.flags(rev)
            return flags & REVIDX_DELTA_IS_SNAPSHOT
        if rev == nullrev:
            return True
        idx = self.index
        base = idx.delta_base(rev)
        if base is None or base == nullrev:
            # the base == nullrev was possible in older version and some
            # repository exist in the wild with such delta
            return True
        p1, p2 = idx.parents(rev)
        while p1 is not None and self.length(p1) == 0:
            b = idx.delta_base(p1)
            p1 = b
        while p2 is not None and self.length(p2) == 0:
            b = idx.delta_base(p2)
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
        return self.index.deltachain(rev, stoprev)

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

    def _get_decompressor(
        self,
        t: i_comp.RevlogCompHeader,
    ) -> i_comp.IRevlogCompressor:
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

        compressor = self._get_decompressor(cast(i_comp.RevlogCompHeader, t))

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
        start = index.data_chunk_start(startrev)
        if startrev == endrev:
            end = start + index.data_chunk_length(startrev)
        else:
            end = index.data_chunk_start(endrev)
            end += index.data_chunk_length(endrev)

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

        compression_mode = self.index.data_chunk_compression_mode(rev)
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
                inlined=self.inline,
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
                comp_mode = self.index.data_chunk_compression_mode(rev)
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

    def raw_text(self, rev: RevnumT) -> tuple[RevnumT, bytes, bool]:
        """return the possibly unvalidated rawtext for a revision

        returns rawtext
        """
        if rev == nullrev:
            return (rev, b'', True)

        # revision in the cache (could be useful to apply delta)
        cachedrev = None
        # An intermediate text to apply deltas to
        basetext = None

        # Check if we have the entry in cache
        # The cache entry looks like (rev, rawtext, validated)
        cache = self._revision_cache
        if cache is not None:
            if cachedrev == rev:
                return cache
            cachedrev = cache[0]

        chain, stopped = self._deltachain(rev, stoprev=cachedrev)
        if stopped:
            basetext = cache[1]

        targetsize = None
        rawsize = self.index.raw_size(rev)
        if rawsize is not None and 0 <= rawsize:
            targetsize = 4 * rawsize

        self.seen_file_size(rawsize)

        bins = self._chunks(chain, targetsize=targetsize)
        if basetext is None:
            basetext = bytes(bins[0])
            bins = bins[1:]
        if bins:
            rawtext = mdiff.patches(basetext, bins)
            del basetext  # let us have a chance to free memory early
        else:
            rawtext = basetext

        self.cache_revision_text(rev, rawtext, False)
        return (rev, rawtext, False)

    def rev_diff(
        self,
        rev_1: RevnumT,
        rev_2: RevnumT,
        extra_delta: bytes | None = None,
    ) -> bytes:
        """return the diff between two revisions

        The revision are expected to have nothing altering them (censoring,
        flag processors, ...) (at least until the inner revlog has the tool to
        be responsible for them)
        """
        if extra_delta is not None:
            msg = b"no support for rev_diff with extra_delta in Python"
            raise error.ProgrammingError(msg)
        return self._diff_fn(
            self.raw_text(rev_1)[1],
            self.raw_text(rev_2)[1],
        )

    def sidedata(self, rev, sidedata_end):
        """Return the sidedata for a given revision number."""
        sidedata_offset = self.index.sidedata_chunk_offset(rev)
        sidedata_size = self.index.sidedata_chunk_length(rev)

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

        comp = self.index.sidedata_chunk_compression_mode(rev)
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
