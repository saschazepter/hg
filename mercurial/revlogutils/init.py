# revlogutils/init.py - initilization code for the revlog
#
# Copyright 2026 Pierre-Yves David <pierre-yves.david@octobus,net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""Helper function for the initial parsing of setup of a revlog"""

from __future__ import annotations

from . import (
    config,
    constants,
)


def default_header(
    opts: dict,
    kind: constants.Kind,
    configs: config.RevlogConfigs,
):
    """init-method: process options config and return corresponding default
    revlog header, which can be used by `_loadindex` to create a new index.

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """
    if b'changelogv2' in opts and kind == constants.KIND_CHANGELOG:
        new_header = constants.CHANGELOGV2
    elif b'revlogv2' in opts:
        new_header = constants.REVLOGV2
    elif b'revlogv1' in opts:
        new_header = constants.REVLOGV1
        if configs.feature.may_inline:
            new_header |= constants.FLAG_INLINE_DATA
        if kind != constants.KIND_CHANGELOG and b'generaldelta' in opts:
            new_header |= constants.FLAG_GENERALDELTA
            if opts.get(b'delta-info-flags'):
                new_header |= constants.FLAG_DELTA_INFO
        if kind == constants.KIND_FILELOG and b'filelog_hasmeta_flag' in opts:
            new_header |= constants.FLAG_FILELOG_META
    elif b'revlogv0' in opts:
        new_header = constants.REVLOGV0
    else:
        new_header = constants.REVLOG_DEFAULT_VERSION
    return new_header


def split_index_filename(radix):
    """the path where to expect the index of an ongoing splitting operation

    The file will only exist if a splitting operation is in progress, but
    it is always expected at the same location."""
    parts = radix.split(b'/')
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
        return radix + b'.i.s'
