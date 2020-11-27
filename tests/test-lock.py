from __future__ import absolute_import

import copy
import errno
import tempfile
import types
import unittest

import silenttestrunner

from mercurial import (
    encoding,
    error,
    lock,
    vfs as vfsmod,
)

testlockname = b'testlock'

# work around http://bugs.python.org/issue1515
if types.MethodType not in copy._deepcopy_dispatch:

    def _deepcopy_method(x, memo):
        return type(x)(x.__func__, copy.deepcopy(x.__self__, memo), x.im_class)

    copy._deepcopy_dispatch[types.MethodType] = _deepcopy_method


class lockwrapper(lock.lock):
    def __init__(self, pidoffset, *args, **kwargs):
        # lock.lock.__init__() calls lock(), so the pidoffset assignment needs
        # to be earlier
        self._pidoffset = pidoffset
        super(lockwrapper, self).__init__(*args, **kwargs)

    def _getpid(self):
        return super(lockwrapper, self)._getpid() + self._pidoffset


class teststate(object):
    def __init__(self, testcase, dir, pidoffset=0):
        self._testcase = testcase
        self._acquirecalled = False
        self._releasecalled = False
        self._postreleasecalled = False
        self.vfs = vfsmod.vfs(dir, audit=False)
        self._pidoffset = pidoffset

    def makelock(self, *args, **kwargs):
        l = lockwrapper(
            self._pidoffset,
            self.vfs,
            testlockname,
            releasefn=self.releasefn,
            acquirefn=self.acquirefn,
            *args,
            **kwargs
        )
        l.postrelease.append(self.postreleasefn)
        return l

    def acquirefn(self):
        self._acquirecalled = True

    def releasefn(self):
        self._releasecalled = True

    def postreleasefn(self, success):
        self._postreleasecalled = True

    def assertacquirecalled(self, called):
        self._testcase.assertEqual(
            self._acquirecalled,
            called,
            'expected acquire to be %s but was actually %s'
            % (
                self._tocalled(called),
                self._tocalled(self._acquirecalled),
            ),
        )

    def resetacquirefn(self):
        self._acquirecalled = False

    def assertreleasecalled(self, called):
        self._testcase.assertEqual(
            self._releasecalled,
            called,
            'expected release to be %s but was actually %s'
            % (
                self._tocalled(called),
                self._tocalled(self._releasecalled),
            ),
        )

    def assertpostreleasecalled(self, called):
        self._testcase.assertEqual(
            self._postreleasecalled,
            called,
            'expected postrelease to be %s but was actually %s'
            % (
                self._tocalled(called),
                self._tocalled(self._postreleasecalled),
            ),
        )

    def assertlockexists(self, exists):
        actual = self.vfs.lexists(testlockname)
        self._testcase.assertEqual(
            actual,
            exists,
            'expected lock to %s but actually did %s'
            % (
                self._toexists(exists),
                self._toexists(actual),
            ),
        )

    def _tocalled(self, called):
        if called:
            return 'called'
        else:
            return 'not called'

    def _toexists(self, exists):
        if exists:
            return 'exist'
        else:
            return 'not exist'


class testlock(unittest.TestCase):
    def testlock(self):
        state = teststate(self, tempfile.mkdtemp(dir=encoding.getcwd()))
        lock = state.makelock()
        state.assertacquirecalled(True)
        lock.release()
        state.assertreleasecalled(True)
        state.assertpostreleasecalled(True)
        state.assertlockexists(False)

    def testrecursivelock(self):
        state = teststate(self, tempfile.mkdtemp(dir=encoding.getcwd()))
        lock = state.makelock()
        state.assertacquirecalled(True)

        state.resetacquirefn()
        lock.lock()
        # recursive lock should not call acquirefn again
        state.assertacquirecalled(False)

        lock.release()  # brings lock refcount down from 2 to 1
        state.assertreleasecalled(False)
        state.assertpostreleasecalled(False)
        state.assertlockexists(True)

        lock.release()  # releases the lock
        state.assertreleasecalled(True)
        state.assertpostreleasecalled(True)
        state.assertlockexists(False)

    def testlockfork(self):
        state = teststate(self, tempfile.mkdtemp(dir=encoding.getcwd()))
        lock = state.makelock()
        state.assertacquirecalled(True)

        # fake a fork
        forklock = copy.copy(lock)
        forklock._pidoffset = 1
        forklock.release()
        state.assertreleasecalled(False)
        state.assertpostreleasecalled(False)
        state.assertlockexists(True)

        # release the actual lock
        lock.release()
        state.assertreleasecalled(True)
        state.assertpostreleasecalled(True)
        state.assertlockexists(False)

    def testfrequentlockunlock(self):
        """This tests whether lock acquisition fails as expected, even if
        (1) lock can't be acquired (makelock fails by EEXIST), and
        (2) locker info can't be read in (readlock fails by ENOENT) while
        retrying 5 times.
        """

        d = tempfile.mkdtemp(dir=encoding.getcwd())
        state = teststate(self, d)

        def emulatefrequentlock(*args):
            raise OSError(errno.EEXIST, "File exists")

        def emulatefrequentunlock(*args):
            raise OSError(errno.ENOENT, "No such file or directory")

        state.vfs.makelock = emulatefrequentlock
        state.vfs.readlock = emulatefrequentunlock

        try:
            state.makelock(timeout=0)
            self.fail("unexpected lock acquisition")
        except error.LockHeld as why:
            self.assertTrue(why.errno == errno.ETIMEDOUT)
            self.assertTrue(why.locker == b"")
            state.assertlockexists(False)


if __name__ == '__main__':
    silenttestrunner.main(__name__)
