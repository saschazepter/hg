#!/usr/bin/env python3


"""
Small and dumb HTTP server for use in tests.
"""

import io
import optparse
import os
import signal
import socket
import sys

from mercurial import (
    encoding,
    pycompat,
    server,
    util,
)

httpserver = util.httpserver
OptionParser = optparse.OptionParser

if pycompat.iswindows:
    sys.stdout = io.TextIOWrapper(
        sys.stdout.buffer,
        sys.stdout.encoding,
        sys.stdout.errors,
        newline="\n",
    )
    sys.stderr = io.TextIOWrapper(
        sys.stderr.buffer,
        sys.stderr.encoding,
        sys.stderr.errors,
        newline="\n",
    )

if os.environ.get('HGIPV6', '0') == '1':

    class simplehttpserver(httpserver.httpserver):
        address_family = socket.AF_INET6

else:
    simplehttpserver = httpserver.httpserver


class _httprequesthandler(httpserver.simplehttprequesthandler):
    def log_message(self, format, *args):
        httpserver.simplehttprequesthandler.log_message(self, format, *args)
        sys.stderr.flush()


class simplehttpservice:
    def __init__(self, host, port):
        self.address = (host, port)

    def init(self):
        self.httpd = simplehttpserver(self.address, _httprequesthandler)

    def run(self):
        self.httpd.serve_forever()


if __name__ == '__main__':
    parser = OptionParser()
    parser.add_option(
        '-p',
        '--port',
        dest='port',
        type='int',
        default=8000,
        help='TCP port to listen on',
        metavar='PORT',
    )
    parser.add_option(
        '-H',
        '--host',
        dest='host',
        default='localhost',
        help='hostname or IP to listen on',
        metavar='HOST',
    )
    parser.add_option('--logfile', help='file name of access/error log')
    parser.add_option(
        '--pid',
        dest='pid',
        help='file name where the PID of the server is stored',
    )
    parser.add_option(
        '-f',
        '--foreground',
        dest='foreground',
        action='store_true',
        help='do not start the HTTP server in the background',
    )
    parser.add_option('--daemon-postexec', action='append')

    (options, args) = parser.parse_args()

    signal.signal(signal.SIGTERM, lambda x, y: sys.exit(0))

    if options.foreground and options.logfile:
        parser.error(
            "options --logfile and --foreground are mutually " "exclusive"
        )
    if options.foreground and options.pid:
        parser.error("options --pid and --foreground are mutually exclusive")

    opts = {
        b'pid_file': options.pid,
        b'daemon': not options.foreground,
        b'daemon_postexec': pycompat.rapply(
            encoding.strtolocal, options.daemon_postexec
        ),
    }
    service = simplehttpservice(options.host, options.port)
    runargs = [sys.executable, __file__] + sys.argv[1:]
    runargs = [pycompat.fsencode(a) for a in runargs]
    server.runservice(
        opts,
        initfn=service.init,
        runfn=service.run,
        logfile=options.logfile,
        runargs=runargs,
    )
