#!/usr/bin/env python3


__doc__ = """Tiny HTTP Proxy.

This module implements GET, HEAD, POST, PUT and DELETE methods
on BaseHTTPServer, and behaves as an HTTP proxy.  The CONNECT
method is also implemented experimentally, but has not been
tested yet.

Any help will be greatly appreciated.           SUZUKI Hisao
"""

__version__ = "0.2.1"

import optparse
import os
import select
import socket
import sys

from mercurial import (
    pycompat,
    util,
)

httpserver = util.httpserver
socketserver = util.socketserver
urlreq = util.urlreq

if os.environ.get('HGIPV6', '0') == '1':
    family = socket.AF_INET6
else:
    family = socket.AF_INET


class ProxyHandler(httpserver.basehttprequesthandler):
    __base = httpserver.basehttprequesthandler
    __base_handle = __base.handle

    server_version = "TinyHTTPProxy/" + __version__
    rbufsize = 0  # self.rfile Be unbuffered

    def handle(self):
        (ip, port) = self.client_address
        allowed = getattr(self, 'allowed_clients', None)
        if allowed is not None and ip not in allowed:
            self.raw_requestline = self.rfile.readline()
            if self.parse_request():
                self.send_error(403)
        else:
            self.__base_handle()

    def log_request(self, code='-', size='-'):
        xheaders = [h for h in self.headers.items() if h[0].startswith('x-')]
        self.log_message(
            '"%s" %s %s%s',
            self.requestline,
            str(code),
            str(size),
            ''.join([' %s:%s' % h for h in sorted(xheaders)]),
        )
        # Flush for Windows, so output isn't lost on TerminateProcess()
        sys.stdout.flush()
        sys.stderr.flush()

    def _connect_to(self, netloc, soc):
        i = netloc.find(':')
        if i >= 0:
            host_port = netloc[:i], int(netloc[i + 1 :])
        else:
            host_port = netloc, 80
        print("\t" "connect to %s:%d" % host_port)
        try:
            soc.connect(host_port)
        except OSError as e:
            self.send_error(404, e.strerror)
            return 0
        return 1

    def do_CONNECT(self):
        soc = socket.socket(family, socket.SOCK_STREAM)
        try:
            if self._connect_to(self.path, soc):
                self.log_request(200)
                self.wfile.write(
                    pycompat.bytestr(self.protocol_version)
                    + b" 200 Connection established\r\n"
                )
                self.wfile.write(
                    b"Proxy-agent: %s\r\n"
                    % pycompat.bytestr(self.version_string())
                )
                self.wfile.write(b"\r\n")
                self._read_write(soc, 300)
        finally:
            print("\t" "bye")
            soc.close()
            self.connection.close()

    def do_GET(self):
        (scm, netloc, path, params, query, fragment) = urlreq.urlparse(
            self.path, 'http'
        )
        if scm != 'http' or fragment or not netloc:
            self.send_error(400, "bad url %s" % self.path)
            return
        soc = socket.socket(family, socket.SOCK_STREAM)
        try:
            if self._connect_to(netloc, soc):
                self.log_request()
                url = urlreq.urlunparse(('', '', path, params, query, ''))
                soc.send(
                    b"%s %s %s\r\n"
                    % (
                        pycompat.bytestr(self.command),
                        pycompat.bytestr(url),
                        pycompat.bytestr(self.request_version),
                    )
                )
                self.headers['Connection'] = 'close'
                del self.headers['Proxy-Connection']
                for key, val in self.headers.items():
                    soc.send(
                        b"%s: %s\r\n"
                        % (pycompat.bytestr(key), pycompat.bytestr(val))
                    )
                soc.send(b"\r\n")
                self._read_write(soc)
        finally:
            print("\t" "bye")
            soc.close()
            self.connection.close()

    def _read_write(self, soc, max_idling=20):
        iw = [self.connection, soc]
        ow = []
        count = 0
        while True:
            count += 1
            (ins, _, exs) = select.select(iw, ow, iw, 3)
            if exs:
                break
            if ins:
                for i in ins:
                    if i is soc:
                        out = self.connection
                    else:
                        out = soc
                    try:
                        data = i.recv(8192)
                    except OSError:
                        break
                    if data:
                        out.send(data)
                        count = 0
            else:
                print("\t" "idle", count)
            if count == max_idling:
                break

    do_HEAD = do_GET
    do_POST = do_GET
    do_PUT = do_GET
    do_DELETE = do_GET


class ThreadingHTTPServer(socketserver.ThreadingMixIn, httpserver.httpserver):
    def __init__(self, *args, **kwargs):
        httpserver.httpserver.__init__(self, *args, **kwargs)
        a = open("proxy.pid", "w")
        a.write(str(os.getpid()) + "\n")
        a.close()


def runserver(port=8000, bind=""):
    server_address = (bind, port)
    ProxyHandler.protocol_version = "HTTP/1.0"
    httpd = ThreadingHTTPServer(server_address, ProxyHandler)
    sa = httpd.socket.getsockname()
    print("Serving HTTP on", sa[0], "port", sa[1], "...")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nKeyboard interrupt received, exiting.")
        httpd.server_close()
        sys.exit(0)


if __name__ == '__main__':
    argv = sys.argv
    if argv[1:] and argv[1] in ('-h', '--help'):
        print(argv[0], "[port [allowed_client_name ...]]")
    else:
        if argv[2:]:
            allowed = []
            for name in argv[2:]:
                client = socket.gethostbyname(name)
                allowed.append(client)
                print("Accept: %s (%s)" % (client, name))
            ProxyHandler.allowed_clients = allowed
            del argv[2:]
        else:
            print("Any clients will be served...")

        parser = optparse.OptionParser()
        parser.add_option(
            '-b',
            '--bind',
            metavar='ADDRESS',
            help='Specify alternate bind address ' '[default: all interfaces]',
            default='',
        )
        (options, args) = parser.parse_args()
        port = 8000
        if len(args) == 1:
            port = int(args[0])
        runserver(port, options.bind)
