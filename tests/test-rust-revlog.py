import struct
import unittest

try:
    from mercurial import rustext

    rustext.__name__  # trigger immediate actual import
except ImportError:
    rustext = None
else:
    from mercurial.rustext import revlog

    # this would fail already without appropriate ancestor.__package__
    from mercurial.rustext.ancestor import LazyAncestors

from mercurial.testing import revlog as revlogtesting

header = struct.unpack(">I", revlogtesting.data_non_inlined[:4])[0]


@unittest.skipIf(
    rustext is None,
    "rustext module revlog relies on is not available",
)
class RustRevlogIndexTest(revlogtesting.RevlogBasedTestBase):
    def test_heads(self):
        idx = self.parseindex()
        rustidx = revlog.MixedIndex(idx, revlogtesting.data_non_inlined, header)
        self.assertEqual(rustidx.headrevs(), idx.headrevs())

    def test_get_cindex(self):
        # drop me once we no longer need the method for shortest node
        idx = self.parseindex()
        rustidx = revlog.MixedIndex(idx, revlogtesting.data_non_inlined, header)
        cidx = rustidx.get_cindex()
        self.assertTrue(idx is cidx)

    def test_len(self):
        idx = self.parseindex()
        rustidx = revlog.MixedIndex(idx, revlogtesting.data_non_inlined, header)
        self.assertEqual(len(rustidx), len(idx))

    def test_ancestors(self):
        idx = self.parseindex()
        rustidx = revlog.MixedIndex(idx, revlogtesting.data_non_inlined, header)
        lazy = LazyAncestors(rustidx, [3], 0, True)
        # we have two more references to the index:
        # - in its inner iterator for __contains__ and __bool__
        # - in the LazyAncestors instance itself (to spawn new iterators)
        self.assertTrue(2 in lazy)
        self.assertTrue(bool(lazy))
        self.assertEqual(list(lazy), [3, 2, 1, 0])
        # a second time to validate that we spawn new iterators
        self.assertEqual(list(lazy), [3, 2, 1, 0])

        # let's check bool for an empty one
        self.assertFalse(LazyAncestors(idx, [0], 0, False))


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
