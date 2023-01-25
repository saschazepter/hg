# admin_commands.py - command processing for admin* commands
#
# Copyright 2022 Mercurial Developers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from . import registrar

table = {}
command = registrar.command(table)
