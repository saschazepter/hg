# misc.py - Various Interface that did not deserve a dedicated module (yet)
#
# Copyright 2025 Octobus, contact@octobus.net
from __future__ import annotations

import abc

from typing import (
    Callable,
    Iterator,
    List,
    Optional,
    Protocol,
    Tuple,
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


AuthInfoT = Tuple[
    bytes,
    Optional[
        Tuple[
            None,
            Tuple[bytes, bytes],
            bytes,
            bytes,
        ]
    ],
]


class IUrl(Protocol):
    r"""Reliable URL parser.

    This parses URLs and provides attributes for the following
    components:

    <scheme>://<user>:<passwd>@<host>:<port>/<path>?<query>#<fragment>

    Missing components are set to None. The only exception is
    fragment, which is set to '' if present but empty.

    If parsefragment is False, fragment is included in query. If
    parsequery is False, query is included in path. If both are
    False, both fragment and query are included in path.

    See http://www.ietf.org/rfc/rfc2396.txt for more information.
    """

    path: Optional[bytes]
    scheme: Optional[bytes]
    user: Optional[bytes]
    passwd: Optional[bytes]
    host: Optional[bytes]
    port: Optional[bytes]
    query: Optional[bytes]
    fragment: Optional[bytes]

    @abc.abstractmethod
    def copy(self) -> IUrl:
        ...

    @abc.abstractmethod
    def authinfo(self) -> AuthInfoT:
        ...

    @abc.abstractmethod
    def isabs(self) -> bool:
        ...

    @abc.abstractmethod
    def localpath(self) -> bytes:
        ...

    @abc.abstractmethod
    def islocal(self) -> bool:
        ...
