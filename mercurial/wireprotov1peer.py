# wireprotov1peer.py - Client-side functionality for wire protocol version 1.
#
# Copyright 2005-2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import sys
import weakref

from concurrent import futures
from .i18n import _
from .node import bin
from . import (
    bundle2,
    changegroup as changegroupmod,
    encoding,
    error,
    pushkey as pushkeymod,
    pycompat,
    util,
    wireprototypes,
)
from .interfaces import (
    repository,
)
from .utils import hashutil

urlreq = util.urlreq


def batchable(f):
    """annotation for batchable methods

    Such methods must implement a coroutine as follows:

    @batchable
    def sample(self, one, two=None):
        # Build list of encoded arguments suitable for your wire protocol:
        encoded_args = [('one', encode(one),), ('two', encode(two),)]
        # Return it, along with a function that will receive the result
        # from the batched request.
        return encoded_args, decode

    The decorator returns a function which wraps this coroutine as a plain
    method, but adds the original method as an attribute called "batchable",
    which is used by remotebatch to split the call into separate encoding and
    decoding phases.
    """

    def plain(*args, **opts):
        encoded_args_or_res, decode = f(*args, **opts)
        if not decode:
            return encoded_args_or_res  # a local result in this case
        self = args[0]
        cmd = pycompat.bytesurl(f.__name__)  # ensure cmd is ascii bytestr
        encoded_res = self._submitone(cmd, encoded_args_or_res)
        return decode(encoded_res)

    setattr(plain, 'batchable', f)
    setattr(plain, '__name__', f.__name__)
    return plain


def encodebatchcmds(req):
    """Return a ``cmds`` argument value for the ``batch`` command."""
    escapearg = wireprototypes.escapebatcharg

    cmds = []
    for op, argsdict in req:
        # Old servers didn't properly unescape argument names. So prevent
        # the sending of argument names that may not be decoded properly by
        # servers.
        assert all(escapearg(k) == k for k in argsdict)

        args = b','.join(
            b'%s=%s' % (escapearg(k), escapearg(v)) for k, v in argsdict.items()
        )
        cmds.append(b'%s %s' % (op, args))

    return b';'.join(cmds)


class unsentfuture(futures.Future):
    """A Future variation to represent an unsent command.

    Because we buffer commands and don't submit them immediately, calling
    ``result()`` on an unsent future could deadlock. Futures for buffered
    commands are represented by this type, which wraps ``result()`` to
    call ``sendcommands()``.
    """

    _peerexecutor: peerexecutor

    def result(self, timeout=None):
        if self.done():
            return futures.Future.result(self, timeout)

        self._peerexecutor.sendcommands()

        # This looks like it will infinitely recurse. However,
        # sendcommands() should modify __class__. This call serves as a check
        # on that.
        return self.result(timeout)


class peerexecutor(repository.ipeercommandexecutor):
    def __init__(self, peer):
        self._peer = peer
        self._sent = False
        self._closed = False
        self._calls = []
        self._futures = weakref.WeakSet()
        self._responseexecutor = None
        self._responsef = None

    def __enter__(self):
        return self

    def __exit__(self, exctype, excvalee, exctb):
        self.close()

    def callcommand(self, command, args):
        if self._sent:
            raise error.ProgrammingError(
                b'callcommand() cannot be used after commands are sent'
            )

        if self._closed:
            raise error.ProgrammingError(
                b'callcommand() cannot be used after close()'
            )

        # Commands are dispatched through methods on the peer.
        fn = getattr(self._peer, pycompat.sysstr(command), None)

        if not fn:
            raise error.ProgrammingError(
                b'cannot call command %s: method of same name not available '
                b'on peer' % command
            )

        # Commands are either batchable or they aren't. If a command
        # isn't batchable, we send it immediately because the executor
        # can no longer accept new commands after a non-batchable command.
        # If a command is batchable, we queue it for later. But we have
        # to account for the case of a non-batchable command arriving after
        # a batchable one and refuse to service it.

        def addcall():
            f = futures.Future()
            self._futures.add(f)
            self._calls.append((command, args, fn, f))
            return f

        if getattr(fn, 'batchable', False):
            f = addcall()

            # But since we don't issue it immediately, we wrap its result()
            # to trigger sending so we avoid deadlocks.
            f.__class__ = unsentfuture
            f._peerexecutor = self
        else:
            if self._calls:
                raise error.ProgrammingError(
                    b'%s is not batchable and cannot be called on a command '
                    b'executor along with other commands' % command
                )

            f = addcall()

            # Non-batchable commands can never coexist with another command
            # in this executor. So send the command immediately.
            self.sendcommands()

        return f

    def sendcommands(self):
        if self._sent:
            return

        if not self._calls:
            return

        self._sent = True

        # Unhack any future types so caller seens a clean type and to break
        # cycle between us and futures.
        for f in self._futures:
            if isinstance(f, unsentfuture):
                f.__class__ = futures.Future
                f._peerexecutor = None

        calls = self._calls
        # Mainly to destroy references to futures.
        self._calls = None

        # Simple case of a single command. We call it synchronously.
        if len(calls) == 1:
            command, args, fn, f = calls[0]

            # Future was cancelled. Ignore it.
            if not f.set_running_or_notify_cancel():
                return

            try:
                result = fn(**pycompat.strkwargs(args))
            except Exception:
                pycompat.future_set_exception_info(f, sys.exc_info()[1:])
            else:
                f.set_result(result)

            return

        # Batch commands are a bit harder. First, we have to deal with the
        # @batchable coroutine. That's a bit annoying. Furthermore, we also
        # need to preserve streaming. i.e. it should be possible for the
        # futures to resolve as data is coming in off the wire without having
        # to wait for the final byte of the final response. We do this by
        # spinning up a thread to read the responses.

        requests = []
        states = []

        for command, args, fn, f in calls:
            # Future was cancelled. Ignore it.
            if not f.set_running_or_notify_cancel():
                continue

            try:
                encoded_args_or_res, decode = fn.batchable(
                    fn.__self__, **pycompat.strkwargs(args)
                )
            except Exception:
                pycompat.future_set_exception_info(f, sys.exc_info()[1:])
                return

            if not decode:
                f.set_result(encoded_args_or_res)
            else:
                requests.append((command, encoded_args_or_res))
                states.append((command, f, batchable, decode))

        if not requests:
            return

        # This will emit responses in order they were executed.
        wireresults = self._peer._submitbatch(requests)

        # The use of a thread pool executor here is a bit weird for something
        # that only spins up a single thread. However, thread management is
        # hard and it is easy to encounter race conditions, deadlocks, etc.
        # concurrent.futures already solves these problems and its thread pool
        # executor has minimal overhead. So we use it.
        self._responseexecutor = futures.ThreadPoolExecutor(1)
        self._responsef = self._responseexecutor.submit(
            self._readbatchresponse, states, wireresults
        )

    def close(self):
        self.sendcommands()

        if self._closed:
            return

        self._closed = True

        if not self._responsef:
            return

        # We need to wait on our in-flight response and then shut down the
        # executor once we have a result.
        try:
            self._responsef.result()
        finally:
            # Help pytype- this is initialized by self.sendcommands(), called
            # above.
            assert self._responseexecutor is not None
            self._responseexecutor.shutdown(wait=True)
            self._responsef = None
            self._responseexecutor = None

            # If any of our futures are still in progress, mark them as
            # errored. Otherwise a result() could wait indefinitely.
            for f in self._futures:
                if not f.done():
                    f.set_exception(
                        error.ResponseError(
                            _(b'unfulfilled batch command response'), None
                        )
                    )

            self._futures = None

    def _readbatchresponse(self, states, wireresults):
        # Executes in a thread to read data off the wire.

        for command, f, batchable, decode in states:
            # Grab raw result off the wire and teach the internal future
            # about it.
            try:
                remoteresult = next(wireresults)
            except StopIteration:
                # This can happen in particular because next(batchable)
                # in the previous iteration can call peer._abort, which
                # may close the peer.
                f.set_exception(
                    error.ResponseError(
                        _(b'unfulfilled batch command response'), None
                    )
                )
            else:
                try:
                    result = decode(remoteresult)
                except Exception:
                    pycompat.future_set_exception_info(f, sys.exc_info()[1:])
                else:
                    f.set_result(result)


class wirepeer(
    repository.peer, repository.ipeercommands, repository.ipeerlegacycommands
):
    """Client-side interface for communicating with a peer repository.

    Methods commonly call wire protocol commands of the same name.

    See also httppeer.py and sshpeer.py for protocol-specific
    implementations of this interface.
    """

    def commandexecutor(self):
        return peerexecutor(self)

    # Begin of ipeercommands interface.

    def clonebundles(self):
        if self.capable(b'clonebundles_manifest'):
            return self._call(b'clonebundles_manifest')
        else:
            self.requirecap(b'clonebundles', _(b'clone bundles'))
            return self._call(b'clonebundles')

    def _finish_inline_clone_bundle(self, stream):
        pass  # allow override for httppeer

    def get_cached_bundle_inline(self, path):
        stream = self._callstream(b"get_cached_bundle_inline", path=path)
        length = util.uvarintdecodestream(stream)

        # SSH streams will block if reading more than length
        yield from util.filechunkiter(stream, limit=length)

        self._finish_inline_clone_bundle(stream)

    @batchable
    def lookup(self, key):
        self.requirecap(b'lookup', _(b'look up remote revision'))

        def decode(d):
            success, data = d[:-1].split(b" ", 1)
            if int(success):
                return bin(data)
            else:
                self._abort(error.RepoError(data))

        return {b'key': encoding.fromlocal(key)}, decode

    @batchable
    def heads(self):
        def decode(d):
            try:
                return wireprototypes.decodelist(d[:-1])
            except ValueError:
                self._abort(error.ResponseError(_(b"unexpected response:"), d))

        return {}, decode

    @batchable
    def known(self, nodes):
        def decode(d):
            try:
                return [bool(int(b)) for b in pycompat.iterbytestr(d)]
            except ValueError:
                self._abort(error.ResponseError(_(b"unexpected response:"), d))

        return {b'nodes': wireprototypes.encodelist(nodes)}, decode

    @batchable
    def branchmap(self):
        def decode(d):
            try:
                branchmap = {}
                for branchpart in d.splitlines():
                    branchname, branchheads = branchpart.split(b' ', 1)
                    branchname = encoding.tolocal(urlreq.unquote(branchname))
                    branchheads = wireprototypes.decodelist(branchheads)
                    branchmap[branchname] = branchheads
                return branchmap
            except TypeError:
                self._abort(error.ResponseError(_(b"unexpected response:"), d))

        return {}, decode

    @batchable
    def listkeys(self, namespace):
        if not self.capable(b'pushkey'):
            return {}, None
        self.ui.debug(b'preparing listkeys for "%s"\n' % namespace)

        def decode(d):
            self.ui.debug(
                b'received listkey for "%s": %i bytes\n' % (namespace, len(d))
            )
            return pushkeymod.decodekeys(d)

        return {b'namespace': encoding.fromlocal(namespace)}, decode

    @batchable
    def pushkey(self, namespace, key, old, new):
        if not self.capable(b'pushkey'):
            return False, None
        self.ui.debug(b'preparing pushkey for "%s:%s"\n' % (namespace, key))

        def decode(d):
            d, output = d.split(b'\n', 1)
            try:
                d = bool(int(d))
            except ValueError:
                raise error.ResponseError(
                    _(b'push failed (unexpected response):'), d
                )
            for l in output.splitlines(True):
                self.ui.status(_(b'remote: '), l)
            return d

        return {
            b'namespace': encoding.fromlocal(namespace),
            b'key': encoding.fromlocal(key),
            b'old': encoding.fromlocal(old),
            b'new': encoding.fromlocal(new),
        }, decode

    def stream_out(self):
        return self._callstream(b'stream_out')

    def getbundle(self, source, **kwargs):
        kwargs = pycompat.byteskwargs(kwargs)
        self.requirecap(b'getbundle', _(b'look up remote changes'))
        opts = {}
        bundlecaps = kwargs.get(b'bundlecaps') or set()
        for key, value in kwargs.items():
            if value is None:
                continue
            keytype = wireprototypes.GETBUNDLE_ARGUMENTS.get(key)
            if keytype is None:
                raise error.ProgrammingError(
                    b'Unexpectedly None keytype for key %s' % key
                )
            elif keytype == b'nodes':
                value = wireprototypes.encodelist(value)
            elif keytype == b'csv':
                value = b','.join(value)
            elif keytype == b'scsv':
                value = b','.join(sorted(value))
            elif keytype == b'boolean':
                value = b'%i' % bool(value)
            elif keytype != b'plain':
                raise KeyError(b'unknown getbundle option type %s' % keytype)
            opts[key] = value
        f = self._callcompressable(b"getbundle", **pycompat.strkwargs(opts))
        if any(cap.startswith(b'HG2') for cap in bundlecaps):
            return bundle2.getunbundler(self.ui, f)
        else:
            return changegroupmod.cg1unpacker(f, b'UN')

    def unbundle(self, bundle, heads, url):
        """Send cg (a readable file-like object representing the
        changegroup to push, typically a chunkbuffer object) to the
        remote server as a bundle.

        When pushing a bundle10 stream, return an integer indicating the
        result of the push (see changegroup.apply()).

        When pushing a bundle20 stream, return a bundle20 stream.

        `url` is the url the client thinks it's pushing to, which is
        visible to hooks.
        """

        if heads != [b'force'] and self.capable(b'unbundlehash'):
            heads = wireprototypes.encodelist(
                [b'hashed', hashutil.sha1(b''.join(sorted(heads))).digest()]
            )
        else:
            heads = wireprototypes.encodelist(heads)

        if hasattr(bundle, 'deltaheader'):
            # this a bundle10, do the old style call sequence
            ret, output = self._callpush(b"unbundle", bundle, heads=heads)
            if ret == b"":
                raise error.ResponseError(_(b'push failed:'), output)
            try:
                ret = int(ret)
            except ValueError:
                raise error.ResponseError(
                    _(b'push failed (unexpected response):'), ret
                )

            for l in output.splitlines(True):
                self.ui.status(_(b'remote: '), l)
        else:
            # bundle2 push. Send a stream, fetch a stream.
            stream = self._calltwowaystream(b'unbundle', bundle, heads=heads)
            ret = bundle2.getunbundler(self.ui, stream)
        return ret

    # End of ipeercommands interface.

    # Begin of ipeerlegacycommands interface.

    def branches(self, nodes):
        n = wireprototypes.encodelist(nodes)
        d = self._call(b"branches", nodes=n)
        try:
            br = [tuple(wireprototypes.decodelist(b)) for b in d.splitlines()]
            return br
        except ValueError:
            self._abort(error.ResponseError(_(b"unexpected response:"), d))

    def between(self, pairs):
        batch = 8  # avoid giant requests
        r = []
        for i in range(0, len(pairs), batch):
            n = b" ".join(
                [
                    wireprototypes.encodelist(p, b'-')
                    for p in pairs[i : i + batch]
                ]
            )
            d = self._call(b"between", pairs=n)
            try:
                r.extend(
                    wireprototypes.decodelist(l) if l else []
                    for l in d.splitlines()
                )
            except ValueError:
                self._abort(error.ResponseError(_(b"unexpected response:"), d))
        return r

    def changegroup(self, nodes, source):
        n = wireprototypes.encodelist(nodes)
        f = self._callcompressable(b"changegroup", roots=n)
        return changegroupmod.cg1unpacker(f, b'UN')

    def changegroupsubset(self, bases, heads, source):
        self.requirecap(b'changegroupsubset', _(b'look up remote changes'))
        bases = wireprototypes.encodelist(bases)
        heads = wireprototypes.encodelist(heads)
        f = self._callcompressable(
            b"changegroupsubset", bases=bases, heads=heads
        )
        return changegroupmod.cg1unpacker(f, b'UN')

    # End of ipeerlegacycommands interface.

    def _submitbatch(self, req):
        """run batch request <req> on the server

        Returns an iterator of the raw responses from the server.
        """
        ui = self.ui
        if ui.debugflag and ui.configbool(b'devel', b'debug.peer-request'):
            ui.debug(b'devel-peer-request: batched-content\n')
            for op, args in req:
                msg = b'devel-peer-request:    - %s (%d arguments)\n'
                ui.debug(msg % (op, len(args)))

        unescapearg = wireprototypes.unescapebatcharg

        rsp = self._callstream(b"batch", cmds=encodebatchcmds(req))
        chunk = rsp.read(1024)
        work = [chunk]
        while chunk:
            while b';' not in chunk and chunk:
                chunk = rsp.read(1024)
                work.append(chunk)
            merged = b''.join(work)
            while b';' in merged:
                one, merged = merged.split(b';', 1)
                yield unescapearg(one)
            chunk = rsp.read(1024)
            work = [merged, chunk]
        yield unescapearg(b''.join(work))

    def _submitone(self, op, args):
        return self._call(op, **pycompat.strkwargs(args))

    def debugwireargs(self, one, two, three=None, four=None, five=None):
        # don't pass optional arguments left at their default value
        opts = {}
        if three is not None:
            opts['three'] = three
        if four is not None:
            opts['four'] = four
        return self._call(b'debugwireargs', one=one, two=two, **opts)

    def _call(self, cmd, **args):
        """execute <cmd> on the server

        The command is expected to return a simple string.

        returns the server reply as a string."""
        raise NotImplementedError()

    def _callstream(self, cmd, **args):
        """execute <cmd> on the server

        The command is expected to return a stream. Note that if the
        command doesn't return a stream, _callstream behaves
        differently for ssh and http peers.

        returns the server reply as a file like object.
        """
        raise NotImplementedError()

    def _callcompressable(self, cmd, **args):
        """execute <cmd> on the server

        The command is expected to return a stream.

        The stream may have been compressed in some implementations. This
        function takes care of the decompression. This is the only difference
        with _callstream.

        returns the server reply as a file like object.
        """
        raise NotImplementedError()

    def _callpush(self, cmd, fp, **args):
        """execute a <cmd> on server

        The command is expected to be related to a push. Push has a special
        return method.

        returns the server reply as a (ret, output) tuple. ret is either
        empty (error) or a stringified int.
        """
        raise NotImplementedError()

    def _calltwowaystream(self, cmd, fp, **args):
        """execute <cmd> on server

        The command will send a stream to the server and get a stream in reply.
        """
        raise NotImplementedError()

    def _abort(self, exception):
        """clearly abort the wire protocol connection and raise the exception"""
        raise NotImplementedError()
