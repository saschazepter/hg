# revlog.py - Type annotations for revlog related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import enum


class DeltaBaseReusePolicy(enum.IntEnum):
    """What should be done with a cached delta and its base ?"""

    NO = 0
    """Ignore the cache when considering candidates.

    The cached delta might be used, but the delta base will not be scheduled
    for usage earlier than in "normal" order.
    """

    TRY = 1
    """Prioritize trying the cached delta base

    The delta base will be tested for validy first. So that the cached deltas
    get used when possible.
    """

    FORCE = 2
    """Force using this delta regardless of its validity

    The delta base will be used and the result will be used for storage
    regardless of the validity of the chain it create.
    """
