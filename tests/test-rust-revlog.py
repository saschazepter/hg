import struct

from mercurial.node import (
    bin as node_bin,
    hex,
)
from mercurial import error

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
    bogus_node_hex = b'cafe' * 10
    bogus_node = node_bin(bogus_node_hex)
    node_hex2 = b"020a0ec626a192ae360b0269fe2de5ba6f05d1e7"
    node2 = node_bin(node_hex2)

    def test_index_nodemap(self):
        idx = self.parserustindex()
        self.assertTrue(idx.has_node(self.node0))
        self.assertFalse(idx.has_node(self.bogus_node))

        self.assertEqual(idx.get_rev(self.node0), 0)
        self.assertEqual(idx.get_rev(self.node0), 0)

        self.assertEqual(idx.rev(self.node0), 0)
        with self.assertRaises(error.RevlogError) as exc_info:
            idx.rev(self.bogus_node)
        self.assertEqual(exc_info.exception.args, (None,))

        self.assertEqual(idx.partialmatch(self.node_hex0[:3]), self.node0)
        self.assertIsNone(idx.partialmatch(self.bogus_node_hex[:3]))
        self.assertEqual(idx.shortest(self.node0), 1)

    def test_len(self):
        idx = self.parserustindex()
        self.assertEqual(len(idx), 4)

    def test_getitem(self):
        idx = self.parserustindex()
        as_tuple = (0, 82969, 484626, 0, 0, -1, -1, self.node0, 0, 0, 2, 2, -1)
        self.assertEqual(idx[0], as_tuple)
        self.assertEqual(idx[self.node0], 0)

    def test_heads(self):
        idx = self.parserustindex()
        self.assertEqual(idx.headrevs(), [3])

    def test_index_append(self):
        idx = self.parserustindex(data=b'')
        self.assertEqual(len(idx), 0)
        self.assertIsNone(idx.get_rev(self.node0))

        non_empty_index = self.parserustindex()
        idx.append(non_empty_index[0])
        self.assertEqual(len(idx), 1)
        self.assertEqual(idx.get_rev(self.node0), 0)

    def test_index_delitem_single(self):
        idx = self.parserustindex()
        del idx[2]
        self.assertEqual(len(idx), 2)

        # the nodetree is consistent
        self.assertEqual(idx.get_rev(self.node0), 0)
        self.assertIsNone(idx.get_rev(self.node2))

        # not an error and does nothing
        del idx[-1]
        self.assertEqual(len(idx), 2)

        for bogus in (-2, 17):
            try:
                del idx[bogus]
            except ValueError as exc:
                # this underlines that we should do better with this message
                assert exc.args[0] == (
                    f"Inconsistency: Revision {bogus} found in nodemap "
                    "is not in revlog index"
                )
            else:
                raise AssertionError(
                    f"an exception was expected for `del idx[{bogus}]`"
                )

    def test_index_delitem_slice(self):
        idx = self.parserustindex()
        del idx[2:3]
        self.assertEqual(len(idx), 2)

        # not an error and not equivalent to `del idx[0::]` but to
        # `del idx[-1]` instead and thus does nothing.
        del idx[-1::]
        self.assertEqual(len(idx), 2)

        for start, stop in (
            (-2, None),
            (17, None),
        ):
            try:
                del idx[start:stop]
            except ValueError as exc:
                # this underlines that we should do better with this message
                assert exc.args[0] == (
                    f"Inconsistency: Revision {start} found in nodemap "
                    "is not in revlog index"
                )
            else:
                raise AssertionError(
                    f"an exception was expected for `del idx[{start}:{stop}]`"
                )

        # although the upper bound is way too big, this is not an error:
        del idx[0::17]
        self.assertEqual(len(idx), 0)

    def test_standalone_nodetree(self):
        idx = self.parserustindex()
        nt = self.nodetree(idx)
        for i in range(4):
            nt.insert(i)

        # invalidation is upon mutation *of the index*
        self.assertFalse(nt.is_invalidated())

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

    def test_reading_context_manager(self):
        irl = self.make_inner_revlog()
        try:
            with irl.reading():
                # not much to do yet
                pass
        except error.RevlogError as exc:
            # well our data file does not even exist
            self.assertTrue(b"when reading Just a path/test.d" in exc.args[0])


# Conditional skipping done by the base class
class RustInnerRevlogTest(
    revlogtesting.RustRevlogBasedTestBase, RustInnerRevlogTestMixin
):
    """For reference"""

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

    def test_canonical_index_file(self):
        irl = self.make_inner_revlog()
        self.assertEqual(irl.canonical_index_file, b'test.i')


# Conditional skipping done by the base class
class PyO3InnerRevlogTest(
    revlogtesting.PyO3RevlogBasedTestBase, RustInnerRevlogTestMixin
):
    """Testing new PyO3 bindings, by comparison with rust-cpython bindings."""


if __name__ == '__main__':
    import silenttestrunner

    silenttestrunner.main(__name__)
