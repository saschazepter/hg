# revlog.py - Type annotations for revlog related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import enum
import typing

from ._basetypes import (
    HgPathT,
)


class DeltaBaseReusePolicy(enum.IntEnum):
    """What should be done with a cached delta and its base ?"""

    NO_DELTA = -1
    """reuse neither the delta base nor the delta

    Ignore the cache when considering candidates and don't reuse the delta
    itself if givent the chance.
    """

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


class IChangedFiles(typing.Protocol):
    """A Protocal holding the changes made to files by a changeset

    Actions performed on files are gathered into 3 sets:

    - added:   files actively added in the changeset.
    - merged:  files whose history got merged
    - removed: files removed in the revision
    - salvaged: files that might have been deleted by a merge but were not
    - touched: files affected by the merge

    and copies information is held by 2 mappings

    - copied_from_p1: {"<new-name>": "<source-name-in-p1>"} mapping for copies
    - copied_from_p2: {"<new-name>": "<source-name-in-p2>"} mapping for copies

    See actual implementation for details
    """

    touched: frozenset[HgPathT]
    added: frozenset[HgPathT]
    merged: frozenset[HgPathT]
    salvaged: frozenset[HgPathT]
    removed: frozenset[HgPathT]

    copied_from_p1: dict[HgPathT, HgPathT]
    copied_from_p2: dict[HgPathT, HgPathT]


ChangedFilesT = IChangedFiles
