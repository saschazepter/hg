import io
import unittest

import silenttestrunner

from mercurial import (
    wireprotoserver,
    wireprotov1server,
)

from mercurial.utils import procutil


class SSHServerGetArgsTests(unittest.TestCase):
    def testparseknown(self):
        tests = [
            (b'* 0\nnodes 0\n', [b'', {}]),
            (
                b'* 0\nnodes 40\n1111111111111111111111111111111111111111\n',
                [b'1111111111111111111111111111111111111111', {}],
            ),
        ]
        for input, expected in tests:
            self.assertparse(b'known', input, expected)

    def assertparse(self, cmd, input, expected):
        server = mockserver(input)
        ui = server._ui
        proto = wireprotoserver.sshv1protocolhandler(ui, ui.fin, ui.fout)
        _func, spec = wireprotov1server.commands[cmd]
        self.assertEqual(proto.getargs(spec), expected)


def mockserver(inbytes):
    ui = mockui(inbytes)
    repo = mockrepo(ui)
    # note: this test unfortunately doesn't really test anything about
    # `sshserver` class anymore: the entirety of logic of that class lives
    # in `serveuntil`, and that function is not even called by this test.
    return wireprotoserver.sshserver(ui, repo)


class mockrepo:
    def __init__(self, ui):
        self.ui = ui


class mockui:
    def __init__(self, inbytes):
        self.fin = io.BytesIO(inbytes)
        self.fout = io.BytesIO()
        self.ferr = io.BytesIO()

    def protectfinout(self):
        return self.fin, self.fout

    def restorefinout(self, fin, fout):
        pass


if __name__ == '__main__':
    # Don't call into msvcrt to set BytesIO to binary mode
    procutil.setbinary = lambda fp: True
    silenttestrunner.main(__name__)
