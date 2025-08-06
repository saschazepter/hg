"""a python shell with repo, changelog & manifest objects (DEPRECATED)

The functionality of this extension has been included in core Mercurial since
version 7.1. Please use the core :hg:`debugshell` command instead.
"""

from __future__ import annotations

from mercurial import commands

from mercurial.main_script import cmd_finder


def uisetup(ui):
    choice, _allcmds = cmd_finder.find_possible(b'dbsh', commands.table)

    if b'dbsh' not in choice and ui.config(b'alias', b'dbsh', None) is None:
        ui.setconfig(b'alias', b'dbsh', b'debugshell', source=b'debugshell')
