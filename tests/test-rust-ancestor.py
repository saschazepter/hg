import sys

from mercurial.node import wdirrev

from mercurial.testing import revlog as revlogtesting

try:
    from mercurial import pyo3_rustext

    pyo3_rustext.__name__
except ImportError:
    pyo3_rustext = None

try:
    from mercurial.cext import parsers as cparsers
except ImportError:
    cparsers = None


class RustAncestorsTestMixin:
    """Test the correctness of binding to Rust code.

    This test is merely for the binding to Rust itself: extraction of
    Python variable, giving back the results etc.

    It is not meant to test the algorithmic correctness of the operations
    on ancestors it provides. Hence the very simple embedded index data is
    good enough.

    Algorithmic correctness is asserted by the Rust unit tests.

    At this point, we have two sets of bindings, in `hg-cpython` and
    `hg-pyo3`. This class used to be for the first and now contains
    the tests that are identical in both bindings. As of this writing,
    there are more implementations in `hg-cpython` than `hg-pyo3`, hence
    some more tests in the subclass for `hg-cpython`. When the work on PyO3
    is complete, the subclasses for `hg-cpython` should have no specific
    test left. Later on, when we remove the dead code in `hg-cpython`, the tests
    should migrate from the mixin to the class for `hg-pyo3`, until we can
    simply remove the mixin.
    """

    @classmethod
    def ancestors_mod(cls):
        return pyo3_rustext.ancestor

    @classmethod
    def dagop_mod(cls):
        return pyo3_rustext.dagop

    @classmethod
    def graph_error(cls):
        return pyo3_rustext.GraphError

    def testiteratorrevlist(self):
        AncestorsIterator = self.ancestors_mod().AncestorsIterator

        idx = self.parserustindex()
        # checking test assumption about the index binary data:
        self.assertEqual(
            {i: (r[5], r[6]) for i, r in enumerate(idx)},
            {0: (-1, -1), 1: (0, -1), 2: (1, -1), 3: (2, -1)},
        )
        ait = AncestorsIterator(idx, [3], 0, True)
        self.assertEqual([r for r in ait], [3, 2, 1, 0])

        ait = AncestorsIterator(idx, [3], 0, False)
        self.assertEqual([r for r in ait], [2, 1, 0])

        ait = AncestorsIterator(idx, [3], 0, False)
        # tainting the index with a mutation, let's see what happens
        # (should be more critical with AncestorsIterator)
        del idx[0:2]
        try:
            next(ait)
        except RuntimeError as exc:
            assert "leaked reference after mutation" in exc.args[0]
        else:
            raise AssertionError("Expected an exception")

    def testlazyancestors(self):
        LazyAncestors = self.ancestors_mod().LazyAncestors

        idx = self.parserustindex()
        start_count = sys.getrefcount(idx.inner)  # should be 2 (see Python doc)
        self.assertEqual(
            {i: (r[5], r[6]) for i, r in enumerate(idx)},
            {0: (-1, -1), 1: (0, -1), 2: (1, -1), 3: (2, -1)},
        )
        lazy = LazyAncestors(idx, [3], 0, True)
        # the LazyAncestors instance holds just one reference to the
        # inner revlog. TODO check that this is normal
        self.assertEqual(sys.getrefcount(idx.inner), start_count + 1)

        self.assertTrue(2 in lazy)
        self.assertTrue(bool(lazy))
        self.assertFalse(None in lazy)
        self.assertEqual(list(lazy), [3, 2, 1, 0])
        # a second time to validate that we spawn new iterators
        self.assertEqual(list(lazy), [3, 2, 1, 0])

        # now let's watch the refcounts closer
        ait = iter(lazy)
        self.assertEqual(sys.getrefcount(idx.inner), start_count + 2)
        del ait
        self.assertEqual(sys.getrefcount(idx.inner), start_count + 1)
        del lazy
        self.assertEqual(sys.getrefcount(idx.inner), start_count)

        # let's check bool for an empty one
        self.assertFalse(LazyAncestors(idx, [0], 0, False))

    def testrefcount(self):
        AncestorsIterator = self.ancestors_mod().AncestorsIterator

        idx = self.parserustindex()
        start_count = sys.getrefcount(idx.inner)

        # refcount increases upon iterator init...
        ait = AncestorsIterator(idx, [3], 0, True)
        self.assertEqual(sys.getrefcount(idx.inner), start_count + 1)
        self.assertEqual(next(ait), 3)

        # and decreases once the iterator is removed
        del ait
        self.assertEqual(sys.getrefcount(idx.inner), start_count)

        # and removing ref to the index after iterator init is no issue
        ait = AncestorsIterator(idx, [3], 0, True)
        del idx
        self.assertEqual(list(ait), [3, 2, 1, 0])

        # the index is not tracked by the GC, hence there is nothing more
        # we can assert to check that it is properly deleted once its refcount
        # drops to 0

    def testgrapherror(self):
        AncestorsIterator = self.ancestors_mod().AncestorsIterator
        GraphError = self.graph_error()

        data = (
            revlogtesting.data_non_inlined[: 64 + 27]
            + b'\xf2'
            + revlogtesting.data_non_inlined[64 + 28 :]
        )
        idx = self.parserustindex(data=data)
        with self.assertRaises(GraphError) as arc:
            AncestorsIterator(idx, [1], -1, False)
        exc = arc.exception
        self.assertIsInstance(exc, ValueError)
        # rust-cpython issues appropriate str instances for Python 2 and 3
        self.assertEqual(exc.args, ('ParentOutOfRange', 1))

    def testwdirunsupported(self):
        AncestorsIterator = self.ancestors_mod().AncestorsIterator
        GraphError = self.graph_error()

        # trying to access ancestors of the working directory raises
        idx = self.parserustindex()
        with self.assertRaises(GraphError) as arc:
            list(AncestorsIterator(idx, [wdirrev], -1, False))

        exc = arc.exception
        self.assertIsInstance(exc, ValueError)
        # rust-cpython issues appropriate str instances for Python 2 and 3
        self.assertEqual(exc.args, ('InvalidRevision', wdirrev))

    def testheadrevs(self):
        dagop = self.dagop_mod()

        idx = self.parserustindex()
        self.assertEqual(dagop.headrevs(idx, [1, 2, 3]), {3})

    def testmissingancestors(self):
        MissingAncestors = self.ancestors_mod().MissingAncestors

        idx = self.parserustindex()
        missanc = MissingAncestors(idx, [1])
        self.assertTrue(missanc.hasbases())
        self.assertEqual(missanc.missingancestors([3]), [2, 3])
        missanc.addbases({2})
        self.assertEqual(missanc.bases(), {1, 2})
        self.assertEqual(missanc.missingancestors([3]), [3])
        self.assertEqual(missanc.basesheads(), {2})

    def testmissingancestorsremove(self):
        MissingAncestors = self.ancestors_mod().MissingAncestors

        idx = self.parserustindex()
        missanc = MissingAncestors(idx, [1])
        revs = {0, 1, 2, 3}
        missanc.removeancestorsfrom(revs)
        self.assertEqual(revs, {2, 3})

    def test_rank(self):
        dagop = self.dagop_mod()

        idx = self.parserustindex()
        try:
            dagop.rank(idx, 1, 2)
        except pyo3_rustext.GraphError as exc:
            self.assertEqual(exc.args, ("InconsistentGraphData",))


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
