# tables.py - trivial module centralizing registration table
#
# Copyright 2025  Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""gather "registration table" to be used with the registrar module

This module allow multiple module to register items to the same table, and
other code to access this table without having to import the registered code.

This module doesn't import anything on purpose. Not importing anything means
this module will not be part of any import cycle.
"""

from __future__ import annotations

command_table: dict = {}
