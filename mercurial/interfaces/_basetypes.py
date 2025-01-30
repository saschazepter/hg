# mercurial/interfaces/_basetypes.py - internal base type aliases for interfaces
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This module contains trivial type aliases that other interfaces might need.
# This is for internal usage by the modules in `mercurial.interfaces`.
#
# For using type aliases outside for `mercurial.interfaces`, look at the
# `mercurial.interfaces.types` module.

from __future__ import annotations

UserMsgT = bytes
"""Text (maybe) displayed to the user."""

HgPathT = bytes
"""A path usable with Mercurial's vfs."""

FsPathT = bytes
"""A path on disk (after vfs encoding)."""
