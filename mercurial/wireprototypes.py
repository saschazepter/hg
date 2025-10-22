# Copyright 2018 Gregory Szorc <gregory.szorc@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import abc
import typing

from typing import (
    Final,
    Iterator,
    Protocol,
)

from .node import (
    bin,
    hex,
)
from .i18n import _

from . import (
    error,
    util,
)
from .utils import compression

if typing.TYPE_CHECKING:
    from .interfaces.compression import (
        ICompressionEngine,
    )
    from .interfaces.types import (
        NeedsTypeHint,
        NodeIdT,
        RepoT,
        UiT,
    )

# Names of the SSH protocol implementations.
SSHV1: Final[bytes] = b'ssh-v1'

NARROWCAP: Final[bytes] = b'exp-narrow-1'
ELLIPSESCAP1: Final[bytes] = b'exp-ellipses-1'
ELLIPSESCAP: Final[bytes] = b'exp-ellipses-2'
SUPPORTED_ELLIPSESCAP: Final[tuple[bytes, bytes]] = (ELLIPSESCAP1, ELLIPSESCAP)

# All available wire protocol transports.
TRANSPORTS = {
    SSHV1: {
        b'transport': b'ssh',
        b'version': 1,
    },
    b'http-v1': {
        b'transport': b'http',
        b'version': 1,
    },
}


class bytesresponse:
    """A wire protocol response consisting of raw bytes."""

    data: bytes

    def __init__(self, data: bytes) -> None:
        self.data = data


class ooberror:
    """wireproto reply: failure of a batch of operation

    Something failed during a batch call. The error message is stored in
    `self.message`.
    """

    message: bytes

    def __init__(self, message: bytes) -> None:
        self.message = message


class pushres:
    """wireproto reply: success with simple integer return

    The call was successful and returned an integer contained in `self.res`.
    """

    output: bytes
    res: int

    def __init__(self, res: int, output: bytes) -> None:
        self.res = res
        self.output = output


class pusherr:
    """wireproto reply: failure

    The call failed. The `self.res` attribute contains the error message.
    """

    output: bytes
    res: bytes

    def __init__(self, res: bytes, output: bytes) -> None:
        self.res = res
        self.output = output


class streamres:
    """wireproto reply: binary stream

    The call was successful and the result is a stream.

    Accepts a generator containing chunks of data to be sent to the client.

    ``prefer_uncompressed`` indicates that the data is expected to be
    uncompressable and that the stream should therefore use the ``none``
    engine.
    """

    gen: Iterator[bytes] | None
    prefer_uncompressed: bool

    def __init__(
        self,
        gen: Iterator[bytes] | None = None,
        prefer_uncompressed: bool = False,
    ) -> None:
        self.gen = gen
        self.prefer_uncompressed = prefer_uncompressed


class streamreslegacy:
    """wireproto reply: uncompressed binary stream

    The call was successful and the result is a stream.

    Accepts a generator containing chunks of data to be sent to the client.

    Like ``streamres``, but sends an uncompressed data for "version 1" clients
    using the application/mercurial-0.1 media type.
    """

    gen: Iterator[bytes] | None

    def __init__(self, gen: Iterator[bytes] | None = None) -> None:
        self.gen = gen


# list of nodes encoding / decoding
def decodelist(l: bytes, sep: bytes = b' ') -> list[NodeIdT]:
    if l:
        return [bin(v) for v in l.split(sep)]
    return []


def encodelist(l: list[bytes], sep: bytes = b' ') -> bytes:
    try:
        return sep.join(map(hex, l))
    except TypeError:
        raise


# batched call argument encoding


def escapebatcharg(plain: bytes) -> bytes:
    return (
        plain.replace(b':', b':c')
        .replace(b',', b':o')
        .replace(b';', b':s')
        .replace(b'=', b':e')
    )


def unescapebatcharg(escaped: bytes) -> bytes:
    return (
        escaped.replace(b':e', b'=')
        .replace(b':s', b';')
        .replace(b':o', b',')
        .replace(b':c', b':')
    )


# mapping of options accepted by getbundle and their types
#
# Meant to be extended by extensions. It is the extension's responsibility to
# ensure such options are properly processed in exchange.getbundle.
#
# supported types are:
#
# :nodes: list of binary nodes, transmitted as space-separated hex nodes
# :csv:   list of values, transmitted as comma-separated values
# :scsv:  set of values, transmitted as comma-separated values
# :plain: string with no transformation needed.
GETBUNDLE_ARGUMENTS: dict[bytes, bytes] = {
    b'heads': b'nodes',
    b'bookmarks': b'boolean',
    b'common': b'nodes',
    b'obsmarkers': b'boolean',
    b'phases': b'boolean',
    b'bundlecaps': b'scsv',
    b'listkeys': b'csv',
    b'cg': b'boolean',
    b'cbattempted': b'boolean',
    b'stream': b'boolean',
    b'includepats': b'csv',
    b'excludepats': b'csv',
}


class baseprotocolhandler(Protocol):
    """Abstract base class for wire protocol handlers.

    A wire protocol handler serves as an interface between protocol command
    handlers and the wire protocol transport layer. Protocol handlers provide
    methods to read command arguments, redirect stdio for the duration of
    the request, handle response types, etc.
    """

    @property
    @abc.abstractmethod
    def name(self) -> bytes:
        """The name of the protocol implementation.

        Used for uniquely identifying the transport type.
        """

    @abc.abstractmethod
    def getargs(self, args):
        """return the value for arguments in <args>

        For version 1 transports, returns a list of values in the same
        order they appear in ``args``. For version 2 transports, returns
        a dict mapping argument name to value.
        """

    @abc.abstractmethod
    def getprotocaps(self):
        """Returns the list of protocol-level capabilities of client

        Returns a list of capabilities as declared by the client for
        the current request (or connection for stateful protocol handlers)."""

    @abc.abstractmethod
    def getpayload(self):
        """Provide a generator for the raw payload.

        The caller is responsible for ensuring that the full payload is
        processed.
        """

    @abc.abstractmethod
    def mayberedirectstdio(self):
        """Context manager to possibly redirect stdio.

        The context manager yields a file-object like object that receives
        stdout and stderr output when the context manager is active. Or it
        yields ``None`` if no I/O redirection occurs.

        The intent of this context manager is to capture stdio output
        so it may be sent in the response. Some transports support streaming
        stdio to the client in real time. For these transports, stdio output
        won't be captured.
        """

    @abc.abstractmethod
    def client(self) -> bytes:
        """Returns a string representation of this client (as bytes)."""

    @abc.abstractmethod
    def addcapabilities(self, repo: RepoT, caps):
        """Adds advertised capabilities specific to this protocol.

        Receives the list of capabilities collected so far.

        Returns a list of capabilities. The passed in argument can be returned.
        """

    @abc.abstractmethod
    def checkperm(self, perm: bytes) -> None:
        """Validate that the client has permissions to perform a request.

        The argument is the permission required to proceed. If the client
        doesn't have that permission, the exception should raise or abort
        in a protocol specific manner.
        """


class commandentry:
    """Represents a declared wire protocol command."""

    def __init__(
        self,
        func,
        args: bytes = b'',
        transports=None,
        permission: bytes = b'push',
        cachekeyfn=None,
        extracapabilitiesfn=None,
    ) -> None:
        self.func = func
        self.args = args
        self.transports = transports or set()
        self.permission = permission
        self.cachekeyfn = cachekeyfn
        self.extracapabilitiesfn = extracapabilitiesfn

    def _merge(self, func, args):
        """Merge this instance with an incoming 2-tuple.

        This is called when a caller using the old 2-tuple API attempts
        to replace an instance. The incoming values are merged with
        data not captured by the 2-tuple and a new instance containing
        the union of the two objects is returned.
        """
        return commandentry(
            func,
            args=args,
            transports=set(self.transports),
            permission=self.permission,
        )

    # Old code treats instances as 2-tuples. So expose that interface.
    def __iter__(self):
        yield self.func
        yield self.args

    def __getitem__(self, i):
        if i == 0:
            return self.func
        elif i == 1:
            return self.args
        else:
            raise IndexError(b'can only access elements 0 and 1')


class commanddict(dict[bytes, commandentry]):
    """Container for registered wire protocol commands.

    It behaves like a dict. But __setitem__ is overwritten to allow silent
    coercion of values from 2-tuples for API compatibility.
    """

    def __setitem__(
        self, k: bytes, v: commandentry | tuple[NeedsTypeHint, NeedsTypeHint]
    ) -> None:
        if isinstance(v, commandentry):
            pass
        # Cast 2-tuples to commandentry instances.
        elif isinstance(v, tuple):
            if len(v) != 2:
                raise ValueError(b'command tuples must have exactly 2 elements')

            # It is common for extensions to wrap wire protocol commands via
            # e.g. ``wireproto.commands[x] = (newfn, args)``. Because callers
            # doing this aren't aware of the new API that uses objects to store
            # command entries, we automatically merge old state with new.
            if k in self:
                v = self[k]._merge(v[0], v[1])
            else:
                # Use default values from @wireprotocommand.
                v = commandentry(
                    v[0],
                    args=v[1],
                    transports=set(TRANSPORTS),
                    permission=b'push',
                )
        else:
            raise ValueError(
                b'command entries must be commandentry instances '
                b'or 2-tuples'
            )

        return super().__setitem__(k, v)

    def commandavailable(
        self, command: bytes, proto: baseprotocolhandler
    ) -> bool:
        """Determine if a command is available for the requested protocol."""
        assert proto.name in TRANSPORTS

        entry = self.get(command)

        if not entry:
            return False

        if proto.name not in entry.transports:
            return False

        return True


def supportedcompengines(ui: UiT, role: bytes) -> list[ICompressionEngine]:
    """Obtain the list of supported compression engines for a request."""
    assert role in (compression.CLIENTROLE, compression.SERVERROLE)

    compengines = compression.compengines.supportedwireengines(role)

    # Allow config to override default list and ordering.
    if role == compression.SERVERROLE:
        configengines = ui.configlist(b'server', b'compressionengines')
        config = b'server.compressionengines'
    else:
        # This is currently implemented mainly to facilitate testing. In most
        # cases, the server should be in charge of choosing a compression engine
        # because a server has the most to lose from a sub-optimal choice. (e.g.
        # CPU DoS due to an expensive engine or a network DoS due to poor
        # compression ratio).
        configengines = ui.configlist(
            b'experimental', b'clientcompressionengines'
        )
        config = b'experimental.clientcompressionengines'

    # No explicit config. Filter out the ones that aren't supposed to be
    # advertised and return default ordering.
    if not configengines:
        attr = 'serverpriority' if role == util.SERVERROLE else 'clientpriority'
        return [
            e for e in compengines if getattr(e.wireprotosupport(), attr) > 0
        ]

    # If compression engines are listed in the config, assume there is a good
    # reason for it (like server operators wanting to achieve specific
    # performance characteristics). So fail fast if the config references
    # unusable compression engines.
    validnames = {e.name() for e in compengines}
    invalidnames = {e for e in configengines if e not in validnames}
    if invalidnames:
        raise error.Abort(
            _(b'invalid compression engine defined in %s: %s')
            % (config, b', '.join(sorted(invalidnames)))
        )

    compengines = [e for e in compengines if e.name() in configengines]
    compengines = sorted(
        compengines, key=lambda e: configengines.index(e.name())
    )

    if not compengines:
        raise error.Abort(
            _(
                b'%s config option does not specify any known '
                b'compression engines'
            )
            % config,
            hint=_(b'usable compression engines: %s')
            % b', '.join(sorted(validnames)),
        )

    return compengines
