# tables.py - trivial module centralizing registration table
#
# Copyright 2025  Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""gather "registration table" to be used with the registrar module

This module allow multiple module to register items to the same table, and
other code to access this table without having to import the registered code.

This module very few import very few on purpose. Not importing anything means
this module will not be part of any import cycle.
"""

from __future__ import annotations

from .interfaces.types import (
    UiT,
)
from .i18n import _

command_table: dict = {}
webcommand_table: dict = {}

# symbols are callables like:
#   fn(repo, subset, x)
# with:
#   repo - current repository instance
#   subset - of revisions to be examined
#   x - argument in tree form
revset_symbol_table: dict = {}
# symbols which can't be used for a DoS attack for any given input
# (e.g. those which accept regexes as plain strings shouldn't be included)
# functions that just return a lot of changesets (like all) don't count here
safe_revset_symbols: set[bytes] = set()

bundle2_part_handler_mapping = {}

template_keyword_table: dict = {}
default_templates: dict = {}


def load_cmd_table(ui: UiT, name: bytes, cmdtable: dict) -> None:
    """Load command functions from specified cmdtable

    Used by extensions to add new commands"""
    overrides = [cmd for cmd in cmdtable if cmd in command_table]
    if overrides:
        msg = _(b"extension '%s' overrides commands: %s\n")
        msg %= (name, b" ".join(overrides))
        ui.warn(msg)
    command_table.update(cmdtable)


def load_revset_predicates(ui: UiT, extname: bytes, registrarobj):
    """Load revset predicates from specified registrarobj"""
    revset_symbol_table.update(registrarobj._table)
    safe_revset_symbols.update(registrarobj._safe_set)


def load_template_keywords(ui: UiT, extname: bytes, registrarobj):
    """Load template keyword from specified registrarobj"""
    for name, func in registrarobj._table.items():
        template_keyword_table[name] = func
