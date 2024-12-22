import struct

from mercurial.node import (
    bin as node_bin,
    hex,
)

try:
    from mercurial import rustext

    rustext.__name__  # trigger immediate actual import
except ImportError:
    rustext = None
else:
    # this would fail already without appropriate ancestor.__package__
    from mercurial.rustext.ancestor import LazyAncestors

from mercurial.testing import revlog as revlogtesting

header = struct.unpack(">I", revlogtesting.data_non_inlined[:4])[0]


class RustInnerRevlogTestMixin:
    """Common tests for both Rust Python bindings."""

    node_hex0 = b'd1f4bbb0befc13bd8cd39d0fcdd93b8c078c4a2f'
    node0 = node_bin(node_hex0)


# Conditional skipping done by the base class
class RustInnerRevlogTest(
    revlogtesting.RustRevlogBasedTestBase, RustInnerRevlogTestMixin
):
    """For reference"""

    def test_heads(self):
        idx = self.parserustindex()
        self.assertEqual(idx.headrevs(), [3])

    def test_len(self):
        idx = self.parserustindex()
        self.assertEqual(len(idx), 4)

    def test_ancestors(self):
        rustidx = self.parserustindex()
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
        self.assertFalse(LazyAncestors(rustidx, [0], 0, False))

    def test_standalone_nodetree(self):
        idx = self.parserustindex()
        nt = self.nodetree(idx)
        for i in range(4):
            nt.insert(i)

        bin_nodes = [entry[7] for entry in idx]
        hex_nodes = [hex(n) for n in bin_nodes]

        for i, node in enumerate(hex_nodes):
            self.assertEqual(nt.prefix_rev_lookup(node), i)
            self.assertEqual(nt.prefix_rev_lookup(node[:5]), i)

        # all 4 revisions in idx (standard data set) have different
        # first nybbles in their Node IDs,
        # hence `nt.shortest()` should return 1 for them, except when
        # the leading nybble is 0 (ambiguity with NULL_NODE)
        for i, (bin_node, hex_node) in enumerate(zip(bin_nodes, hex_nodes)):
            shortest = nt.shortest(bin_node)
            expected = 2 if hex_node[0] == ord('0') else 1
            self.assertEqual(shortest, expected)
            self.assertEqual(nt.prefix_rev_lookup(hex_node[:shortest]), i)

        # test invalidation (generation poisoning) detection
        del idx[3]
        self.assertTrue(nt.is_invalidated())


# Conditional skipping done by the base class
class PyO3InnerRevlogTest(
    revlogtesting.PyO3RevlogBasedTestBase, RustInnerRevlogTestMixin
):
    """Testing new PyO3 bindings, by comparison with rust-cpython bindings."""


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
