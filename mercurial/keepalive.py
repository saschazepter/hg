#   This library is free software; you can redistribute it and/or
#   modify it under the terms of the GNU Lesser General Public
#   License as published by the Free Software Foundation; either
#   version 2.1 of the License, or (at your option) any later version.
#
#   This library is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   Lesser General Public License for more details.
#
#   You should have received a copy of the GNU Lesser General Public
#   License along with this library; if not, see
#   <http://www.gnu.org/licenses/>.

# This file is part of urlgrabber, a high-level cross-protocol url-grabber
# Copyright 2002-2004 Michael D. Stenner, Ryan Tomayko

# Modified by Benoit Boissinot:
#  - fix for digest auth (inspired from urllib2.py @ Python v2.4)
# Modified by Dirkjan Ochtman:
#  - import md5 function from a local util module
# Modified by Augie Fackler:
#  - add safesend method and use it to prevent broken pipe errors
#    on large POST requests

"""An HTTP handler for urllib2 that supports HTTP 1.1 and keepalive.

>>> import urllib2
>>> from keepalive import HTTPHandler
>>> keepalive_handler = HTTPHandler()
>>> opener = urlreq.buildopener(keepalive_handler)
>>> urlreq.installopener(opener)
>>>
>>> fo = urlreq.urlopen('http://www.python.org')

If a connection to a given host is requested, and all of the existing
connections are still in use, another connection will be opened.  If
the handler tries to use an existing connection but it fails in some
way, it will be closed and removed from the pool.

To remove the handler, simply re-run build_opener with no arguments, and
install that opener.

You can explicitly close connections by using the close_connection()
method of the returned file-like object (described below) or you can
use the handler methods:

  close_connection(host)
  close_all()
  open_connections()

NOTE: using the close_connection and close_all methods of the handler
should be done with care when using multiple threads.
  * there is nothing that prevents another thread from creating new
    connections immediately after connections are closed
  * no checks are done to prevent in-use connections from being closed

>>> keepalive_handler.close_all()

EXTRA ATTRIBUTES AND METHODS

  Upon a status of 200, the object returned has a few additional
  attributes and methods, which should not be used if you want to
  remain consistent with the normal urllib2-returned objects:

    close_connection()  -  close the connection to the host
    readlines()         -  you know, readlines()
    status              -  the return status (i.e. 404)
    reason              -  english translation of status (i.e. 'File not found')

  If you want the best of both worlds, use this inside an
  AttributeError-catching try:

  >>> try: status = fo.status
  >>> except AttributeError: status = None

  Unfortunately, these are ONLY there if status == 200, so it's not
  easy to distinguish between non-200 responses.  The reason is that
  urllib2 tries to do clever things with error codes 301, 302, 401,
  and 407, and it wraps the object upon return.
"""

# $Id: keepalive.py,v 1.14 2006/04/04 21:00:32 mstenner Exp $

from __future__ import annotations

import collections
import hashlib
import sys
import threading

from .i18n import _
from .node import hex
from . import (
    pycompat,
    urllibcompat,
    util,
)
from .utils import procutil

httplib = util.httplib
urlerr = util.urlerr
urlreq = util.urlreq

DEBUG = None


class ConnectionManager:
    """
    The connection manager must be able to:
      * keep track of all existing
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._hostmap = collections.defaultdict(list)  # host -> [connection]
        self._connmap = {}  # map connections to host
        self._readymap = {}  # map connection to ready state

    def add(self, host, connection, ready):
        self._lock.acquire()
        try:
            self._hostmap[host].append(connection)
            self._connmap[connection] = host
            self._readymap[connection] = ready
        finally:
            self._lock.release()

    def remove(self, connection):
        self._lock.acquire()
        try:
            try:
                host = self._connmap[connection]
            except KeyError:
                pass
            else:
                del self._connmap[connection]
                del self._readymap[connection]
                self._hostmap[host].remove(connection)
                if not self._hostmap[host]:
                    del self._hostmap[host]
        finally:
            self._lock.release()

    def set_ready(self, connection, ready):
        try:
            self._readymap[connection] = ready
        except KeyError:
            pass

    def get_ready_conn(self, host):
        conn = None
        self._lock.acquire()
        try:
            for c in self._hostmap[host]:
                if self._readymap[c]:
                    self._readymap[c] = False
                    conn = c
                    break
        finally:
            self._lock.release()
        return conn

    def get_all(self, host=None):
        if host:
            return list(self._hostmap[host])
        else:
            return dict(
                {h: list(conns) for (h, conns) in self._hostmap.items()}
            )


class KeepAliveHandler:
    def __init__(self, timeout=None):
        self._cm = ConnectionManager()
        self._timeout = timeout
        self.requestscount = 0
        self.sentbytescount = 0

    #### Connection Management
    def open_connections(self):
        """return a list of connected hosts and the number of connections
        to each.  [('foo.com:80', 2), ('bar.org', 1)]"""
        return [(host, len(li)) for (host, li) in self._cm.get_all().items()]

    def close_connection(self, host):
        """close connection(s) to <host>
        host is the host:port spec, as in 'www.cnn.com:8080' as passed in.
        no error occurs if there is no connection to that host."""
        for h in self._cm.get_all(host):
            self._cm.remove(h)
            h.close()

    def close_all(self):
        """close all open connections"""
        for host, conns in self._cm.get_all().items():
            for h in conns:
                self._cm.remove(h)
                h.close()

    def _request_closed(self, request, host, connection):
        """tells us that this request is now closed and that the
        connection is ready for another request"""
        self._cm.set_ready(connection, True)

    def _remove_connection(self, host, connection, close=0):
        if close:
            connection.close()
        self._cm.remove(connection)

    #### Transaction Execution
    def http_open(self, req):
        return self.do_open(HTTPConnection, req)

    def do_open(self, http_class, req):
        host = urllibcompat.gethost(req)
        if not host:
            raise urlerr.urlerror(b'no host given')
        if req._tunnel_host:  # proxy
            realhost = req._tunnel_host
        else:
            realhost = host

        try:
            h = self._cm.get_ready_conn(realhost)
            while h:
                r = self._reuse_connection(h, req, realhost)

                # if this response is non-None, then it worked and we're
                # done.  Break out, skipping the else block.
                if r:
                    break

                # connection is bad - possibly closed by server
                # discard it and ask for the next free connection
                h.close()
                self._cm.remove(h)
                h = self._cm.get_ready_conn(realhost)
            else:
                # no (working) free connections were found.  Create a new one.
                h = http_class(host, timeout=self._timeout)
                if DEBUG:
                    DEBUG.info(
                        b"creating new connection to %s (%d)", host, id(h)
                    )
                self._cm.add(realhost, h, False)
                self._start_transaction(h, req)
                r = h.getresponse()
        # The string form of BadStatusLine is the status line. Add some context
        # to make the error message slightly more useful.
        except httplib.BadStatusLine as err:
            raise urlerr.urlerror(
                _(b'bad HTTP status line: %s') % pycompat.sysbytes(err.line)
            )
        except (OSError, httplib.HTTPException) as err:
            raise urlerr.urlerror(err)

        # If not a persistent connection, don't try to reuse it. Look
        # for this using getattr() since vcr doesn't define this
        # attribute, and in that case always close the connection.
        if getattr(r, 'will_close', True):
            self._cm.remove(h)

        if DEBUG:
            DEBUG.info(b"STATUS: %s, %s", r.status, r.reason)
        r._handler = self
        r._host = host
        r._url = req.get_full_url()
        r._connection = h
        r.code = r.status
        r.headers = r.msg
        r.msg = r.reason

        return r

    def _reuse_connection(self, h, req, host):
        """start the transaction with a re-used connection
        return a response object (r) upon success or None on failure.
        This DOES not close or remove bad connections in cases where
        it returns.  However, if an unexpected exception occurs, it
        will close and remove the connection before re-raising.
        """
        try:
            self._start_transaction(h, req)
            r = h.getresponse()
            # note: just because we got something back doesn't mean it
            # worked.  We'll check the version below, too.
        except (OSError, httplib.HTTPException):
            r = None
        except:  # re-raises
            # adding this block just in case we've missed
            # something we will still raise the exception, but
            # lets try and close the connection and remove it
            # first.  We previously got into a nasty loop
            # where an exception was uncaught, and so the
            # connection stayed open.  On the next try, the
            # same exception was raised, etc.  The trade-off is
            # that it's now possible this call will raise
            # a DIFFERENT exception
            if DEBUG:
                DEBUG.error(
                    b"unexpected exception - closing connection to %s (%d)",
                    host,
                    id(h),
                )
            self._cm.remove(h)
            h.close()
            raise

        if r is None or r.version == 9:
            # httplib falls back to assuming HTTP 0.9 if it gets a
            # bad header back.  This is most likely to happen if
            # the socket has been closed by the server since we
            # last used the connection.
            if DEBUG:
                DEBUG.info(
                    b"failed to re-use connection to %s (%d)", host, id(h)
                )
            r = None
        else:
            if DEBUG:
                DEBUG.info(b"re-using connection to %s (%d)", host, id(h))

        return r

    def _start_transaction(self, h, req):
        oldbytescount = getattr(h, 'sentbytescount', 0)

        # What follows mostly reimplements HTTPConnection.request()
        # except it adds self.parent.addheaders in the mix and sends headers
        # in a deterministic order (to make testing easier).
        headers = util.sortdict(self.parent.addheaders)
        headers.update(sorted(req.headers.items()))
        headers.update(sorted(req.unredirected_hdrs.items()))
        headers = util.sortdict((n.lower(), v) for n, v in headers.items())
        skipheaders = {}
        for n in ('host', 'accept-encoding'):
            if n in headers:
                skipheaders['skip_' + n.replace('-', '_')] = 1
        try:
            if urllibcompat.hasdata(req):
                data = urllibcompat.getdata(req)
                h.putrequest(
                    req.get_method(),
                    urllibcompat.getselector(req),
                    **skipheaders,
                )
                if 'content-type' not in headers:
                    h.putheader(
                        'Content-type', 'application/x-www-form-urlencoded'
                    )
                if 'content-length' not in headers:
                    h.putheader('Content-length', '%d' % len(data))
            else:
                h.putrequest(
                    req.get_method(),
                    urllibcompat.getselector(req),
                    **skipheaders,
                )
        except OSError as err:
            raise urlerr.urlerror(err)
        for k, v in headers.items():
            h.putheader(k, v)
        h.endheaders()
        if urllibcompat.hasdata(req):
            h.send(data)

        # This will fail to record events in case of I/O failure. That's OK.
        self.requestscount += 1
        self.sentbytescount += getattr(h, 'sentbytescount', 0) - oldbytescount

        try:
            self.parent.requestscount += 1
            self.parent.sentbytescount += (
                getattr(h, 'sentbytescount', 0) - oldbytescount
            )
        except AttributeError:
            pass


class HTTPHandler(KeepAliveHandler, urlreq.httphandler):
    pass


class HTTPResponse(httplib.HTTPResponse):
    # we need to subclass HTTPResponse in order to
    # 1) add close_connection() method
    # 2) add geturl() method
    # 3) add accounting for read(), readlines() and readinto()

    def __init__(self, sock, debuglevel=0, strict=0, method=None):
        httplib.HTTPResponse.__init__(
            self, sock, debuglevel=debuglevel, method=method
        )
        self.fileno = sock.fileno
        self.code = None
        self.receivedbytescount = 0
        self._rbuf = b''
        self._rbufsize = 8096
        self._handler = None  # inserted by the handler later
        self._host = None  # (same)
        self._url = None  # (same)
        self._connection = None  # (same)

    # Python 2.7 has a single close() which closes the socket handle.
    # This method was effectively renamed to _close_conn() in Python 3. But
    # there is also a close(). _close_conn() is called by methods like
    # read().

    def close(self):
        if self.fp:
            self.fp.close()
            self.fp = None
            if self._handler:
                self._handler._request_closed(
                    self, self._host, self._connection
                )

    def _close_conn(self):
        self.close()

    def close_connection(self):
        self._handler._remove_connection(self._host, self._connection, close=1)
        self.close()

    def geturl(self):
        return self._url

    def read(self, amt=None):
        data = super().read(amt)
        self.receivedbytescount += len(data)
        if self._connection is not None:
            self._connection.receivedbytescount += len(data)
        if self._handler is not None:
            self._handler.parent.receivedbytescount += len(data)
        return data

    def readline(self, limit: int = -1):
        data = super().readline(limit=limit)
        self.receivedbytescount += len(data)
        if self._connection is not None:
            self._connection.receivedbytescount += len(data)
        if self._handler is not None:
            self._handler.parent.receivedbytescount += len(data)
        return data

    def readinto(self, dest):
        got = super().readinto(dest)
        self.receivedbytescount += got
        if self._connection is not None:
            self._connection.receivedbytescount += got
        if self._handler is not None:
            self._handler.parent.receivedbytescount += got
        return got


def safesend(self, str):
    """Send `str' to the server.

    Shamelessly ripped off from httplib to patch a bad behavior.
    """
    # _broken_pipe_resp is an attribute we set in this function
    # if the socket is closed while we're sending data but
    # the server sent us a response before hanging up.
    # In that case, we want to pretend to send the rest of the
    # outgoing data, and then let the user use getresponse()
    # (which we wrap) to get this last response before
    # opening a new socket.
    if getattr(self, '_broken_pipe_resp', None) is not None:
        return

    if self.sock is None:
        if self.auto_open:
            self.connect()
        else:
            raise httplib.NotConnected

    # send the data to the server. if we get a broken pipe, then close
    # the socket. we want to reconnect when somebody tries to send again.
    #
    # NOTE: we DO propagate the error, though, because we cannot simply
    #       ignore the error... the caller will know if they can retry.
    if self.debuglevel > 0:
        print(b"send:", repr(str))
    try:
        blocksize = 8192
        read = getattr(str, 'read', None)
        if read is not None:
            if self.debuglevel > 0:
                print(b"sending a read()able")
            data = read(blocksize)
            while data:
                self.sock.sendall(data)
                self.sentbytescount += len(data)
                data = read(blocksize)
        else:
            self.sock.sendall(str)
            self.sentbytescount += len(str)
    except BrokenPipeError:
        if self._HTTPConnection__state == httplib._CS_REQ_SENT:
            self._broken_pipe_resp = None
            self._broken_pipe_resp = self.getresponse()
            reraise = False
        else:
            reraise = True
        self.close()
        if reraise:
            raise


def wrapgetresponse(cls):
    """Wraps getresponse in cls with a broken-pipe sane version."""

    def safegetresponse(self):
        # In safesend() we might set the _broken_pipe_resp
        # attribute, in which case the socket has already
        # been closed and we just need to give them the response
        # back. Otherwise, we use the normal response path.
        r = getattr(self, '_broken_pipe_resp', None)
        if r is not None:
            return r
        return cls.getresponse(self)

    safegetresponse.__doc__ = cls.getresponse.__doc__
    return safegetresponse


class HTTPConnection(httplib.HTTPConnection):
    # url.httpsconnection inherits from this. So when adding/removing
    # attributes, be sure to audit httpsconnection() for unintended
    # consequences.

    # use the modified response class
    response_class = HTTPResponse
    send = safesend
    getresponse = wrapgetresponse(httplib.HTTPConnection)

    def __init__(self, *args, **kwargs):
        httplib.HTTPConnection.__init__(self, *args, **kwargs)
        self.sentbytescount = 0
        self.receivedbytescount = 0

    def __repr__(self):
        base = super().__repr__()
        local = "(unconnected)"
        s = self.sock
        if s:
            try:
                local = "%s:%d" % s.getsockname()
            except OSError:
                pass  # Likely not connected
        return "<%s: %s <--> %s:%d>" % (base, local, self.host, self.port)


#########################################################################
#####   TEST FUNCTIONS
#########################################################################


def continuity(url):
    md5 = hashlib.md5
    format = b'%25s: %s'

    # first fetch the file with the normal http handler
    opener = urlreq.buildopener()
    urlreq.installopener(opener)
    fo = urlreq.urlopen(url)
    foo = fo.read()
    fo.close()
    m = md5(foo)
    print(format % (b'normal urllib', hex(m.digest())))

    # now install the keepalive handler and try again
    opener = urlreq.buildopener(HTTPHandler())
    urlreq.installopener(opener)

    fo = urlreq.urlopen(url)
    foo = fo.read()
    fo.close()
    m = md5(foo)
    print(format % (b'keepalive read', hex(m.digest())))

    fo = urlreq.urlopen(url)
    foo = b''
    while True:
        f = fo.readline()
        if f:
            foo = foo + f
        else:
            break
    fo.close()
    m = md5(foo)
    print(format % (b'keepalive readline', hex(m.digest())))


def comp(N, url):
    print(b'  making %i connections to:\n  %s' % (N, url))

    procutil.stdout.write(b'  first using the normal urllib handlers')
    # first use normal opener
    opener = urlreq.buildopener()
    urlreq.installopener(opener)
    t1 = fetch(N, url)
    print(b'  TIME: %.3f s' % t1)

    procutil.stdout.write(b'  now using the keepalive handler       ')
    # now install the keepalive handler and try again
    opener = urlreq.buildopener(HTTPHandler())
    urlreq.installopener(opener)
    t2 = fetch(N, url)
    print(b'  TIME: %.3f s' % t2)
    print(b'  improvement factor: %.2f' % (t1 / t2))


def fetch(N, url, delay=0):
    import time

    lens = []
    starttime = time.time()
    for i in range(N):
        if delay and i > 0:
            time.sleep(delay)
        fo = urlreq.urlopen(url)
        foo = fo.read()
        fo.close()
        lens.append(len(foo))
    diff = time.time() - starttime

    j = 0
    for i in lens[1:]:
        j = j + 1
        if not i == lens[0]:
            print(b"WARNING: inconsistent length on read %i: %i" % (j, i))

    return diff


def test_timeout(url):
    global DEBUG
    dbbackup = DEBUG

    class FakeLogger:
        def debug(self, msg, *args):
            print(msg % args)

        info = warning = error = debug

    DEBUG = FakeLogger()
    print(b"  fetching the file to establish a connection")
    fo = urlreq.urlopen(url)
    data1 = fo.read()
    fo.close()

    i = 20
    print(b"  waiting %i seconds for the server to close the connection" % i)
    while i > 0:
        procutil.stdout.write(b'\r  %2i' % i)
        procutil.stdout.flush()
        time.sleep(1)
        i -= 1
    procutil.stderr.write(b'\r')

    print(b"  fetching the file a second time")
    fo = urlreq.urlopen(url)
    data2 = fo.read()
    fo.close()

    if data1 == data2:
        print(b'  data are identical')
    else:
        print(b'  ERROR: DATA DIFFER')

    DEBUG = dbbackup


def test(url, N=10):
    print(b"performing continuity test (making sure stuff isn't corrupted)")
    continuity(url)
    print(b'')
    print(b"performing speed comparison")
    comp(N, url)
    print(b'')
    print(b"performing dropped-connection check")
    test_timeout(url)


if __name__ == '__main__':
    import time

    try:
        N = int(sys.argv[1])
        url = sys.argv[2]
    except (IndexError, ValueError):
        print("%s <integer> <url>" % sys.argv[0])
    else:
        test(url, N)
