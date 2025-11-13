# hgweb/hgweb_mod.py - external entry point for web interface to hg's repo
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from .hgweb_mod_inner import *

from .. import (
    initialization,
)


initialization.init()
