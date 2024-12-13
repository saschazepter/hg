# script_commands.py - command declaration for "script::" namespace
#
# Copyright 2022 Mercurial Developers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations


from . import (
    registrar,
    tables,
)

command = registrar.command(tables.command_table)


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items.

    See `mercurial.initialization` for details"""
