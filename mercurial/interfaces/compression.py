# compression.py - Type annotations for compression related object
#
# Copyright 2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import io
from typing import (
    Iterator,
    Protocol,
)


class IRevlogCompressor(Protocol):
    @abc.abstractmethod
    def compress(self, data: bytes) -> bytes:
        """compress a chunk"""

    @abc.abstractmethod
    def decompress(self, data: bytes) -> bytes:
        """decompress a chunk"""


class _StreamT(Protocol):
    """internal protocol to type input and output stream"""

    def read(self, size: int) -> bytes:
        """read up to `size` bytes from the compressed stream"""


class IWireProtoSupport(Protocol):
    """Signal that a compression engine is usable to compress data on the wire

    It hold three fields:

    * String format identifier
    * Integer priority for the server
    * Integer priority for the client

    The integer priorities are used to order the advertisement of format
    support by server and client. The highest integer is advertised
    first. Integers with non-positive values aren't advertised.

    The priority values are somewhat arbitrary and only used for default
    ordering. The relative order can be changed via config options.
    """

    name: bytes
    serverpriority: int
    clientpriority: int


WireProtoSupportT = IWireProtoSupport


class ICompressionEngine(Protocol):
    """Base class for compression engines.

    Compression engines must implement the interface defined by this class.
    """

    @abc.abstractmethod
    def name(self) -> bytes:
        """Returns the name of the compression engine.

        This is the key the engine is registered under.

        This method must be implemented.
        """

    @abc.abstractmethod
    def available(self) -> bool:
        """Whether the compression engine is available.

        The intent of this method is to allow optional compression engines
        that may not be available in all installations (such as engines relying
        on C extensions that may not be present).
        """

    @abc.abstractmethod
    def bundletype(self) -> bytes | None:
        """Describes bundle identifiers for this engine.

        If this compression engine isn't supported for bundles, returns None.

        If this engine can be used for bundles, returns a 2-tuple of strings of
        the user-facing "bundle spec" compression name and an internal
        identifier used to denote the compression format within bundles. To
        exclude the name from external usage, set the first element to ``None``.

        If bundle compression is supported, the class must also implement
        ``compressstream`` and `decompressorreader``.

        The docstring of this method is used in the help system to tell users
        about this engine.
        """

    @abc.abstractmethod
    def wireprotosupport(self) -> WireProtoSupportT | None:
        """Declare support for this compression format on the wire protocol.

        If this compression engine isn't supported for compressing wire
        protocol payloads, returns None.

        Otherwise, returns an object complying to WireProtoSupportT

        If wire protocol compression is supported, the class must also implement
        ``compressstream`` and ``decompressorreader``.
        """

    @abc.abstractmethod
    def revlogheader(self) -> bytes | None:
        """Header added to revlog chunks that identifies this engine.

        If this engine can be used to compress revlogs, this method should
        return the bytes used to identify chunks compressed with this engine.
        Else, the method should return ``None`` to indicate it does not
        participate in revlog compression.
        """

    @abc.abstractmethod
    def compressstream(
        self,
        it: Iterator[bytes],
        opts: dict | None = None,
    ) -> Iterator[bytes]:
        """Compress an iterator of chunks.

        The method receives an iterator (ideally a generator) of chunks of
        bytes to be compressed. It returns an iterator (ideally a generator)
        of bytes of chunks representing the compressed output.

        Optionally accepts an argument defining how to perform compression.
        Each engine treats this argument differently.
        """

    @abc.abstractmethod
    def decompressorreader(
        self, fh: _StreamT | io.BytesIO
    ) -> _StreamT | io.BytesIO:
        """Perform decompression on a file object.

        Argument is an object with a ``read(size)`` method that returns
        compressed data. Return value is an object with a ``read(size)`` that
        returns uncompressed data.
        """

    @abc.abstractmethod
    def revlogcompressor(
        self,
        opts: dict | None = None,
    ) -> IRevlogCompressor:
        """Obtain an object that can be used to compress revlog entries.

        The object has a ``compress(data)`` method that compresses binary
        data. This method returns compressed binary data or ``None`` if
        the data could not be compressed (too small, not compressible, etc).
        The returned data should have a header uniquely identifying this
        compression format so decompression can be routed to this engine.
        This header should be identified by the ``revlogheader()`` return
        value.

        The object has a ``decompress(data)`` method that decompresses
        data. The method will only be called if ``data`` begins with
        ``revlogheader()``. The method should return the raw, uncompressed
        data or raise a ``StorageError``.

        The object is reusable but is not thread safe.
        """
