# bdiff.py - CFFI implementation of bdiff.c
#
# Copyright 2016 Maciej Fijalkowski <fijall@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import struct
import typing

from ..pure.bdiff import *

from ..interfaces import (
    modules as intmod,
)

from . import _bdiff  # pytype: disable=import-error

ffi = _bdiff.ffi
lib = _bdiff.lib


def blocks(sa: bytes, sb: bytes) -> list[tuple[int, int, int, int]]:
    a = ffi.new("struct bdiff_line**")
    b = ffi.new("struct bdiff_line**")
    ac = ffi.new("char[]", bytes(sa))
    bc = ffi.new("char[]", bytes(sb))
    l = ffi.new("struct bdiff_hunk*")
    try:
        an = lib.bdiff_splitlines(ac, len(sa), a)
        bn = lib.bdiff_splitlines(bc, len(sb), b)
        if not a[0] or not b[0]:
            raise MemoryError
        count = lib.bdiff_diff(a[0], an, b[0], bn, l)
        if count < 0:
            raise MemoryError
        rl = [(0, 0, 0, 0)] * count
        h = l.next
        i = 0
        while h:
            rl[i] = (h.a1, h.a2, h.b1, h.b2)
            h = h.next
            i += 1
    finally:
        lib.free(a[0])
        lib.free(b[0])
        lib.bdiff_freehunks(l.next)
    return rl


def bdiff(sa: bytes, sb: bytes) -> bytes:
    a = ffi.new("struct bdiff_line**")
    b = ffi.new("struct bdiff_line**")
    ac = ffi.new("char[]", bytes(sa))
    bc = ffi.new("char[]", bytes(sb))
    l = ffi.new("struct bdiff_hunk*")
    try:
        an = lib.bdiff_splitlines(ac, len(sa), a)
        bn = lib.bdiff_splitlines(bc, len(sb), b)
        if not a[0] or not b[0]:
            raise MemoryError
        count = lib.bdiff_diff(a[0], an, b[0], bn, l)
        if count < 0:
            raise MemoryError
        rl = []
        h = l.next
        la = lb = 0
        while h:
            if h.a1 != la or h.b1 != lb:
                lgt = (b[0] + h.b1).l - (b[0] + lb).l
                rl.append(
                    struct.pack(
                        b">lll",
                        (a[0] + la).l - a[0].l,
                        (a[0] + h.a1).l - a[0].l,
                        lgt,
                    )
                )
                rl.append(bytes(ffi.buffer((b[0] + lb).l, lgt)))
            la = h.a2
            lb = h.b2
            h = h.next

    finally:
        lib.free(a[0])
        lib.free(b[0])
        lib.bdiff_freehunks(l.next)
    return b"".join(rl)


# In order to adhere to the module protocol, these functions must be visible to
# the type checker, though they aren't actually implemented by this
# implementation of the module protocol.  Callers are responsible for
# checking that the implementation is available before using them.
if typing.TYPE_CHECKING:
    xdiffblocks: intmod.BDiffBlocksFnc | None = None
