# narrowrepo.py - repository which supports narrow revlogs, lazy loading
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from . import narrowdirstate


def wraprepo(repo):
    """Enables narrow clone functionality on a single local repository."""

    class narrowrepository(repo.__class__):
        def _makedirstate(self):
            dirstate = super()._makedirstate()
            return narrowdirstate.wrapdirstate(self, dirstate)

    repo.__class__ = narrowrepository
