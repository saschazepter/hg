# main_script - utility around the top level command for Mercurial
#
# Copyright 2005-2025 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import sys
import typing

if typing.TYPE_CHECKING:
    from ..interfaces.types import (
        RepoSetupFnT,
        RepoT,
    )


class request:
    repo: RepoT | None
    prereposetups: list[RepoSetupFnT]

    def __init__(
        self,
        args,
        ui=None,
        repo: RepoT | None = None,
        fin=None,
        fout=None,
        ferr=None,
        fmsg=None,
        prereposetups: list[RepoSetupFnT] | None = None,
    ):
        self.args = args
        self.ui = ui
        self.repo = repo

        # input/output/error streams
        self.fin = fin
        self.fout = fout
        self.ferr = ferr
        # separate stream for status/error messages
        self.fmsg = fmsg

        # remember options pre-parsed by _earlyparseopts()
        self.earlyoptions = {}

        # reposetups which run before extensions, useful for chg to pre-fill
        # low-level repo state (for example, changelog) before extensions.
        self.prereposetups = prereposetups or []

        # store the parsed and canonical command
        self.canonical_command = None

    def _runexithandlers(self) -> None:
        exc = None
        handlers = self.ui._exithandlers
        try:
            while handlers:
                func, args, kwargs = handlers.pop()
                try:
                    func(*args, **kwargs)
                except:  # re-raises below
                    if exc is None:
                        exc = sys.exc_info()[1]
                    self.ui.warnnoi18n(b'error in exit handlers:\n')
                    self.ui.traceback(force=True)
        finally:
            if exc is not None:
                raise exc
