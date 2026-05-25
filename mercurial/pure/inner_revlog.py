# inner_revlog.py: pure python implementation of some revlog inner details
#
# Copyright 2023-2025 Octobus <contact@octobus.net>
"""The python implementation for the Inner revlog"""

from __future__ import annotations

import abc
import binascii
import collections
import contextlib
import io
import os
import typing
import zlib

from typing import (
    Callable,
    Iterator,
    Mapping,
    cast,
)

# import stuff from node for others to import from revlog
from ..node import (
    nullrev,
)
from ..i18n import _
from ..interfaces.types import (
    HgPathT,
    RevnumT,
    TransactionT,
)
from ..revlogutils.constants import (
    COMP_MODE_DEFAULT,
    COMP_MODE_INLINE,
    COMP_MODE_PLAIN,
    KIND_FILELOG,
    KIND_MANIFESTLOG,
    REVIDX_DELTA_IS_SNAPSHOT,
    STR_SPLIT,
    V2FileType,
)
from ..interfaces import compression as i_comp

from ..revlogutils import (
    docket as docket_mod,
)

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    from ..pure.parsers import (
        BaseIndex,
        Index2,
        MonoBlockIndex,
    )

    # TODO: Change to Buffer for 3.14+ support
    from collections.abc import ByteString

from .. import (
    error,
    mdiff,
    revlogutils,
    util,
    vfs as vfsmod,
)
from ..revlogutils import (
    config as revlog_config,
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


class CorruptedRevlogError(error.RevlogError):
    ...


class BaseInnerRevlog(abc.ABC):
    """An inner layer of the revlog object

    That layer exist to be able to delegate some operation to Rust, its
    boundaries are arbitrary and based on what we can delegate to Rust.
    """

    docket = None
    has_revdiff_extra = False
    """does this inner revlog support revdiff with an extra patch"""

    opener: vfsmod.vfs
    index: BaseIndex

    support_extended_data: bool
    """True if the storage support more than just storing data"""

    def __init__(
        self,
        opener: vfsmod.vfs,
        target: tuple[int, bytes],
        index,
        segment_file,
        inline,
        configs: revlog_config.RevlogConfigs,
    ):
        self.opener = opener
        self.target = target
        self.index = index

        self.inline = inline
        self.data_config = configs.data
        self.delta_config = configs.delta
        self.feature_config = configs.feature

        if target[0] == KIND_MANIFESTLOG:
            self._diff_fn = mdiff.manifest_diff
        else:
            self._diff_fn = mdiff.storage_diff

        # index

        # tuple of file handles being used for active writing.
        self._writinghandles = None

        self._segmentfile = segment_file

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

    def __len__(self):
        return len(self.index)

    @abc.abstractmethod
    def check_size(self) -> tuple[int, int]:
        """Check size of index and data files

        return a (dd, di) tuple.
        - dd: extra bytes for the "data" file
        - di: extra bytes for the "index" file

        A healthy revlog will return (0, 0).
        """

    @abc.abstractmethod
    def files(self, include_old: bool = True) -> list[HgPathT]:
        """return list of files that compose this revlog"""

    def clear_cache(self):
        assert not self.is_delaying
        self._revision_cache = None
        if self._uncompressed_chunk_cache is not None:
            self._uncompressed_chunk_cache.clear()
        self._segmentfile.clear_cache()

    def seen_file_size(self, size: int):
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
    def is_delaying(self):
        """is the revlog is currently delaying the visibility of written data?

        The delaying mechanism can be either in-memory or written on disk in a
        side-file."""
        return False

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
        return None

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
        """Context manager that keeps files open for reading"""
        if len(self.index) == 0:
            yield  # nothing to be read
        else:
            with self._reading():
                yield

    @contextlib.contextmanager
    def _reading(self):
        with self._segmentfile.reading():
            yield

    @property
    def is_writing(self):
        """True is a writing context is open"""
        return self._writinghandles is not None

    @property
    def is_open(self):
        """True if any file handle is being held

        Used for assert and debug in the python code"""
        return self._segmentfile.is_open

    @contextlib.contextmanager
    def writing(self, transaction):
        """Open the revlog files for writing

        Add content to a revlog should be done within such context.
        """
        if self.is_writing:
            yield
        else:
            with self._writing(transaction):
                yield

    @contextlib.contextmanager
    @abc.abstractmethod
    def _writing(self, transaction):
        ...

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
                    chunkstart += (rev + 1) * self.index.entry_size
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
        if rawsize is not None:
            assert rawsize >= 0
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

    def sidedata(self, rev):
        """Return the sidedata for a given revision number."""
        return {}

    def changed_files_bytes(self, rev: RevnumT) -> bytes:
        """Serialized ChangedFiles data for this revision

        If the inner-revlog doesn't store that information, always return the
        serialization of an empty ChangedFiles.
        """
        return b""

    def sts_splits(self, rev: RevnumT) -> list[tuple[RevnumT, int]]:
        raise error.ProgrammingError("lacking stable-tail support")

    def add_changed_files(
        self,
        transaction: TransactionT,
        data_iter: Iterator[tuple[RevnumT, bool, bytes]],
    ):
        """Update the ChangedFiles information of a series of revision

        Only relevant for inner revlog that support ChangedFiles.
        """
        raise error.ProgrammingError("lacking support for ChangedFils data")

    @abc.abstractmethod
    def next_data_offset(self):
        """Returns the current offset in the (in-transaction) data file."""

    @abc.abstractmethod
    def add_entry(
        self,
        transaction: TransactionT,
        entry: revlogutils.RevlogEntry,
        data: bytes,
        link: RevnumT,
        other_data: dict[V2FileType, bytes] | None,
    ):
        ...

    def delay(self):
        raise error.ProgrammingError("Cannot delay a non-V1 revlog")

    def write_pending(self):
        raise error.ProgrammingError("Cannot write_pending a non-V1 revlog")

    def finalize_pending(self):
        raise error.ProgrammingError("Cannot finalize_pending a non-V1 revlog")

    def rewrite_sidedata(self, transaction: TransactionT, new_info):
        raise error.ProgrammingError(b"rewriting sidedata without support")

    def strip_after(self, transaction, rev, min_link):
        """truncate the revlog on the first revision with a linkrev >= minlink

        It remove all revisions after `rev`."""
        if not self._strip_affected(rev, min_link):
            return

        # first truncate the files on disk
        self._strip_after(transaction, rev, min_link)

        # then reset internal state in memory to forget those revisions
        self.clear_cache()
        if rev < len(self):
            del self.index[rev:-1]

    def _strip_affected(self, rev: RevnumT, min_link: RevnumT) -> bool:
        """is there any work to do in this revlog for a strip"""
        return rev < len(self)

    @abc.abstractmethod
    def _strip_after(self, transaction, rev, min_link):
        ...


class InnerRevlogV1(BaseInnerRevlog):
    """A inner revlog for a revlog-v1 revlog"""

    support_extended_data: bool = False

    index: MonoBlockIndex

    def __init__(
        self,
        opener: vfsmod.vfs,
        target: tuple[int, bytes],
        index_header: int,
        index_data,
        index_file,
        index_parser,
        data_file,
        inline,
        configs: revlog_config.RevlogConfigs,
    ):
        try:
            index, chunk_cache = index_parser(
                index_data,
                inline,
                configs.delta.general_delta,
                configs.delta.delta_info,
            )
        except (ValueError, IndexError):
            raise CorruptedRevlogError(b"corrupted index")

        segment_file = randomaccessfile.randomaccessfile(
            opener,
            index_file if inline else data_file,
            configs.data.chunk_cache_size,
            chunk_cache,
        )

        super().__init__(
            opener=opener,
            target=target,
            index=index,
            segment_file=segment_file,
            inline=inline,
            configs=configs,
        )
        # used during diverted write.
        self.index_file = index_file
        self.data_file = data_file
        self._orig_index_file = None
        self._delay_buffer = None
        self._index_header = index_header

    def check_size(self) -> tuple[int, int]:
        """Check size of index and data files

        return a (dd, di) tuple.
        - dd: extra bytes for the "data" file
        - di: extra bytes for the "index" file

        A healthy revlog will return (0, 0).
        """
        expected_data = 0
        if len(self):
            expected_data = max(0, self.end(len(self) - 1))
        excepted_index = len(self) * self.index.entry_size

        try:
            with self.opener(self.data_file) as f:
                f.seek(0, io.SEEK_END)
                dd = f.tell()
        except FileNotFoundError:
            dd = 0
        if not self.inline:
            dd -= expected_data

        try:
            with self.opener(self.index_file) as f:
                f.seek(0, io.SEEK_END)
                di = f.tell()
        except FileNotFoundError:
            di = 0
        di -= excepted_index
        if self.inline:
            di -= expected_data

        return (dd, di)

    def files(self, include_old: bool = True) -> list[HgPathT]:
        """return list of files that compose this revlog"""
        res = [self.index_file]
        if not self.inline:
            res.append(self.data_file)
        return res

    @contextlib.contextmanager
    def _reading(self):
        if self.is_delaying and self.inline:
            msg = "revlog with delayed write should not be inline"
            raise error.ProgrammingError(msg)
        with super()._reading():
            yield

    @contextlib.contextmanager
    def _writing(self, transaction):
        ifh = dfh = None
        try:
            r = len(self.index)
            # opening the data file.
            dsize = 0
            if r:
                dsize = self.end(r - 1)
            dfh = None
            if not self.inline:
                dfh = self.opener.wopen(self.data_file)
                dfh.seek(0, os.SEEK_END)
                transaction.add(self.data_file, dsize)
            # opening the index file.
            isize = r * self.index.entry_size
            ifh = self._index_write_fp()
            if self.inline:
                transaction.add(self.index_file, dsize + isize)
            else:
                transaction.add(self.index_file, isize)
            # exposing all file handle for writing.
            self._writinghandles = (ifh, dfh)
            self._segmentfile.writing_handle = ifh if self.inline else dfh
            yield
        finally:
            self._writinghandles = None
            self._segmentfile.writing_handle = None
            if dfh is not None:
                dfh.close()
            # closing the index file last to avoid exposing referent to
            # potential unflushed data content.
            if ifh is not None:
                ifh.close()

    def _index_write_fp(self, index_end=None):
        """internal method to open the index file for writing

        You should not use this directly and use `_writing` instead
        """
        if index_end is not None:
            raise error.ProgrammingError("index_end not None for v1")
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
            f.seek(0, os.SEEK_END)
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

    def next_data_offset(self):
        """Returns the current offset in the (in-transaction) data file."""
        return self.end(len(self.index) - 1)

    def add_entry(
        self,
        transaction: TransactionT,
        entry: revlogutils.RevlogEntry,
        data: bytes,
        link: RevnumT,
        other_data: dict[V2FileType, bytes] | None,
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
        assert other_data is None, other_data
        ifh, dfh = self._writinghandles
        ifh.seek(0, os.SEEK_END)
        if dfh:
            dfh.seek(0, os.SEEK_END)

        offset = self.next_data_offset()

        curr = len(self.index)
        self.index.add_entry(entry)
        bin_entry = self.index.entry_binary(curr)
        if curr == 0:
            header = self.index.pack_header(self._index_header)
            bin_entry = header + bin_entry

        if not self.inline:
            transaction.add(self.data_file, offset)
            transaction.add(self.canonical_index_file, curr * len(bin_entry))
            if data[0]:
                dfh.write(data[0])
            dfh.write(data[1])
            if self._delay_buffer is None:
                ifh.write(bin_entry)
            else:
                self._delay_buffer.append(bin_entry)
        elif self._delay_buffer is not None:
            msg = b'invalid delayed write on inline revlog'
            raise error.ProgrammingError(msg)
        else:
            offset += curr * self.index.entry_size
            transaction.add(self.canonical_index_file, offset)
            ifh.write(bin_entry)
            ifh.write(data[0])
            ifh.write(data[1])

    @property
    def canonical_index_file(self):
        if self._orig_index_file is not None:
            return self._orig_index_file
        return self.index_file

    def _index_new_fp(self):
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
            with self._index_new_fp() as fp:
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
                ifh = self._index_write_fp()
                self._writinghandles = (ifh, new_dfh)
                self._segmentfile.writing_handle = new_dfh
                new_dfh = None
                # No need to deal with sidedata writing handle as it is only
                # relevant with revlog-v2 which is never inline, not reaching
                # this code
        finally:
            if new_dfh is not None:
                new_dfh.close()
        self._index_header = header
        return self.index_file

    @property
    def is_delaying(self):
        """is the revlog is currently delaying the visibility of written data?

        The delaying mechanism can be either in-memory or written on disk in a
        side-file."""
        return (self._delay_buffer is not None) or (
            self._orig_index_file is not None
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

    def _strip_after(self, transaction, rev, min_link):
        """truncate the revlog on the first revision with a linkrev >= minlink

        It remove all revisions after `rev`."""
        # first truncate the files on disk
        end = rev * self.index.entry_size
        data_end = self.start(rev)

        if self.inline:
            end += data_end
        else:
            transaction.add(self.data_file, data_end)
        transaction.add(self.index_file, end)


IDX_TOO_SHORT = _(b'too few index bytes for %s %s: got %d, expected %d')

if typing.TYPE_CHECKING:
    _ChildrenUpdateT = Mapping[RevnumT, list[RevnumT | None]]


class InnerRevlogV2(BaseInnerRevlog):
    """A inner revlog for a revlog-v2 revlog"""

    index: Index2

    support_extended_data: bool = True

    _default_compression_header: i_comp.RevlogCompHeader

    @util.propertycache
    def _active_fts(self) -> tuple[V2FileType]:
        return self.docket.active_fts

    @util.propertycache
    def _index_fts(self) -> tuple[V2FileType]:
        return self.docket.index_fts

    def __init__(
        self,
        *,
        opener: vfsmod.vfs,
        radix: bytes,
        target: tuple[int, bytes],
        docket: docket_mod.RevlogDocket,
        index_parser: Callable[[tuple[ByteString, ...]], Index2],
        configs: revlog_config.RevlogConfigs,
    ):
        self.docket = docket
        self.target = target
        self.radix = radix

        index_blocks = []
        for ft in self._index_fts:
            block = b''
            # always get the filepath to get consistent order in the test
            block_path = docket.filepath(ft)
            block_size = docket.get_end(ft)
            if block_size > 0:
                block = opener.tryread(
                    block_path,
                    configs.data.mmap_index_threshold,
                    size=block_size,
                )
                if len(block) < block_size:
                    msg = IDX_TOO_SHORT % (
                        self.display_id,
                        docket_mod.EXT[ft],
                        len(block),
                        block_size,
                    )
                    raise error.RevlogError(msg)
            index_blocks.append(block)

        try:
            index = index_parser(tuple(index_blocks))
        except (ValueError, IndexError):
            raise CorruptedRevlogError(b"corrupted index")

        self._segment_files: dict[
            docket_mod.FileType,
            randomaccessfile.randomaccessfile,
        ] = {}
        for ft in self._active_fts:
            if ft.is_index:
                continue
            self._segment_files[ft] = randomaccessfile.randomaccessfile(
                opener,
                docket.filepath(ft),
                configs.data.chunk_cache_size,
            )

        super().__init__(
            opener=opener,
            target=target,
            index=index,
            segment_file=self._segment_files[docket.FT.DATA],
            inline=False,
            configs=configs,
        )
        self._segmentfile_sidedata = self._segment_files[docket.FT.SIDEDATA]
        self._default_compression_header = docket.default_compression_header

    @util.propertycache
    def display_id(self):
        """The public facing "ID" of the revlog that we use in message"""
        if self.target[0] == KIND_FILELOG:
            # Reference the file without the "data/" prefix, so it is familiar
            # to the user.
            return self.target[1]
        else:
            return self.radix

    def check_size(self) -> tuple[int, int]:
        """Check size of index and data files

        return a (dd, di) tuple.
        - dd: extra bytes for the "data" file
        - di: extra bytes for the "index" file

        A healthy revlog will return (0, 0).
        """
        # TODO: return something sensible for V2
        #
        # trailing data are not error in V2, but missing data are.
        #
        # However, until the InnerRevlogV2 is has access to the docket that
        # knows about data file end. In addition, there is more than just
        # index and data for revlog-v2 so the return would have to evolve.
        return (0, 0)

    def files(self, include_old: bool = True) -> list[HgPathT]:
        """return list of files that compose this revlog"""
        docket = self.docket
        res = []
        add_one = res.append
        add_many = res.extend
        add_one(docket.docket_path())
        for ft in self._active_fts:
            if ft.is_index:
                add_one(docket.filepath(ft))
            else:
                if 0 < docket.get_end(ft):
                    add_one(docket.filepath(ft))
        if include_old:
            add_many(docket.old_filepaths())
        return res

    def clear_cache(self):
        super().clear_cache()
        self._segmentfile_sidedata.clear_cache()

    @util.propertycache
    def _decompressor(self):
        """the default decompressor"""
        t = self._default_compression_header
        return self._get_decompressor(t).decompress

    @contextlib.contextmanager
    def _reading(self):
        with contextlib.ExitStack() as stack:
            for ft in self._active_fts:
                if not ft.is_index:
                    stack.enter_context(self._segment_files[ft].reading())
            yield

    @property
    def is_open(self):
        """True if any file handle is being held

        Used for assert and debug in the python code"""
        return super().is_open or self._segmentfile_sidedata.is_open

    def sidedata(self, rev):
        """Return the sidedata for a given revision number."""
        sidedata_end = self.docket.get_end(self.docket.FT.SIDEDATA)
        sidedata_offset = self.index.sidedata_chunk_offset(rev)
        sidedata_size = self.index.sidedata_chunk_length(rev)

        if sidedata_size == 0:
            return {}

        if sidedata_end < sidedata_offset + sidedata_size:
            filename = self.docket.filepath(self.docket.FT.SIDEDATA)
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

    def changed_files_bytes(self, rev):
        """Serialized ChangedFiles data for this revision

        If the inner-revlog doesn't store that information, always return the
        serialization of an empty ChangedFiles.
        """
        if self.docket.FT.CHANGED_FILES not in self._segment_files:
            return b""
        offset = self.index.changed_files_offset(rev)
        size = self.index.changed_files_length(rev)
        if size == 0:
            return b""
        # TODO raise a proper error on corruption
        f = self._segment_files[self.docket.FT.CHANGED_FILES]
        data = f.read_chunk(offset, size)
        assert len(data) == size
        return data

    @contextlib.contextmanager
    def _writing(self, transaction):
        docket = self.docket

        # NOTE: I suspect we don't need check_ambig for the index, but only on
        # the docket.
        check_ambig = self.data_config.check_ambig
        handles = {}
        with contextlib.ExitStack() as stack:
            for ft in self._active_fts[::-1]:
                path = docket.filepath(ft)
                end = docket.get_end(ft)

                if ft.is_index:
                    fh = self.opener.wopen(path, checkambig=check_ambig)
                else:
                    fh = self.opener.wopen(path)
                stack.enter_context(fh)
                fh.seek(end, os.SEEK_SET)
                transaction.add(path, end)
                if ft in self._segment_files:
                    self._segment_files[ft].writing_handle = fh
                handles[ft] = fh
            self._writinghandles = handles
            yield
            self._writinghandles = None
            for segment_file in self._segment_files.values():
                segment_file.writing_handle = None

    def next_data_offset(self):
        """Returns the current offset in the (in-transaction) data file."""
        return self.docket.get_end(self.docket.FT.DATA)

    def _prepare_update(self, transaction, file_type, pos):
        """ensure the data we are about to write are in a mutable block

        NOTE: This is currently not very efficent as we don't splits the block
        "vertically". i.e. all data of a single type are in a continuous block.
        """
        docket = self.docket
        if docket.is_pending_offset(file_type, pos):
            # data already updatable, nothing to do
            return

        old_path = self.opener.join(docket.filepath(file_type))
        new_name = docket.new_filepath(file_type)
        new_path = self.opener.join(new_name)
        util.copyfile(old_path, new_path)
        transaction.add(new_path, 0)

    def _rewrite_index(
        self,
        transaction: TransactionT,
        rev: RevnumT,
        idx_bins: tuple[None | bytes],
        pending_only: bool = False,
    ):
        """rewrite on-disk index data for revision

        This should be called with the returns of various `index.update_xxx`
        methods.

        The `idx_bins` is a tuple of binary data to update for `rev` for each
        index block. `None` value are unchanged and don't need to be updated.
        """
        for idx_ft, bin_piece, entry_size in zip(
            self._index_fts,
            idx_bins,
            self.index.entry_sizes,
        ):
            if bin_piece is None:
                continue
            idx_pos = entry_size * rev
            assert len(bin_piece) == entry_size
            # Changing index content under reader nose would be a problem,
            # however if that transaction has not been committed yet,
            # nobody is reading it and this won't be a problem.
            if not pending_only:
                self._prepare_update(transaction, idx_ft, idx_pos)
            elif not self.docket.is_pending_offset(idx_ft, idx_pos):
                msg = "invalid rewrite of a non-pending revision"
                raise error.ProgrammingError(msg)
            idx_fh = self._writinghandles[idx_ft]
            idx_fh.seek(idx_pos, os.SEEK_SET)
            idx_fh.write(bin_piece)

    def _add_children_info(
        self,
        transaction: TransactionT,
        curr: RevnumT,
        entry: revlogutils.RevlogEntry,
    ):
        """add children information to an incoming entry

        Also update the affected parent and sibling
        """
        entry.child_p1 = nullrev
        entry.child_p2 = nullrev
        entry.sibling_p1 = nullrev
        entry.sibling_p2 = nullrev
        # This dict hold updated binary block for older revision affected
        # by children tracking.
        #
        # IMPORTANT, In some rare case, the same revision might be affected
        # twice (first by the p1 processing, second by the p2 processing.
        # The current code assume that:
        #
        # - the index will apply the change internally independently from
        #   the "on disk" update.
        # - the second update call will return a binary blob containing
        #   both update.
        #
        # Such cases might happens
        #
        #  - for buggy revision that use the same revision for p1 and p2.
        #  - for oedipus merge between a parent and a child:
        #
        #      C
        #      |\
        #      | B
        #      |/
        #      A
        #
        #   In such case, adding C first update the sibling_p1 for B and
        #   then update the child_p2 for that same B.
        #
        # NOTE: since the computationa nd update regarding p1 will never
        # impact the computation and update regarding p2. We could computed
        # them both upfront and use a single method to update all values in
        # one go. Such method would be more complexe, but would result in
        # less constraint on the index size.

        update = {}
        p1 = entry.parent_rev_1
        assert p1 < curr

        if p1 == nullrev:
            # NOTE: we are using sibling_p1 to track all root revisions in
            # this revlog. This is useful to handle "children(null)" (and
            # to have less special case)
            if curr > 0:
                c1 = 0
                while (next := self.index.sibling_p1(c1)) != nullrev:
                    # XXX: we should raise a proper corruption error here
                    assert next is not None
                    assert c1 < next, (c1, next)  # avoid infinite loop
                    assert c1 < curr, (c1, curr)
                    c1 = next
                update[c1] = self.index.update_sibling_p1(c1, curr)
        else:
            c1 = self.index.child_p1(p1)
            assert c1 is not None
            assert c1 < curr, (c1, curr)
            if c1 == nullrev:
                update[p1] = self.index.update_child_p1(p1, curr)
            else:
                while (next := self.index.sibling_p1(c1)) != nullrev:
                    # XXX: we should raise a proper corruption error here
                    assert next is not None
                    assert c1 < next, (c1, next)  # avoid infinite loop
                    assert c1 < curr, (c1, curr)
                    c1 = next
                update[c1] = self.index.update_sibling_p1(c1, curr)
        p2 = entry.parent_rev_2
        assert p1 < curr
        if p2 != nullrev:
            c2 = self.index.child_p2(p2)
            assert c2 is not None
            assert c2 < curr, (c2, curr)
            if c2 == nullrev:
                update[p2] = self.index.update_child_p2(p2, curr)
            else:
                while (next := self.index.sibling_p2(c2)) != nullrev:
                    # XXX: we should raise a proper corruption error here
                    assert next is not None
                    assert c2 < next, (c2, next)  # avoid infinite loop
                    assert c2 < curr, (c2, curr)
                    c2 = next
                update[c2] = self.index.update_sibling_p2(c2, curr)
        for rev, idx_bins in sorted(update.items()):
            self._rewrite_index(transaction, rev, idx_bins)

    def add_entry(
        self,
        transaction: TransactionT,
        entry: revlogutils.RevlogEntry,
        data: bytes,
        link: int,
        other_data: dict[V2FileType, bytes] | None,
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
        docket = self.docket
        curr = len(self.index)

        if other_data is None:
            other_data = {}
        assert other_data is not None

        if self.feature_config.children:
            self._add_children_info(transaction, curr, entry)

        if (sidedata := other_data.get(docket.FT.SIDEDATA)) is not None:
            entry.sidedata_offset = docket.get_end(self.docket.FT.SIDEDATA)
            entry.sidedata_compressed_length = len(sidedata)

        if docket.FT.CHANGED_FILES in self._active_fts:
            entry.changed_files_offset = docket.get_end(
                self.docket.FT.CHANGED_FILES
            )
            entry.changed_files_length = len(
                other_data.get(self.docket.FT.CHANGED_FILES, b"")
            )

        if docket.FT.STS_SPLIT in self._active_fts:
            entry.sts_split_offset = docket.get_end(self.docket.FT.STS_SPLIT)
            split_data_size = len(other_data.get(self.docket.FT.STS_SPLIT, b""))
            assert (split_data_size % STR_SPLIT.size) == 0
            entry.sts_split_count = split_data_size // STR_SPLIT.size

        for ft, fh in sorted(self._writinghandles.items()):
            pos = docket.get_end(ft)
            fh.seek(pos, os.SEEK_SET)
            transaction.add(docket.filepath(ft), pos)

        self.index.add_entry(entry)
        bin_entry = self.index.entry_binaries(curr)
        if data[0]:
            self._writinghandles[docket.FT.DATA].write(data[0])
        self._writinghandles[docket.FT.DATA].write(data[1])
        for ft, o_data in sorted(other_data.items()):
            self._writinghandles[ft].write(o_data)

        for ft, bin_piece in zip(self._index_fts, bin_entry):
            self._writinghandles[ft].write(bin_piece)
        for ft, fh in sorted(self._writinghandles.items()):
            self.docket.set_end(ft, fh.tell())

    def rewrite_sidedata(self, transaction: TransactionT, new_info):
        assert self.is_writing
        new_entries = []
        # append the new sidedata

        sdfh = self._writinghandles[self.docket.FT.SIDEDATA]
        sdfh.seek(self.docket.get_end(self.docket.FT.SIDEDATA), os.SEEK_SET)
        current_offset = sdfh.tell()
        startrev = None
        for rev, serialized_sidedata, flags in new_info:
            if startrev is None:
                startrev = rev

            sidedata_compression_mode = COMP_MODE_INLINE
            if serialized_sidedata and self.feature_config.has_side_data:
                sidedata_compression_mode = COMP_MODE_PLAIN
                h, comp_sidedata = self.compress(serialized_sidedata)
                if (
                    h != b'u'
                    and comp_sidedata[0] != b'\0'
                    and len(comp_sidedata) < len(serialized_sidedata)
                ):
                    assert not h
                    if comp_sidedata[0] == self._default_compression_header:
                        sidedata_compression_mode = COMP_MODE_DEFAULT
                        serialized_sidedata = comp_sidedata
                    else:
                        sidedata_compression_mode = COMP_MODE_INLINE
                        serialized_sidedata = comp_sidedata
            if (
                self.index.sidedata_chunk_offset(rev) != 0
                or self.index.sidedata_chunk_length(rev) != 0
            ):
                # rewriting entries that already have sidedata is not
                # supported yet, because it introduces garbage data in the
                # revlog.
                msg = b"rewriting existing sidedata is not supported yet: %d %d"
                msg %= (
                    self.index.sidedata_chunk_offset(rev),
                    self.index.sidedata_chunk_length(rev),
                )
                raise error.Abort(msg)

            # Apply (potential) flags to add and to remove after running
            # the sidedata helpers
            assert not (flags[0] & flags[1])
            entry_update = (
                current_offset,
                len(serialized_sidedata),
                flags[0],
                flags[1],
                sidedata_compression_mode,
            )

            # the sidedata computation might have move the file cursors around
            sdfh.seek(current_offset, os.SEEK_SET)
            sdfh.write(serialized_sidedata)
            new_entries.append(entry_update)
            current_offset += len(serialized_sidedata)
            self.docket.set_end(self.docket.FT.SIDEDATA, sdfh.tell())

        # rewrite the new index entries
        for i, e in enumerate(new_entries):
            rev = startrev + i
            idx_bins = self.index.replace_sidedata_info(
                rev,
                *e,
            )  # pytype: disable=attribute-error
            self._rewrite_index(
                transaction,
                rev,
                idx_bins,
                pending_only=True,
            )

    def sidedata_cut_off(self, rev):
        sd_cut_off = self.index.sidedata_chunk_offset(rev)
        if sd_cut_off != 0:
            return sd_cut_off
        # This is some annoying dance, because entries without sidedata
        # currently use 0 as their ofsset. (instead of previous-offset +
        # previous-size)
        #
        # We should reconsider this sidedata → 0 sidata_offset policy.
        # In the meantime, we need this.
        idx = self.index
        while 0 <= rev:
            length = idx.sidedata_chunk_length(rev)
            if length != 0:
                return idx.sidedata_chunk_offset(rev) + length
            rev -= 1
        return 0

    def _strip_affected(self, rev: RevnumT, min_link: RevnumT) -> bool:
        """is there any work to do in this revlog for a strip"""
        size = len(self)
        if rev < size:
            return True
        elif size == 0:
            return False
        return False

    def _strip_after(self, transaction, rev, min_link):
        """truncate the revlog on the first revision with a linkrev >= minlink

        It remove all revisions after `rev`."""
        docket = self.docket

        if rev < len(self):
            if self.feature_config.children:
                children_updates = self._strip_precomp_children(rev)

            data_end = self.start(rev)
            sidedata_end = self.sidedata_cut_off(rev)
            # XXX we could, leverage the docket while stripping. However it is
            # not powerfull enough at the time of this comment
            for ft, entry_size in zip(self._index_fts, self.index.entry_sizes):
                end = rev * entry_size
                docket.set_end(ft, end)
                transaction.add(docket.filepath(ft), end)
            docket.set_end(self.docket.FT.DATA, data_end)
            docket.set_end(self.docket.FT.SIDEDATA, sidedata_end)
            transaction.add(docket.filepath(docket.FT.DATA), data_end)
            transaction.add(docket.filepath(docket.FT.SIDEDATA), sidedata_end)

            if self.feature_config.children:
                self._strip_apply_children(transaction, children_updates)
        self.docket.write(transaction, stripping=True)

    def _strip_precomp_children(
        self,
        strip_rev: RevnumT,
    ) -> _ChildrenUpdateT:
        """precompute children update for a strip operastion"""
        ...
        assert self.feature_config.children
        # we need to adjust children tracking below the striping point.
        processed_p1 = set()
        processed_p2 = set()
        updates: _ChildrenUpdateT = collections.defaultdict(
            lambda: [None, None, None, None]
        )
        idx = self.index
        for stripped in range(strip_rev, len(self.index)):
            p1, p2 = idx.parents(stripped)
            if p1 < strip_rev and p1 not in processed_p1:
                processed_p1.add(p1)
                c1 = idx.child_p1(p1)
                assert c1 != nullrev
                if strip_rev <= c1:
                    # note: child_p1 of nullrev is always 0 (unless the
                    # repository is empty, but then we would not have
                    # anything to strip), so the only way to have :
                    # "p1 == nullrev" and  "p1 < rev" and rev <=
                    # p1.child_p1" if for "rev" to be "0". In that case we
                    # are stripping everything and there won't be anything
                    # left to update.
                    #
                    # In all case, we can't "update" nullrev so we strip
                    # the "p1" update in this case.
                    if p1 != nullrev:
                        assert p1 is not None
                        updates[p1][0] = nullrev
                else:
                    while (
                        next := idx.sibling_p1(c1)
                    ) != nullrev and next < strip_rev:
                        c1 = next
                    assert c1 is not None
                    updates[c1][1] = nullrev
            if p2 < strip_rev and p2 not in processed_p2 and p2 != nullrev:
                processed_p2.add(p2)
                c2 = idx.child_p2(p2)
                assert c2 is not None
                assert c2 != nullrev
                if strip_rev <= c2:
                    assert p2 is not None
                    updates[p2][2] = nullrev
                else:
                    while (
                        next := idx.sibling_p2(c2)
                    ) != nullrev and next < strip_rev:
                        c2 = next
                    assert c2 is not None
                    updates[c2][3] = nullrev
        return updates

    def _strip_apply_children(
        self,
        transaction: TransactionT,
        updates: _ChildrenUpdateT,
    ) -> None:
        """apply the updates computed by _strip_precomp_children"""
        assert self.feature_config.children
        idx = self.index
        with self.writing(transaction):
            for u_rev, u_value in sorted(updates.items()):
                c1, s1, c2, s2 = u_value
                bins = None  # this assume we can just use the last bin
                if c1 is not None:
                    bins = idx.update_child_p1(u_rev, c1)
                if c2 is not None:
                    bins = idx.update_child_p2(u_rev, c2)
                if s1 is not None:
                    bins = idx.update_sibling_p1(u_rev, s1)
                if s2 is not None:
                    bins = idx.update_sibling_p2(u_rev, s2)
                assert bins is not None

                self._rewrite_index(transaction, u_rev, bins)

    def file_cutoffs(self, first_excl_rev):
        docket = self.docket
        index = self.index
        cutoffs = {
            docket.FT.DATA: index.data_chunk_start(first_excl_rev),
            docket.FT.SIDEDATA: self.sidedata_cut_off(first_excl_rev),
        }
        for ft, entry_size in zip(self._index_fts, self.index.entry_sizes):
            cutoffs[ft] = entry_size * first_excl_rev
        if docket.FT.CHANGED_FILES in self._active_fts:
            cgf_cutoff = index.changed_files_offset(first_excl_rev)

            cutoffs[docket.FT.CHANGED_FILES] = cgf_cutoff
        if docket.FT.INDEX_STR in self._active_fts:
            sts_cutoff = index.sts_split_offset(first_excl_rev)
            cutoffs[docket.FT.STS_SPLIT] = sts_cutoff
        return cutoffs

    def rewrite_data(
        self,
        transaction: TransactionT,
        rev: RevnumT,
        delta_data: bytes,
        delta_u_size: int,
        delta_base: RevnumT | None,
        compression: revlogutils.CompModeT,
        censored=True,
    ):
        """record new data chunk for a revision

        Used when censoring revision, assume the data storage have been
        truncated up to that revision.

        The API might evolve in the future. For example, to "track delta
        quality" information.  Or if we starts using it to "re-encode" delta
        tree in the future.
        """

        index = self.index
        docket = self.docket
        offset = docket.get_end(docket.FT.DATA)
        if rev == 0:
            assert offset == 0
        else:
            expected = index.data_chunk_start(rev - 1)
            expected += index.data_chunk_length(rev - 1)
            assert expected == offset, (offset, expected)

        fh = self._writinghandles[docket.FT.DATA]
        fh.seek(offset, os.SEEK_SET)
        fh.write(delta_data)
        docket.set_end(docket.FT.DATA, offset + len(delta_data))
        idx_bin = index.update_data(
            rev=rev,
            offset=offset,
            chunk_size=len(delta_data),
            uncompressed_chunk_size=delta_u_size,
            compression=compression,
            censored=censored,
            delta_base=delta_base,
        )
        self._rewrite_index(transaction, rev, idx_bin)

    def add_changed_files(
        self,
        transaction: TransactionT,
        data_iter: Iterator[tuple[RevnumT, bool, bytes]],
    ):
        """Update the ChangedFiles information of a series of revision

        This assume the "changed-files" information were previously
        missing in all these revisions.

        This also assume these revisions that are being updated are part of a
        pending transaction and wasn't fully committed to disk yet. As a
        result, the revision entries were not part of the "from disk" data of
        this index.
        """
        docket = self.docket
        ft = docket.FT.CHANGED_FILES
        assert ft in self._active_fts
        assert self.is_writing
        fh = self._writinghandles[ft]
        start_pos = pos = docket.get_end(ft)
        fh.seek(pos, os.SEEK_SET)
        transaction.add(docket.filepath(ft), pos)
        for rev, has_copy_info, cfg_bin in data_iter:
            assert self.index.changed_files_offset(rev) == start_pos
            assert self.index.changed_files_length(rev) == 0
            size = len(cfg_bin)
            assert size != 1
            fh.write(cfg_bin)
            idx_bins = self.index.update_changed_files(
                rev,
                has_copy_info,
                pos,
                size,
            )
            self._rewrite_index(
                transaction,
                rev,
                idx_bins,
                pending_only=True,
            )
            pos += size
            docket.set_end(ft, pos)
            assert self.changed_files_bytes(rev) == cfg_bin, (
                self.changed_files_bytes(rev),
                cfg_bin,
            )

    def sts_splits(self, rev: RevnumT) -> list[tuple[RevnumT, int]]:
        count = self.index.sts_split_count(rev)
        if count == 0:
            return []
        offset = self.index.sts_split_offset(rev)
        assert offset is not None
        fh = self._segment_files[self.docket.FT.STS_SPLIT]
        size = STR_SPLIT.size * count
        raw = fh.read_chunk(offset, size)
        splits = []
        for idx in range(count):
            start = idx * STR_SPLIT.size
            splits.append(STR_SPLIT.unpack(raw[start : start + STR_SPLIT.size]))
        return splits
