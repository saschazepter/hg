"""a python shell with repo, changelog & manifest objects (DEPRECATED)

The functionality of this extension has been included in core Mercurial since
version 7.1. Please use the core :hg:`debugshell` command instead.
"""

from __future__ import annotations

from mercurial import cmdutil, commands


def uisetup(ui):
    choice, _allcmds = cmdutil.findpossible(b'dbsh', commands.table)

    if b'dbsh' not in choice and ui.config(b'alias', b'dbsh', None) is None:
        ui.setconfig(b'alias', b'dbsh', b'debugshell', source=b'debugshell')
