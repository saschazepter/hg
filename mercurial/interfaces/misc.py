# misc.py - Various Interface that did not deserve a dedicated module (yet)
#
# Copyright 2025 Octobus, contact@octobus.net
from __future__ import annotations

import abc

from typing import (
    Callable,
    List,
    Protocol,
)


class IHooks(Protocol):
    """A collection of hook functions that can be used to extend a
    function's behavior. Hooks are called in lexicographic order,
    based on the names of their sources."""

    @abc.abstractmethod
    def add(self, source: bytes, hook: Callable):
        ...

    @abc.abstractmethod
    def __call__(self, *args) -> List:
        ...
