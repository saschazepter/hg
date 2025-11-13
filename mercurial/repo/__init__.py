# repo_utils - collection of simply utility around repository
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os


def find_repo(p: bytes) -> bytes | None:
    """find the root of a repository under "p" path if any"""
    while not os.path.isdir(os.path.join(p, b".hg")):
        oldp, p = p, os.path.dirname(p)
        if p == oldp:
            return None
    return p


# set of (path, vfs-location) tuples. vfs-location is:
# - 'plain for vfs relative paths
# - '' for svfs relative paths
cachedfiles = set()
