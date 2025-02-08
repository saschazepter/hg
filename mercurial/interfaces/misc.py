# misc.py - Various Interface that did not deserve a dedicated module (yet)
#
# Copyright 2025 Octobus, contact@octobus.net
from __future__ import annotations

import abc

from typing import (
    Callable,
    Iterator,
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


class IDirs(Protocol):
    '''a multiset of directory names from a set of file paths'''

    @abc.abstractmethod
    def addpath(self, path: bytes) -> None:
        ...

    @abc.abstractmethod
    def delpath(self, path: bytes) -> None:
        ...

    @abc.abstractmethod
    def __iter__(self) -> Iterator[bytes]:
        ...

    @abc.abstractmethod
    def __contains__(self, d: bytes) -> bool:
        ...
