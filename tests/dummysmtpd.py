#!/usr/bin/env python3

"""dummy SMTP server for use in tests"""


import io
import optparse
import os
import socket
import ssl
import sys

from mercurial import (
    pycompat,
    server,
    sslutil,
    ui as uimod,
)

if pycompat.iswindows:
    sys.stdout = io.TextIOWrapper(
        sys.stdout.buffer,
        sys.stdout.encoding,
        sys.stdout.errors,
        newline="\n",
    )

if os.environ.get('HGIPV6', '0') == '1':
    family = socket.AF_INET6
else:
    family = socket.AF_INET


def log(msg):
    sys.stdout.write(msg)
    sys.stdout.flush()


def mocksmtpserversession(conn, addr):
    conn.send(b'220 smtp.example.com ESMTP\r\n')

    try:
        # Newer versions of OpenSSL raise on EOF
        line = conn.recv(1024)
    except ssl.SSLError:
        log('no hello: EOF\n')
        return

    if not line.lower().startswith(b'ehlo '):
        # Older versions of OpenSSl don't raise
        log('no hello: %s\n' % line)
        return

    conn.send(b'250 Hello\r\n')

    line = conn.recv(1024)
    if not line.lower().startswith(b'mail from:'):
        log('no mail from: %s\n' % line)
        return
    mailfrom = line[10:].decode().rstrip()
    if mailfrom.startswith('<') and mailfrom.endswith('>'):
        mailfrom = mailfrom[1:-1]

    conn.send(b'250 Ok\r\n')

    rcpttos = []
    while True:
        line = conn.recv(1024)
        if not line.lower().startswith(b'rcpt to:'):
            break
        rcptto = line[8:].decode().rstrip()
        if rcptto.startswith('<') and rcptto.endswith('>'):
            rcptto = rcptto[1:-1]
        rcpttos.append(rcptto)

        conn.send(b'250 Ok\r\n')

    if not line.lower().strip() == b'data':
        log('no rcpt to or data: %s' % line)

    conn.send(b'354 Go ahead\r\n')

    data = b''
    while True:
        line = conn.recv(1024)
        if not line:
            log('connection closed before end of data')
            break
        data += line
        if data.endswith(b'\r\n.\r\n'):
            data = data[:-5]
            break

    conn.send(b'250 Ok\r\n')

    log(
        '%s from=%s to=%s\n%s\n'
        % (addr[0], mailfrom, ', '.join(rcpttos), data.decode())
    )


def run(host, port, certificate):
    ui = uimod.ui.load()
    with socket.socket(family, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((host, port))
        # log('listening at %s:%d\n' % (host, port))
        s.listen(1)
        try:
            while True:
                conn, addr = s.accept()
                if certificate:
                    try:
                        conn = sslutil.wrapserversocket(
                            conn, ui, certfile=certificate
                        )
                    except ssl.SSLError as e:
                        log('%s ssl error: %s\n' % (addr[0], e))
                        conn.close()
                        continue
                log("connection from %s:%s\n" % addr)
                mocksmtpserversession(conn, addr)
                conn.close()
        except KeyboardInterrupt:
            pass


def _encodestrsonly(v):
    if isinstance(v, str):
        return v.encode('ascii')
    return v


def bytesvars(obj):
    unidict = vars(obj)
    bd = {k.encode('ascii'): _encodestrsonly(v) for k, v in unidict.items()}
    if bd[b'daemon_postexec'] is not None:
        bd[b'daemon_postexec'] = [
            _encodestrsonly(v) for v in bd[b'daemon_postexec']
        ]
    return bd


def main():
    op = optparse.OptionParser()
    op.add_option('-d', '--daemon', action='store_true')
    op.add_option('--daemon-postexec', action='append')
    op.add_option('-p', '--port', type=int, default=8025)
    op.add_option('-a', '--address', default='localhost')
    op.add_option('--pid-file', metavar='FILE')
    op.add_option('--tls', choices=['none', 'smtps'], default='none')
    op.add_option('--certificate', metavar='FILE')
    op.add_option('--logfile', metavar='FILE')

    opts, args = op.parse_args()
    if (opts.tls == 'smtps') != bool(opts.certificate):
        op.error('--certificate must be specified with --tls=smtps')

    server.runservice(
        bytesvars(opts),
        runfn=lambda: run(opts.address, opts.port, opts.certificate),
        runargs=[pycompat.sysexecutable, pycompat.fsencode(__file__)]
        + pycompat.sysargv[1:],
        logfile=opts.logfile,
    )


if __name__ == '__main__':
    main()
