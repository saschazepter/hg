# mercurial/interfaces/types.py - type alias for interfaces
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This is the main entry point for Mercurial code writing type annotations.
#
# The general principle can be summarized when dealing with <FooBar> object:
# - to type your code: use FooBarT from `mercurial.interface.types`
# - to implement foobar: use IFoorbar from `mercurial.interface.foo_bar`

from __future__ import annotations

from . import (
    _basetypes,
    matcher,
)

MatcherT = matcher.IMatcher

UserMsgT = _basetypes.UserMsgT
HgPathT = _basetypes.HgPathT
FsPathT = _basetypes.FsPathT
