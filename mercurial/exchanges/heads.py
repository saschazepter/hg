# mercurial/exchanges/heads.py - heads focussed exchange's utilities
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import array
import binascii
import struct

from typing import Sequence


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
