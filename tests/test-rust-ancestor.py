from __future__ import absolute_import
import sys
import unittest

from mercurial.node import wdirrev
from mercurial import error

from mercurial.testing import revlog as revlogtesting

try:
    from mercurial import rustext

    rustext.__name__  # trigger immediate actual import
except ImportError:
    rustext = None
else:
    # this would fail already without appropriate ancestor.__package__
    from mercurial.rustext.ancestor import (
        AncestorsIterator,
        LazyAncestors,
        MissingAncestors,
    )
    from mercurial.rustext import dagop

try:
    from mercurial.cext import parsers as cparsers
except ImportError:
    cparsers = None


@unittest.skipIf(
    rustext is None,
    'The Rust version of the "ancestor" module is not available. It is needed'
    ' for this test.',
)
@unittest.skipIf(
    rustext is None,
    'The Rust or C version of the "parsers" module, which the "ancestor" module'
    ' relies on, is not available.',
)
class rustancestorstest(revlogtesting.RevlogBasedTestBase):
    """Test the correctness of binding to Rust code.

    This test is merely for the binding to Rust itself: extraction of
    Python variable, giving back the results etc.

    It is not meant to test the algorithmic correctness of the operations
    on ancestors it provides. Hence the very simple embedded index data is
    good enough.

    Algorithmic correctness is asserted by the Rust unit tests.
    """

    def testiteratorrevlist(self):
        idx = self.parseindex()
        # checking test assumption about the index binary data:
        self.assertEqual(
            {i: (r[5], r[6]) for i, r in enumerate(idx)},
            {0: (-1, -1), 1: (0, -1), 2: (1, -1), 3: (2, -1)},
        )
        ait = AncestorsIterator(idx, [3], 0, True)
        self.assertEqual([r for r in ait], [3, 2, 1, 0])

        ait = AncestorsIterator(idx, [3], 0, False)
        self.assertEqual([r for r in ait], [2, 1, 0])

    def testlazyancestors(self):
        idx = self.parseindex()
        start_count = sys.getrefcount(idx)  # should be 2 (see Python doc)
        self.assertEqual(
            {i: (r[5], r[6]) for i, r in enumerate(idx)},
            {0: (-1, -1), 1: (0, -1), 2: (1, -1), 3: (2, -1)},
        )
        lazy = LazyAncestors(idx, [3], 0, True)
        # we have two more references to the index:
        # - in its inner iterator for __contains__ and __bool__
        # - in the LazyAncestors instance itself (to spawn new iterators)
        self.assertEqual(sys.getrefcount(idx), start_count + 2)

        self.assertTrue(2 in lazy)
        self.assertTrue(bool(lazy))
        self.assertEqual(list(lazy), [3, 2, 1, 0])
        # a second time to validate that we spawn new iterators
        self.assertEqual(list(lazy), [3, 2, 1, 0])

        # now let's watch the refcounts closer
        ait = iter(lazy)
        self.assertEqual(sys.getrefcount(idx), start_count + 3)
        del ait
        self.assertEqual(sys.getrefcount(idx), start_count + 2)
        del lazy
        self.assertEqual(sys.getrefcount(idx), start_count)

        # let's check bool for an empty one
        self.assertFalse(LazyAncestors(idx, [0], 0, False))

    def testmissingancestors(self):
        idx = self.parseindex()
        missanc = MissingAncestors(idx, [1])
        self.assertTrue(missanc.hasbases())
        self.assertEqual(missanc.missingancestors([3]), [2, 3])
        missanc.addbases({2})
        self.assertEqual(missanc.bases(), {1, 2})
        self.assertEqual(missanc.missingancestors([3]), [3])
        self.assertEqual(missanc.basesheads(), {2})

    def testmissingancestorsremove(self):
        idx = self.parseindex()
        missanc = MissingAncestors(idx, [1])
        revs = {0, 1, 2, 3}
        missanc.removeancestorsfrom(revs)
        self.assertEqual(revs, {2, 3})

    def testrefcount(self):
        idx = self.parseindex()
        start_count = sys.getrefcount(idx)

        # refcount increases upon iterator init...
        ait = AncestorsIterator(idx, [3], 0, True)
        self.assertEqual(sys.getrefcount(idx), start_count + 1)
        self.assertEqual(next(ait), 3)

        # and decreases once the iterator is removed
        del ait
        self.assertEqual(sys.getrefcount(idx), start_count)

        # and removing ref to the index after iterator init is no issue
        ait = AncestorsIterator(idx, [3], 0, True)
        del idx
        self.assertEqual(list(ait), [3, 2, 1, 0])

    def testgrapherror(self):
        data = (
            revlogtesting.data_non_inlined[: 64 + 27]
            + b'\xf2'
            + revlogtesting.data_non_inlined[64 + 28 :]
        )
        idx = cparsers.parse_index2(data, False)[0]
        with self.assertRaises(rustext.GraphError) as arc:
            AncestorsIterator(idx, [1], -1, False)
        exc = arc.exception
        self.assertIsInstance(exc, ValueError)
        # rust-cpython issues appropriate str instances for Python 2 and 3
        self.assertEqual(exc.args, ('ParentOutOfRange', 1))

    def testwdirunsupported(self):
        # trying to access ancestors of the working directory raises
        # WdirUnsupported directly
        idx = self.parseindex()
        with self.assertRaises(error.WdirUnsupported):
            list(AncestorsIterator(idx, [wdirrev], -1, False))

    def testheadrevs(self):
        idx = self.parseindex()
        self.assertEqual(dagop.headrevs(idx, [1, 2, 3]), {3})


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
