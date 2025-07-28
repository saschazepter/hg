# config.py - Type annotations for config related objects
#
# Copyright 2025 Matt Harbison <mharbison72@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from typing import (
    Mapping,
)

CfgRemapT = Mapping[bytes, bytes]
"""The type for remapping one or more config section names to another."""


# TODO: Add Protocol class for configmod.config class
