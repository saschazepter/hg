"""Utilities for docket files.

A docket is a small metadata file that points to other files and records
information about their size and structure.

As a simple example, a docket could contain an 8-byte string ID and a 4-byte
file size, referring to a file named "data.{ID}". You could append to the data
file and update the size, or write a new data file and update the ID and size.

Dockets are useful for append-mostly data storage. The transaction only needs to
know about the docket, not the data files. To roll back a transaction, you just
restore the docket, rather than truncating data files. When you create a new
data file (the "mostly" in "append-mostly"), you leave the old data file alone.
This means processes can safely mmap data files without worrying about them
getting truncated or removed underneath them.
"""

from __future__ import annotations

import os
import random
import struct

from .. import encoding, node


def make_uid(id_size=8):
    """Return a new unique identifier.

    The identifier is random and composed of ascii characters.
    """
    # Since we "hex" the result we need half the number of bits to have a final
    # uid of size id_size.
    return node.hex(os.urandom(id_size // 2))


# some special test logic to avoid anoying random output in the test
stable_docket_file = encoding.environ.get(b'HGTEST_UUIDFILE')

if stable_docket_file:

    def make_uid(id_size=8):
        try:
            with open(stable_docket_file, mode='rb') as f:
                seed = f.read().strip()
        except FileNotFoundError:
            seed = b'04'  # chosen by a fair dice roll. garanteed to be random
        iter_seed = iter(seed)
        # some basic circular sum hashing on 64 bits
        int_seed = 0
        low_mask = int('1' * 35, 2)
        for i in iter_seed:
            high_part = int_seed >> 35
            low_part = (int_seed & low_mask) << 28
            int_seed = high_part + low_part + i
        r = random.Random()
        r.seed(int_seed, version=1)
        # once we drop python 3.8 support we can simply use r.randbytes
        raw = r.getrandbits(id_size * 4)
        assert id_size == 8
        p = struct.pack('>L', raw)
        new = node.hex(p)
        with open(stable_docket_file, 'wb') as f:
            f.write(new)
        return new
