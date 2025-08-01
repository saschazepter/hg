# clone.py - high level logic for cloning
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os

from ..utils import (
    urlutil,
)


def default_dest(source):
    """return default destination of clone if none is given

    >>> default_dest(b'foo')
    'foo'
    >>> default_dest(b'/foo/bar')
    'bar'
    >>> default_dest(b'/')
    ''
    >>> default_dest(b'')
    ''
    >>> default_dest(b'http://example.org/')
    ''
    >>> default_dest(b'http://example.org/foo/')
    'foo'
    """
    path = urlutil.url(source).path
    if not path:
        return b''
    return os.path.basename(os.path.normpath(path))
