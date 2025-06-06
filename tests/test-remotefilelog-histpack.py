#!/usr/bin/env python3

import hashlib
import os
import random
import shutil
import stat
import struct
import sys
import tempfile
import unittest

import silenttestrunner

from mercurial.node import sha1nodeconstants
from mercurial import (
    pycompat,
    ui as uimod,
)

# Load the local remotefilelog, not the system one
sys.path[0:0] = [os.path.join(os.path.dirname(__file__), '..')]
from hgext.remotefilelog import (
    basepack,
    historypack,
)


class histpacktests(unittest.TestCase):
    def setUp(self):
        self.tempdirs = []

    def tearDown(self):
        for d in self.tempdirs:
            shutil.rmtree(d)

    def makeTempDir(self):
        tempdir = tempfile.mkdtemp()
        self.tempdirs.append(tempdir)
        return pycompat.fsencode(tempdir)

    def getHash(self, content):
        return hashlib.sha1(content).digest()

    def getFakeHash(self):
        return b''.join(
            pycompat.bytechr(random.randint(0, 255)) for _ in range(20)
        )

    def createPack(self, revisions=None):
        """Creates and returns a historypack containing the specified revisions.

        `revisions` is a list of tuples, where each tuple contains a filanem,
        node, p1node, p2node, and linknode.
        """
        if revisions is None:
            revisions = [
                (
                    b"filename",
                    self.getFakeHash(),
                    sha1nodeconstants.nullid,
                    sha1nodeconstants.nullid,
                    self.getFakeHash(),
                    None,
                )
            ]

        packdir = pycompat.fsencode(self.makeTempDir())
        packer = historypack.mutablehistorypack(uimod.ui(), packdir, version=2)

        for filename, node, p1, p2, linknode, copyfrom in revisions:
            packer.add(filename, node, p1, p2, linknode, copyfrom)

        path = packer.close()
        return historypack.historypack(path)

    def testAddSingle(self):
        """Test putting a single entry into a pack and reading it out."""
        filename = b"foo"
        node = self.getFakeHash()
        p1 = self.getFakeHash()
        p2 = self.getFakeHash()
        linknode = self.getFakeHash()

        revisions = [(filename, node, p1, p2, linknode, None)]
        pack = self.createPack(revisions)

        actual = pack.getancestors(filename, node)[node]
        self.assertEqual(p1, actual[0])
        self.assertEqual(p2, actual[1])
        self.assertEqual(linknode, actual[2])

    def testAddMultiple(self):
        """Test putting multiple unrelated revisions into a pack and reading
        them out.
        """
        revisions = []
        for i in range(10):
            filename = b"foo-%d" % i
            node = self.getFakeHash()
            p1 = self.getFakeHash()
            p2 = self.getFakeHash()
            linknode = self.getFakeHash()
            revisions.append((filename, node, p1, p2, linknode, None))

        pack = self.createPack(revisions)

        for filename, node, p1, p2, linknode, copyfrom in revisions:
            actual = pack.getancestors(filename, node)[node]
            self.assertEqual(p1, actual[0])
            self.assertEqual(p2, actual[1])
            self.assertEqual(linknode, actual[2])
            self.assertEqual(copyfrom, actual[3])

    def testAddAncestorChain(self):
        """Test putting multiple revisions in into a pack and read the ancestor
        chain.
        """
        revisions = []
        filename = b"foo"
        lastnode = sha1nodeconstants.nullid
        for i in range(10):
            node = self.getFakeHash()
            revisions.append(
                (
                    filename,
                    node,
                    lastnode,
                    sha1nodeconstants.nullid,
                    sha1nodeconstants.nullid,
                    None,
                )
            )
            lastnode = node

        # revisions must be added in topological order, newest first
        revisions = list(reversed(revisions))
        pack = self.createPack(revisions)

        # Test that the chain has all the entries
        ancestors = pack.getancestors(revisions[0][0], revisions[0][1])
        for filename, node, p1, p2, linknode, copyfrom in revisions:
            ap1, ap2, alinknode, acopyfrom = ancestors[node]
            self.assertEqual(ap1, p1)
            self.assertEqual(ap2, p2)
            self.assertEqual(alinknode, linknode)
            self.assertEqual(acopyfrom, copyfrom)

    def testPackMany(self):
        """Pack many related and unrelated ancestors."""
        # Build a random pack file
        allentries = {}
        ancestorcounts = {}
        revisions = []
        random.seed(0)
        for i in range(100):
            filename = b"filename-%d" % i
            entries = []
            p2 = sha1nodeconstants.nullid
            linknode = sha1nodeconstants.nullid
            for j in range(random.randint(1, 100)):
                node = self.getFakeHash()
                p1 = sha1nodeconstants.nullid
                if len(entries) > 0:
                    p1 = entries[random.randint(0, len(entries) - 1)]
                entries.append(node)
                revisions.append((filename, node, p1, p2, linknode, None))
                allentries[(filename, node)] = (p1, p2, linknode)
                if p1 == sha1nodeconstants.nullid:
                    ancestorcounts[(filename, node)] = 1
                else:
                    newcount = ancestorcounts[(filename, p1)] + 1
                    ancestorcounts[(filename, node)] = newcount

        # Must add file entries in reverse topological order
        revisions = list(reversed(revisions))
        pack = self.createPack(revisions)

        # Verify the pack contents
        for filename, node in allentries:
            ancestors = pack.getancestors(filename, node)
            self.assertEqual(ancestorcounts[(filename, node)], len(ancestors))
            for anode, (ap1, ap2, alinknode, copyfrom) in ancestors.items():
                ep1, ep2, elinknode = allentries[(filename, anode)]
                self.assertEqual(ap1, ep1)
                self.assertEqual(ap2, ep2)
                self.assertEqual(alinknode, elinknode)
                self.assertEqual(copyfrom, None)

    def testGetNodeInfo(self):
        revisions = []
        filename = b"foo"
        lastnode = sha1nodeconstants.nullid
        for i in range(10):
            node = self.getFakeHash()
            revisions.append(
                (
                    filename,
                    node,
                    lastnode,
                    sha1nodeconstants.nullid,
                    sha1nodeconstants.nullid,
                    None,
                )
            )
            lastnode = node

        pack = self.createPack(revisions)

        # Test that getnodeinfo returns the expected results
        for filename, node, p1, p2, linknode, copyfrom in revisions:
            ap1, ap2, alinknode, acopyfrom = pack.getnodeinfo(filename, node)
            self.assertEqual(ap1, p1)
            self.assertEqual(ap2, p2)
            self.assertEqual(alinknode, linknode)
            self.assertEqual(acopyfrom, copyfrom)

    def testGetMissing(self):
        """Test the getmissing() api."""
        revisions = []
        filename = b"foo"
        for i in range(10):
            node = self.getFakeHash()
            p1 = self.getFakeHash()
            p2 = self.getFakeHash()
            linknode = self.getFakeHash()
            revisions.append((filename, node, p1, p2, linknode, None))

        pack = self.createPack(revisions)

        missing = pack.getmissing([(filename, revisions[0][1])])
        self.assertFalse(missing)

        missing = pack.getmissing(
            [(filename, revisions[0][1]), (filename, revisions[1][1])]
        )
        self.assertFalse(missing)

        fakenode = self.getFakeHash()
        missing = pack.getmissing(
            [(filename, revisions[0][1]), (filename, fakenode)]
        )
        self.assertEqual(missing, [(filename, fakenode)])

        # Test getmissing on a non-existant filename
        missing = pack.getmissing([(b"bar", fakenode)])
        self.assertEqual(missing, [(b"bar", fakenode)])

    def testAddThrows(self):
        pack = self.createPack()

        try:
            pack.add(
                b'filename',
                sha1nodeconstants.nullid,
                sha1nodeconstants.nullid,
                sha1nodeconstants.nullid,
                sha1nodeconstants.nullid,
                None,
            )
            self.assertTrue(False, "historypack.add should throw")
        except RuntimeError:
            pass

    def testBadVersionThrows(self):
        pack = self.createPack()
        path = pack.path + b'.histpack'
        with open(path, 'rb') as f:
            raw = f.read()
        raw = struct.pack('!B', 255) + raw[1:]
        os.chmod(path, os.stat(path).st_mode | stat.S_IWRITE)
        with open(path, 'wb+') as f:
            f.write(raw)

        try:
            historypack.historypack(pack.path)
            self.assertTrue(False, "bad version number should have thrown")
        except RuntimeError:
            pass

    def testLargePack(self):
        """Test creating and reading from a large pack with over X entries.
        This causes it to use a 2^16 fanout table instead."""
        total = basepack.SMALLFANOUTCUTOFF + 1
        revisions = []
        for i in range(total):
            filename = b"foo-%d" % i
            node = self.getFakeHash()
            p1 = self.getFakeHash()
            p2 = self.getFakeHash()
            linknode = self.getFakeHash()
            revisions.append((filename, node, p1, p2, linknode, None))

        pack = self.createPack(revisions)
        self.assertEqual(pack.params.fanoutprefix, basepack.LARGEFANOUTPREFIX)

        for filename, node, p1, p2, linknode, copyfrom in revisions:
            actual = pack.getancestors(filename, node)[node]
            self.assertEqual(p1, actual[0])
            self.assertEqual(p2, actual[1])
            self.assertEqual(linknode, actual[2])
            self.assertEqual(copyfrom, actual[3])


# TODO:
# histpack store:
# - repack two packs into one

if __name__ == '__main__':
    if pycompat.iswindows:
        sys.exit(80)  # Skip on Windows
    silenttestrunner.main(__name__)
