# context.py - Interface for the content of mercurial/context.py
#
# Copyright 2025 Octobus, contact@octobus.net
from __future__ import annotations

import abc
from typing import (
    Iterable,
    Protocol,
)

from . import (
    repository,
)


# XXX this Protocol is a Stub, you can help by expanding it.
class IContext(Protocol):
    in_memory: bool

    @abc.abstractmethod
    def parents(self) -> list[IChangeContext]:
        ...

    @abc.abstractmethod
    def p1(self) -> IChangeContext:
        ...

    @abc.abstractmethod
    def p2(self) -> IChangeContext:
        ...

    # XXX should be -> misc.ISubRepo
    @abc.abstractmethod
    def sub(self, path: bytes, allowcreate: bool = True):
        ...

    @property
    @abc.abstractmethod
    def substate(self):
        ...


# XXX this Protocol is a Stub, you can help by expanding it.
class IChangeContext(IContext, Protocol):
    @abc.abstractmethod
    def repo(self) -> repository.IRepo:
        ...

    @abc.abstractmethod
    def __contains__(self, key: bytes) -> bool:
        ...

    @abc.abstractmethod
    def __iter__(self) -> Iterable[bytes]:
        ...

    @abc.abstractmethod
    def __getitem__(self, key: bytes):
        ...

    @abc.abstractmethod
    def description(self) -> bytes:
        ...

    @abc.abstractmethod
    def files(self) -> list[bytes]:
        ...


# XXX this Protocol is a Stub, you can help by expanding it.
class IWorkingContext(IContext, Protocol):
    @abc.abstractmethod
    def dirty(self) -> bool:
        ...


# XXX this Protocol is a Stub, you can help by expanding it.
class IWorkingCommitContext(IWorkingContext, IChangeContext, Protocol):
    pass

    @abc.abstractmethod
    def modified(self) -> list[bytes]:
        ...

    @abc.abstractmethod
    def added(self) -> list[bytes]:
        ...

    @abc.abstractmethod
    def removed(self) -> list[bytes]:
        ...

    @abc.abstractmethod
    def deleted(self) -> list[bytes]:
        ...
