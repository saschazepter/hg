#!/usr/bin/env python

"""dummy SMTP server for use in tests"""


import asyncore
import optparse
import smtpd
import ssl
import sys
import traceback

from mercurial import (
    pycompat,
    server,
    sslutil,
    ui as uimod,
)


def log(msg):
    sys.stdout.write(msg)
    sys.stdout.flush()


class dummysmtpserver(smtpd.SMTPServer):
    def __init__(self, localaddr):
        smtpd.SMTPServer.__init__(self, localaddr, remoteaddr=None)

    def process_message(self, peer, mailfrom, rcpttos, data, **kwargs):
        log('%s from=%s to=%s\n' % (peer[0], mailfrom, ', '.join(rcpttos)))

    def handle_error(self):
        # On Windows, a bad SSL connection sometimes generates a WSAECONNRESET.
        # The default handler will shutdown this server, and then both the
        # current connection and subsequent ones fail on the client side with
        # "No connection could be made because the target machine actively
        # refused it".  If we eat the error, then the client properly aborts in
        # the expected way, and the server is available for subsequent requests.
        traceback.print_exc()


class dummysmtpsecureserver(dummysmtpserver):
    def __init__(self, localaddr, certfile):
        dummysmtpserver.__init__(self, localaddr)
        self._certfile = certfile

    def handle_accept(self):
        pair = self.accept()
        if not pair:
            return
        conn, addr = pair
        ui = uimod.ui.load()
        try:
            # wrap_socket() would block, but we don't care
            conn = sslutil.wrapserversocket(conn, ui, certfile=self._certfile)
        except ssl.SSLError:
            log('%s ssl error\n' % addr[0])
            conn.close()
            return
        smtpd.SMTPChannel(self, conn, addr)


def run():
    try:
        asyncore.loop()
    except KeyboardInterrupt:
        pass


def _encodestrsonly(v):
    if isinstance(v, type(u'')):
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

    opts, args = op.parse_args()
    if opts.tls == 'smtps' and not opts.certificate:
        op.error('--certificate must be specified')

    addr = (opts.address, opts.port)

    def init():
        if opts.tls == 'none':
            dummysmtpserver(addr)
        else:
            dummysmtpsecureserver(addr, opts.certificate)
        log('listening at %s:%d\n' % addr)

    server.runservice(
        bytesvars(opts),
        initfn=init,
        runfn=run,
        runargs=[pycompat.sysexecutable, pycompat.fsencode(__file__)]
        + pycompat.sysargv[1:],
    )


if __name__ == '__main__':
    main()
