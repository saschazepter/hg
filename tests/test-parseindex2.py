"""This unit test primarily tests parsers.parse_index2().

It also checks certain aspects of the parsers module as a whole.
"""

from __future__ import absolute_import, print_function

import os
import struct
import subprocess
import sys
import unittest

from mercurial.node import (
    bin,
    hex,
    nullid,
    nullrev,
)
from mercurial import (
    policy,
    pycompat,
)

parsers = policy.importmod('parsers')

# original python implementation
def gettype(q):
    return int(q & 0xFFFF)


def offset_type(offset, type):
    return int(int(offset) << 16 | type)


indexformatng = ">Qiiiiii20s12x"


def py_parseindex(data, inline):
    s = 64
    cache = None
    index = []
    nodemap = {nullid: nullrev}
    n = off = 0

    l = len(data) - s
    append = index.append
    if inline:
        cache = (0, data)
        while off <= l:
            e = struct.unpack(indexformatng, data[off : off + s])
            nodemap[e[7]] = n
            append(e)
            n += 1
            if e[1] < 0:
                break
            off += e[1] + s
    else:
        while off <= l:
            e = struct.unpack(indexformatng, data[off : off + s])
            nodemap[e[7]] = n
            append(e)
            n += 1
            off += s

    e = list(index[0])
    type = gettype(e[0])
    e[0] = offset_type(0, type)
    index[0] = tuple(e)

    return index, cache


data_inlined = (
    b'\x00\x01\x00\x01\x00\x00\x00\x00\x00\x00\x01\x8c'
    b'\x00\x00\x04\x07\x00\x00\x00\x00\x00\x00\x15\x15\xff\xff\xff'
    b'\xff\xff\xff\xff\xff\xebG\x97\xb7\x1fB\x04\xcf\x13V\x81\tw\x1b'
    b'w\xdduR\xda\xc6\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
    b'x\x9c\x9d\x93?O\xc30\x10\xc5\xf7|\x8a\xdb\x9a\xa8m\x06\xd8*\x95'
    b'\x81B\xa1\xa2\xa2R\xcb\x86Pd\x9a\x0b5$vd_\x04\xfd\xf6\x9c\xff@'
    b'\x11!\x0b\xd9\xec\xf7\xbbw\xe7gG6\xad6\x04\xdaN\xc0\x92\xa0$)'
    b'\xb1\x82\xa2\xd1%\x16\xa4\x8b7\xa9\xca\xd4-\xb2Y\x02\xfc\xc9'
    b'\xcaS\xf9\xaeX\xed\xb6\xd77Q\x02\x83\xd4\x19\xf5--Y\xea\xe1W'
    b'\xab\xed\x10\xceR\x0f_\xdf\xdf\r\xe1,\xf5\xf0\xcb\xf5 \xceR\x0f'
    b'_\xdc\x0e\x0e\xc3R\x0f_\xae\x96\x9b!\x9e\xa5\x1e\xbf\xdb,\x06'
    b'\xc7q\x9a/\x88\x82\xc3B\xea\xb5\xb4TJ\x93\xb6\x82\x0e\xe16\xe6'
    b'KQ\xdb\xaf\xecG\xa3\xd1 \x01\xd3\x0b_^\xe8\xaa\xa0\xae\xad\xd1'
    b'&\xbef\x1bz\x08\xb0|\xc9Xz\x06\xf6Z\x91\x90J\xaa\x17\x90\xaa'
    b'\xd2\xa6\x11$5C\xcf\xba#\xa0\x03\x02*2\x92-\xfc\xb1\x94\xdf\xe2'
    b'\xae\xb8\'m\x8ey0^\x85\xd3\x82\xb4\xf0`:\x9c\x00\x8a\xfd\x01'
    b'\xb0\xc6\x86\x8b\xdd\xae\x80\xf3\xa9\x9fd\x16\n\x00R%\x1a\x06'
    b'\xe9\xd8b\x98\x1d\xf4\xf3+\x9bf\x01\xd8p\x1b\xf3.\xed\x9f^g\xc3'
    b'^\xd9W81T\xdb\xd5\x04sx|\xf2\xeb\xd6`%?x\xed"\x831\xbf\xf3\xdc'
    b'b\xeb%gaY\xe1\xad\x9f\xb9f\'1w\xa9\xa5a\x83s\x82J\xb98\xbc4\x8b'
    b'\x83\x00\x9f$z\xb8#\xa5\xb1\xdf\x98\xd9\xec\x1b\x89O\xe3Ts\x9a4'
    b'\x17m\x8b\xfc\x8f\xa5\x95\x9a\xfc\xfa\xed,\xe5|\xa1\xfe\x15\xb9'
    b'\xbc\xb2\x93\x1f\xf2\x95\xff\xdf,\x1a\xc5\xe7\x17*\x93Oz:>\x0e'
)

data_non_inlined = (
    b'\x00\x00\x00\x01\x00\x00\x00\x00\x00\x01D\x19'
    b'\x00\x07e\x12\x00\x00\x00\x00\x00\x00\x00\x00\xff\xff\xff\xff'
    b'\xff\xff\xff\xff\xd1\xf4\xbb\xb0\xbe\xfc\x13\xbd\x8c\xd3\x9d'
    b'\x0f\xcd\xd9;\x8c\x07\x8cJ/\x00\x00\x00\x00\x00\x00\x00\x00\x00'
    b'\x00\x00\x00\x00\x00\x00\x01D\x19\x00\x00\x00\x00\x00\xdf\x00'
    b'\x00\x01q\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\xff'
    b'\xff\xff\xff\xc1\x12\xb9\x04\x96\xa4Z1t\x91\xdfsJ\x90\xf0\x9bh'
    b'\x07l&\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
    b'\x00\x01D\xf8\x00\x00\x00\x00\x01\x1b\x00\x00\x01\xb8\x00\x00'
    b'\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\xff\xff\xff\xff\x02\n'
    b'\x0e\xc6&\xa1\x92\xae6\x0b\x02i\xfe-\xe5\xbao\x05\xd1\xe7\x00'
    b'\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01F'
    b'\x13\x00\x00\x00\x00\x01\xec\x00\x00\x03\x06\x00\x00\x00\x01'
    b'\x00\x00\x00\x03\x00\x00\x00\x02\xff\xff\xff\xff\x12\xcb\xeby1'
    b'\xb6\r\x98B\xcb\x07\xbd`\x8f\x92\xd9\xc4\x84\xbdK\x00\x00\x00'
    b'\x00\x00\x00\x00\x00\x00\x00\x00\x00'
)


def parse_index2(data, inline):
    index, chunkcache = parsers.parse_index2(data, inline)
    return list(index), chunkcache


def importparsers(hexversion):
    """Import mercurial.parsers with the given sys.hexversion."""
    # The file parsers.c inspects sys.hexversion to determine the version
    # of the currently-running Python interpreter, so we monkey-patch
    # sys.hexversion to simulate using different versions.
    code = (
        "import sys; sys.hexversion=%s; "
        "import mercurial.cext.parsers" % hexversion
    )
    cmd = "\"%s\" -c \"%s\"" % (os.environ['PYTHON'], code)
    # We need to do these tests inside a subprocess because parser.c's
    # version-checking code happens inside the module init function, and
    # when using reload() to reimport an extension module, "The init function
    # of extension modules is not called a second time"
    # (from http://docs.python.org/2/library/functions.html?#reload).
    p = subprocess.Popen(
        cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    return p.communicate()  # returns stdout, stderr


def hexfailmsg(testnumber, hexversion, stdout, expected):
    try:
        hexstring = hex(hexversion)
    except TypeError:
        hexstring = None
    return (
        "FAILED: version test #%s with Python %s and patched "
        "sys.hexversion %r (%r):\n Expected %s but got:\n-->'%s'\n"
        % (
            testnumber,
            sys.version_info,
            hexversion,
            hexstring,
            expected,
            stdout,
        )
    )


def makehex(major, minor, micro):
    return int("%x%02x%02x00" % (major, minor, micro), 16)


class parseindex2tests(unittest.TestCase):
    def assertversionokay(self, testnumber, hexversion):
        stdout, stderr = importparsers(hexversion)
        self.assertFalse(
            stdout, hexfailmsg(testnumber, hexversion, stdout, 'no stdout')
        )

    def assertversionfail(self, testnumber, hexversion):
        stdout, stderr = importparsers(hexversion)
        # We include versionerrortext to distinguish from other ImportErrors.
        errtext = b"ImportError: %s" % pycompat.sysbytes(
            parsers.versionerrortext
        )
        self.assertIn(
            errtext,
            stdout,
            hexfailmsg(
                testnumber,
                hexversion,
                stdout,
                expected="stdout to contain %r" % errtext,
            ),
        )

    def testversiondetection(self):
        """Check the version-detection logic when importing parsers."""
        # Only test the version-detection logic if it is present.
        try:
            parsers.versionerrortext
        except AttributeError:
            return
        info = sys.version_info
        major, minor, micro = info[0], info[1], info[2]
        # Test same major-minor versions.
        self.assertversionokay(1, makehex(major, minor, micro))
        self.assertversionokay(2, makehex(major, minor, micro + 1))
        # Test different major-minor versions.
        self.assertversionfail(3, makehex(major + 1, minor, micro))
        self.assertversionfail(4, makehex(major, minor + 1, micro))
        self.assertversionfail(5, "'foo'")

    def testbadargs(self):
        # Check that parse_index2() raises TypeError on bad arguments.
        with self.assertRaises(TypeError):
            parse_index2(0, True)

    def testparseindexfile(self):
        # Check parsers.parse_index2() on an index file against the
        # original Python implementation of parseindex, both with and
        # without inlined data.

        want = py_parseindex(data_inlined, True)
        got = parse_index2(data_inlined, True)
        self.assertEqual(want, got)  # inline data

        want = py_parseindex(data_non_inlined, False)
        got = parse_index2(data_non_inlined, False)
        self.assertEqual(want, got)  # no inline data

        ix = parsers.parse_index2(data_inlined, True)[0]
        for i, r in enumerate(ix):
            if r[7] == nullid:
                i = -1
            try:
                self.assertEqual(
                    ix[r[7]],
                    i,
                    'Reverse lookup inconsistent for %r' % hex(r[7]),
                )
            except TypeError:
                # pure version doesn't support this
                break

    def testminusone(self):
        want = (0, 0, 0, -1, -1, -1, -1, nullid)
        index, junk = parsers.parse_index2(data_inlined, True)
        got = index[-1]
        self.assertEqual(want, got)  # inline data

        index, junk = parsers.parse_index2(data_non_inlined, False)
        got = index[-1]
        self.assertEqual(want, got)  # no inline data

    def testdelitemwithoutnodetree(self):
        index, _junk = parsers.parse_index2(data_non_inlined, False)

        def hexrev(rev):
            if rev == nullrev:
                return b'\xff\xff\xff\xff'
            else:
                return bin('%08x' % rev)

        def appendrev(p1, p2=nullrev):
            # node won't matter for this test, let's just make sure
            # they don't collide. Other data don't matter either.
            node = hexrev(p1) + hexrev(p2) + b'.' * 12
            index.append((0, 0, 12, 1, 34, p1, p2, node))

        appendrev(4)
        appendrev(5)
        appendrev(6)
        self.assertEqual(len(index), 7)

        del index[1:-1]

        # assertions that failed before correction
        self.assertEqual(len(index), 1)  # was 4
        headrevs = getattr(index, 'headrevs', None)
        if headrevs is not None:  # not implemented in pure
            self.assertEqual(index.headrevs(), [0])  # gave ValueError


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
