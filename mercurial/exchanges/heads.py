# mercurial/exchanges/heads.py - heads focussed exchange's utilities
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import array
import binascii
import hashlib
import struct

from typing import (
    Dict,
    Sequence,
    Tuple,
)

from ..interfaces.types import (
    NodeIdT,
    PeerT,
    RepoT,
)
from .. import (
    node as node_mod,
)


def _bucket_boundary(max_value: int) -> list[int]:
    """Provide useful bucket boundary according to a maximum value

    For a value X, this provides log_2(X), with each bucket being about ½ the
    size of the previous one.

    These bucket will be used by server to advertise fingerprint of their
    heads. The strategy for buckets selection and fingerprinting is entirely
    the responsability of the server so the strategy used by this function can
    be safely updated.

    >>> def t(x):
    ...     print(f"bin: {x:016b}")
    ...     v = _bucket_boundary(x)
    ...     print(f"buckets:")
    ...     for i in v:
    ...         print("    ", f"{i:016b}")
    ...     print(f"ret: {v}")

    >>> t(0)
    bin: 0000000000000000
    buckets:
         0000000000000000
    ret: [0]

    >>> t(1)
    bin: 0000000000000001
    buckets:
         0000000000000001
    ret: [1]

    >>> t(42)
    bin: 0000000000101010
    buckets:
         0000000000010000
         0000000000100000
         0000000000100100
         0000000000101000
         0000000000101001
         0000000000101010
    ret: [16, 32, 36, 40, 41, 42]

    >>> t(1337)
    bin: 0000010100111001
    buckets:
         0000001000000000
         0000010000000000
         0000010010000000
         0000010011000000
         0000010100000000
         0000010100100000
         0000010100110000
         0000010100110100
         0000010100110110
         0000010100111000
         0000010100111001
    ret: [512, 1024, 1152, 1216, 1280, 1312, 1328, 1332, 1334, 1336, 1337]

    >>> t(600)
    bin: 0000001001011000
    buckets:
         0000000100000000
         0000000110000000
         0000001000000000
         0000001000100000
         0000001001000000
         0000001001010000
         0000001001010100
         0000001001010110
         0000001001010111
         0000001001011000
    ret: [256, 384, 512, 544, 576, 592, 596, 598, 599, 600]

    >>> t(1023)
    bin: 0000001111111111
    buckets:
         0000001000000000
         0000001100000000
         0000001110000000
         0000001111000000
         0000001111100000
         0000001111110000
         0000001111111000
         0000001111111100
         0000001111111110
         0000001111111111
    ret: [512, 768, 896, 960, 992, 1008, 1016, 1020, 1022, 1023]
    >>> t(1024)
    bin: 0000010000000000
    buckets:
         0000001000000000
         0000001100000000
         0000001110000000
         0000001111000000
         0000001111100000
         0000001111110000
         0000001111111000
         0000001111111100
         0000001111111110
         0000001111111111
         0000010000000000
    ret: [512, 768, 896, 960, 992, 1008, 1016, 1020, 1022, 1023, 1024]
    """
    if max_value <= 0:
        # repository is empty or have a single revision, we don't care about
        # such repository here.
        return [0]

    tiers = []
    for idx in range(32):
        if idx:
            mask = int('1' * idx, 2)
        else:
            mask = 0
        mask = ~mask
        t = max_value & mask
        if t == 0:
            # we went over the highest bit
            break
        bit = 1 << idx
        if (max_value & bit) == 0:
            t -= bit
        tiers.append(t)
    tiers.sort()
    return tiers


FP_SPEC = struct.Struct('I')
"""serialization specification for the fingerprint

The fingerprint computation is not designed as a shared logic and can be safely
updated from one version to the next. The fact the encoding is
endianess-dependent is on purpose, the computation of the fingerprint is
already endianess-dependent.
"""


def _bucket_fingerprints(
    tiers: list[int],
    heads: Sequence[int],
) -> dict[int, tuple[int, bytes]]:
    """Compute heads fingerprint for the provided tier value

    The `heads` are expected to be unique and sorted in ascending order as
    returned by revlog's `headrevs` method.

    These bucket will be used by server to advertise fingerprint of their
    heads. The strategy for buckets selection and fingerprinting is entirely
    the responsability of the server so the strategy used by this function can
    be safely updated.

    For example, the current function will be affected by the machine
    endianess. This is expected to be fine, as it is unlikely for a server to
    flip-flop between endianess. This sensitivity to endianess have been kept
    on purpose to highlight the possible differences.

    The information returned for each bucket is the number of heads associated
    with this bucket in this bucket and they fingerprint.

    # about the finger print strategy:

    Their are multiple valid strategies to select which revisions to include in
    a bucket. The strategy picked by the server might change over time.

    There are two possible criteria decide if a revision goes into a bucket of
    value N:
    * the revision number being <= N (currently used)
    * the revision rank being <= N

    There are two possible ways to compute the set of revision to consider:
    * compute all heads of the full graph once and filter using the above
      criteria (currently used)
    * for each bucket, compute the heads of the subgraph matching the criteria.

    Finally, there are two ways to compute the final hash:
    * using the revision number themselve (currently used)
    * using the nodeif of the revision

    The strategy currently implemented is the simplest and fastest to implement
    right now. The alternative usually offer more stable alternative. The cost
    of using them will lower as other feature gets implemented.

    Note that the combination of all three alternative (rank + heads of
    sub-graph + node) produce an "universal" hash allowing two independant peer
    to recognise a common subgraph without exchanging anything else than the
    fingerprint.
    """
    info = {}
    # Reverse so that we pop tiers in ascending order.
    tiers.sort(reverse=True)

    # we assume the heads are sorted
    all_heads = memoryview(array.array('i', heads))
    prev_crc32 = 0
    bucket_start = 0
    bucket_end = 0

    current_tier = tiers.pop()
    # XXX: Iterating over all heads is sub-optimal. We could a more efficient
    # strategy (e.g. binary search) to find bucket boundary without iterating
    # over each heads. However, that simple approach was enough for an initial
    # implementation.
    for r in heads:
        while r > current_tier:
            if bucket_start == bucket_end:
                info[current_tier] = (bucket_end, FP_SPEC.pack(prev_crc32))
            else:
                bucket_heads = all_heads[bucket_start:bucket_end]
                bucket_hash = binascii.crc32(bucket_heads, prev_crc32)
                info[current_tier] = (bucket_end, FP_SPEC.pack(bucket_hash))
                prev_crc32 = bucket_hash
                bucket_start = bucket_end
            current_tier = tiers.pop()
        bucket_end += 1
    assert not tiers
    if bucket_start == bucket_end:
        info[current_tier] = (bucket_end, FP_SPEC.pack(prev_crc32))
    else:
        bucket_heads = all_heads[bucket_start:bucket_end]
        bucket_hash = binascii.crc32(bucket_heads, prev_crc32)
        info[current_tier] = (bucket_end, FP_SPEC.pack(bucket_hash))
    return info


def buckets_info(repo) -> dict[int, tuple[int, bytes]]:
    """return a set of bucket with fingerprint and head count information

    The bucket are identified by an integer that defines which subset of the
    repository heads it covers.

    If the fingerprint of a bucket did not change, the heads covered by that
    bucket has not changed.

    The information returned for each bucket is the number of heads associated
    with this bucket in this bucket and they fingerprint.
    """
    cl = repo.changelog
    tiers = _bucket_boundary(len(cl) - 1)
    heads = cl.headrevs()
    if heads == [None]:  # happens for empty repository (for historical reason)
        heads = []
    return _bucket_fingerprints(tiers, heads)


BUCKET_HEADER = struct.Struct('>BBB')
"""The top level header used for serialization

* [u8]: number of buckets
* [u8]: fingerprint size
* [u8]: nodeid size
"""


BUCKET_INFO = struct.Struct('>Ll')
"""The fixed size part of a single bucket header used for serialization

* [u32] bucket-id
* [i32] number of new heads in that bucket
"""


def encoded_bucket_info(repo) -> bytes:
    """an encoded version of the bucket info to be used over the wire


    The data is encoded as follow:

    # [u8]: number of bucket
    # [u8]: size of bucket's fingerprint
    # [u8]: size of head's nodeid (i.e. repo.nodeconstants.nodelen)
    # then for each bucket:
    #    [u32] bucket-id
    #    [i32] number of new heads in that bucket
    #    [bytes] the heads fingerprint for that bucket
    # then for each head:
    #    [bytes] head nodeid

    Used by the wireprotocol to serialize the data.
    """
    pieces = []
    bucket_info = buckets_info(repo)

    cl = repo.changelog
    to_node = cl.index.node
    head_revs = cl.headrevs()

    bfps = FP_SPEC.size
    hns = repo.nodeconstants.nodelen

    pieces.append(BUCKET_HEADER.pack(len(bucket_info), bfps, hns))

    for bucket_id, (count, fp) in sorted(bucket_info.items()):
        pieces.append(BUCKET_INFO.pack(bucket_id, count))
        pieces.append(fp)
    pieces.extend(to_node(r) for r in head_revs)
    return b''.join(pieces)


_ServerReplyT = Dict[int, Tuple[bytes, Sequence[NodeIdT]]]
"""The data sent by the server when requesting heads with fingerprint"""


def decode_bucket_info(
    raw_data: bytes,
) -> _ServerReplyT:
    """return a dict from a encoded bucket info

    { bucket-id -> (fingerprint, [nodes])}

    Used by the wireprotocol to deserialize the data from `encoded_bucket_info`.
    """

    data = memoryview(raw_data)
    nb_bucket, bfps, hns = BUCKET_HEADER.unpack(data[: BUCKET_HEADER.size])

    info_size = BUCKET_INFO.size + bfps
    all_info_size = nb_bucket * info_size
    info_data = data[BUCKET_HEADER.size : BUCKET_HEADER.size + all_info_size]
    nodes_data = data[BUCKET_HEADER.size + all_info_size :]
    if (chunk_len := len(nodes_data)) % hns:
        msg = "nodes-chunk of odd size (%d %% %d)"
        msg %= (chunk_len, hns)
        raise ValueError(msg)

    info = []
    for start in range(0, all_info_size, info_size):
        raw = info_data[start : start + BUCKET_INFO.size]
        bucket_id, nb_head = BUCKET_INFO.unpack(raw)
        fp = info_data[start + BUCKET_INFO.size : start + info_size]
        info.append((bucket_id, nb_head, fp))

    prev_nb_head = 0
    read = 0  # sanity checks
    bucket_info: _ServerReplyT = {}
    for bucket_id, nb_head, fp in info:
        nodes_start = prev_nb_head * hns
        if read == 0:
            assert nodes_start == 0
        nodes_end = nb_head * hns
        assert nodes_end <= len(nodes_data)
        # XXX consider not building the list at all in the future
        indexes = range(nodes_start, nodes_end, hns)
        nodes = [nodes_data[i : i + hns].tobytes() for i in indexes]
        read += len(nodes)
        bucket_info[bucket_id] = (fp, nodes)
        prev_nb_head = nb_head
    if read < (available := (chunk_len // hns)):
        msg = "fewer nodes read than available (%d < %d)"
        msg %= (read, available)
        raise ValueError(msg)
    return bucket_info


def _cache_filename(remote_name: bytes) -> bytes:
    """return a unique identify for a remote"""
    return node_mod.hex(hashlib.sha256(remote_name).digest()) + b'.remote-heads'


# Note: using `bytes` here might be incompatible with memoryview in the future,
# change the typing if so.
def _get_data(used: int, data: bytes, size: int) -> tuple[int, bytes | None]:
    """get the Nth last bytes of "data" ignoring "used" bytes at the end

    return (new_used, data_of_length_size)

    return (used, None) if the data are too short.
    """
    start = used + size
    if len(data) < used + size:
        return (used, None)
    if used == 0:
        return (used + size, data[-start:])
    return (used + size, data[-start:-used])


class RemoteHeadsCache:
    """A cache of the remote heads

    Can be persisted to disk.
    """

    def __init__(self):
        self._buckets: dict[int, tuple[bytes, int]] = {}
        self._heads: list[NodeIdT] = []

    @staticmethod
    def from_cache(local: RepoT, remote: PeerT) -> RemoteHeadsCache:
        """Try to load cache of heads for `remote` stored for `local`

        Return a RemoteHeadsCache object is all cases, empty if no cache could
        be found.

        Won't try anything for remote using a non-named path.
        """
        remote_name = remote.path.name
        if remote_name is None:
            return RemoteHeadsCache()
        # NOTE: we should use the mmap-threshold here
        cached_bytes = local.cachevfs.tryread(_cache_filename(remote_name))

        # read the header to determine the stored buckets
        used, main_header = _get_data(0, cached_bytes, BUCKET_HEADER.size)
        if main_header is None:
            # not enough data for the main header
            return RemoteHeadsCache()
        total_heads = 0
        bucket_count, fp_size, node_size = BUCKET_HEADER.unpack(main_header)
        if node_size != local.nodeconstants.nodelen:
            # node size incompatible with the local repo
            return RemoteHeadsCache()

        cached = RemoteHeadsCache()
        bh_size = BUCKET_INFO.size + fp_size
        for i in range(bucket_count):
            used, bucket_header = _get_data(used, cached_bytes, bh_size)
            if bucket_header is None:
                # not enough data for the promissed bucker header
                return RemoteHeadsCache()
            bucket_id, bucket_heads = BUCKET_INFO.unpack_from(bucket_header)
            bucket_fp = bucket_header[-fp_size:]
            total_heads = max(total_heads, bucket_heads)
            cached._buckets[bucket_id] = (bucket_fp, bucket_heads)
        if len(cached_bytes) < used + (total_heads * node_size):
            # not enough data for all the head we need
            return RemoteHeadsCache()

        # read the heads
        cached._heads = [
            cached_bytes[node_size * idx : node_size * (idx + 1)]
            for idx in range(total_heads)
        ]
        return cached

    def try_write(self, local: RepoT, remote: PeerT) -> None:
        """attempt to update the cache on disk

        Silently fails if it can't write.
        """
        if not self._heads:
            # nothing to cache, nothing to write.
            return
        remote_name = remote.path.name
        if remote_name is None:
            # not a recuring repository, skip.
            return

        cache_name = _cache_filename(remote_name)
        try:
            # NOTE: We could reuse the existing file (if it did not change),
            # doing a kernel level copy of the prefix that did not change would
            # be faster than writing all heads from scratch.
            node_size = None
            fingerprint_size = None
            with local.cachevfs(
                cache_name,
                mode=b"w",
                atomictemp=True,
            ) as cache_file:
                for h in self._heads:
                    if node_size is None:
                        node_size = len(h)
                    else:
                        assert node_size == len(
                            h
                        )  # XXX raise and delete the cache
                    cache_file.write(h)
                for b_id, (b_fp, b_hc) in sorted(self._buckets.items()):
                    if fingerprint_size is None:
                        fingerprint_size = len(b_fp)
                    else:
                        assert fingerprint_size == len(
                            b_fp
                        )  # XXX raise and delete the cache
                    cache_file.write(BUCKET_INFO.pack(b_id, b_hc))
                    cache_file.write(b_fp)
                main_header = BUCKET_HEADER.pack(
                    len(self._buckets),
                    fingerprint_size,
                    node_size,
                )
                cache_file.write(main_header)
        except IOError:
            # this is a cache, update can fail
            pass

    def cached_fingerprints(self) -> list[tuple[int, bytes]]:
        """return a mapping with all the known buckets and their fingerprint

        This is to be used to inform the remote of the known bucket offering
        that remote the opportunity to reduce the number of heads it actually
        has to list.
        """
        return [
            (b_id, b_fp)
            for b_id, (b_fp, _b_hc) in sorted(self._buckets.items())
        ]

    def update(
        self,
        server_reply: _ServerReplyT,
    ) -> tuple[int, list[NodeIdT]]:
        """update the Cache with remote information

        Return the number of head we could reuse form the cache and the full
        list of server heads.
        """
        matched = set(
            k for k, (h, count, heads) in server_reply.items() if heads is None
        )
        if not matched:
            self._buckets.clear()
            self._heads.clear()
            matching_head_count = 0
        else:
            unmatched = set(self._buckets) - matched
            for b_id in unmatched:
                del self._buckets[b_id]
            best_math = max(matched)
            matching_head_count = server_reply[best_math][1]
            assert len(self._heads) >= matching_head_count, (
                len(self._heads),
                matching_head_count,
            )
            del self._heads[matching_head_count:]
        for b_id, (b_fp, count, nodes) in sorted(server_reply.items()):
            if nodes is None:
                # NOTE: In the future, the server might provide intermediate
                # bucket with a number of heads that it would be useful to
                # cache.
                continue
            assert (len(self._heads) + len(nodes)) == count
            self._heads.extend(nodes)
            self._buckets[b_id] = (b_fp, len(self._heads))
        return matching_head_count, self._heads[:]
