# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import hashlib
import itertools
import struct
import typing

from .thirdparty import attr
from . import (
    match as matchmod,
    pycompat,
    util,
)

if typing.TYPE_CHECKING:
    import attr


@attr.s(hash=True)
class ShardTreeNode:
    """A node within a tree of narrow patterns.

    It is used to create a normalized representation of potentially nested
    include and exclude patterns to uniquely identify semantically equivalent
    rules, as well as generating an associated file matcher."""

    path = attr.ib(type=bytes, eq=True)
    """The path (rooted by `b""`) that this node concerns"""

    included = attr.ib(type=bool, default=True, eq=True)
    """Whether this path is included or excluded"""

    children = attr.ib(type=set, default=attr.Factory(set), eq=False)
    """The set of child nodes (describing rules for sub-paths)"""

    @staticmethod
    def from_patterns(
        includes: set[bytes], excludes: set[bytes]
    ) -> ShardTreeNode:
        """Transform includes and excludes into a compact tree of those rules."""
        # Need to include everything by default
        root_path = [b""]

        if b"" in includes or b"." in includes or not includes:
            # `clone` passes `path:.` by default which
            # is supposed to include everything. This is the wrong API IMO
            # and is a serialization detail hitting internal logic (empty
            # paths are annoying in text formats).
            # XXX find out how much we need to preserve this behavior
            includes.discard(b".")
            includes.add(b"")
            root_path = []

        # Excludes take precedence over includes (it happens that users include
        # and exclude the same paths, directly or through `--import-rules`)
        includes -= excludes

        nodes = (
            ShardTreeNode(p, p in includes)
            for p in itertools.chain(root_path, includes, excludes)
        )
        stack = []
        for node in sorted(nodes, key=lambda x: x._zero_path):
            while stack and not node._sub_path_of(stack[-1]):
                stack.pop()
            if stack:
                if stack[-1].included != node.included:
                    stack[-1].children.add(node)
                    stack.append(node)
            else:
                stack.append(node)
        root = stack[0]
        return root

    def matcher(self, root_path: bytes):
        """Build the matcher corresponding to this tree."""
        if not self.path:
            # We're the root node
            if self.included:
                top_matcher = matchmod.alwaysmatcher()
            else:
                top_matcher = matchmod.nevermatcher()
        else:
            top_matcher = matchmod.match(
                root_path,
                b'',
                [b'path:%s' % self.path],
            )
        if not self.children:
            return top_matcher

        subs = [n.matcher(root_path) for n in self.children]
        if len(subs) == 1:
            sub_matcher = subs[0]
        else:
            # TODO figure out a way of creating a single matcher with multiple
            # paths instead.
            sub_matcher = matchmod.unionmatcher(subs)

        if not self.path and not self.included:
            return sub_matcher
        return matchmod.differencematcher(top_matcher, sub_matcher)

    @util.propertycache
    def _zero_path(self) -> bytes:
        """A version of the `path` with `\0` instead of `/`.

        This ensures that the path and its subpath get sorted
        next to each other."""
        path = self.path
        return zero_path(path)

    def _sub_path_of(self, other: ShardTreeNode) -> bytes:
        """True if `self` is a sub-path of `other`"""
        return self._zero_path.startswith(other._zero_path)

    def flat(self) -> tuple[frozenset[bytes], frozenset[bytes]]:
        """Return the tree as two flat sets of includes and excludes"""
        inc_paths: set[bytes] = set()
        exc_paths: set[bytes] = set()
        if self.included:
            inc_paths.add(self.path)
        else:
            exc_paths.add(self.path)
        for c in self.children:
            inc, exc = c.flat()
            inc_paths.update(inc)
            exc_paths.update(exc)
        return frozenset(inc_paths), frozenset(exc_paths)

    def fingerprint(self) -> bytes:
        """Get the fingerprint for this node. It will return a different hash
        for a semantically different node, allowing for quick comparison."""
        includes, excludes = self.flat()

        buf = [b"shape-v1\n"]
        sorted_paths = sorted(
            itertools.chain(includes, excludes), key=lambda x: zero_path(x)
        )

        buf.append(struct.pack(b"<Q", len(sorted_paths)))

        for path in sorted_paths:
            prefix = b"inc/" if path in includes else b"exc/"
            buf.append(b"%s%s\n" % (prefix, path))

        return pycompat.sysbytes(hashlib.sha256(b"".join(buf)).hexdigest())


def zero_path(path: bytes) -> bytes:
    assert b'\0' not in path
    assert not path.startswith(b'/')
    assert not path.endswith(b'/')
    if not path:
        path = b'/'
    else:
        path = b'/%s/' % path
    return path.replace(b'/', b'\0')


def fingerprint_for_patterns(
    include_pats: set[bytes], exclude_pats: set[bytes]
) -> bytes | None:
    include_pats = {p.removeprefix(b"path:") for p in include_pats}
    exclude_pats = {p.removeprefix(b"path:") for p in exclude_pats}

    node = ShardTreeNode.from_patterns(include_pats, exclude_pats)
    return node.fingerprint()


def shard_tree_matcher(
    root: bytes, include: set[bytes], exclude: set[bytes] | None
):
    """Return a matcher corresponding to these includes and excludes if they
    can be expressed as a tree, which (for now) only works for `path:`."""
    if exclude is None:
        exclude = set()

    # matchmod.match only works for simple cases. Nested excludes/includes
    # don't work and we need them for shapes, but only for `path:` patterns.
    #
    # `rootfilesin:` does not use the new logic yet because they make the code
    # more complex and are not needed by shapes. Maybe we'll end up
    # implementing it.
    includes_are_paths = all(p.startswith(b"path:") for p in include)
    excludes_are_paths = all(p.startswith(b"path:") for p in exclude)
    if includes_are_paths and excludes_are_paths:
        include = {p.removeprefix(b"path:") for p in include}
        exclude = {p.removeprefix(b"path:") for p in exclude}
        pattern_tree: ShardTreeNode = ShardTreeNode.from_patterns(
            include, exclude
        )
        return pattern_tree.matcher(root)
