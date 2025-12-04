# narrowdirstate.py - extensions to mercurial dirstate to support narrow clones
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from mercurial.i18n import _
from mercurial import error


def wrapdirstate(repo, dirstate):
    """Add narrow spec dirstate ignore, block changes outside narrow spec."""

    def _editfunc(fn):
        def _wrapper(self, filename, *args, **kwargs):
            narrowmatch = repo.narrowmatch()
            if (
                filename is not None
                and not narrowmatch(filename)
                and filename not in self
            ):
                msg = _(b"cannot track '%s' - it is outside the narrow clone")
                msg %= filename
                raise error.Abort(msg)
            return fn(self, filename, *args, **kwargs)

        meth_name = fn.__name__
        if not hasattr(dirstate, meth_name):
            # Keep this in sync with the dirstate in case it changes
            msg = "narrow overrides a method that does not exist: %s"
            msg %= meth_name
            raise error.ProgrammingError(msg)
        return _wrapper

    class narrowdirstate(dirstate.__class__):
        # Prevent adding/editing/copying/deleting files that are outside the
        # sparse checkout
        @_editfunc
        def set_tracked(self, *args, **kwargs):
            return super().set_tracked(*args, **kwargs)

        @_editfunc
        def set_untracked(self, *args, **kwargs):
            return super().set_untracked(*args, **kwargs)

        def rebuild(self, parent, allfiles, changedfiles=None):
            if changedfiles is None:
                # Rebuilding entire dirstate, let's filter allfiles to match the
                # narrowspec.
                allfiles = [f for f in allfiles if repo.narrowmatch()(f)]
            super().rebuild(parent, allfiles, changedfiles)

    dirstate.__class__ = narrowdirstate
    return dirstate
