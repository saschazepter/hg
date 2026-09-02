# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import hashlib
import itertools
import struct
import typing

from .i18n import _
from .thirdparty import attr
from . import (
    error,
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

    def matcher(self, root_path: bytes, warn=None):
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
                warn=warn,
            )
        if not self.children:
            return top_matcher

        subs = []
        for child in self.children:
            # Make sure the tree is well-formed
            assert child.included != self.included
            subs.append(child.matcher(root_path, warn=warn))

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

        buf = [SERIALIZATION_SHAPE_MARKER]
        sorted_paths = sorted(
            itertools.chain(includes, excludes), key=lambda x: zero_path(x)
        )

        buf.append(struct.pack(b"<Q", len(sorted_paths)))

        for path in sorted_paths:
            prefix = PREFIX_INCLUDE if path in includes else PREFIX_EXCLUDE
            buf.append(b"%s%s\n" % (prefix, path))

        return pycompat.sysbytes(hashlib.sha256(b"".join(buf)).hexdigest())


# Magic marker to help identify the format easily
SERIALIZATION_SHAPE_MARKER = b"shape-v1\n"
# Serialization prefix for included paths
PREFIX_INCLUDE = b"inc/"
# Serialization prefix for excluded paths
PREFIX_EXCLUDE = b"exc/"


def deserialize(data: bytes) -> tuple[list[bytes], list[bytes]]:
    """Returns the includes and exclude paths, by doing the reverse operation
    of the serialization used for fingerprints"""
    rest = data.removeprefix(SERIALIZATION_SHAPE_MARKER)
    if rest == data:
        raise error.Abort(_(b"error deserializing shape: missing marker"))

    SIZE_OF_LEN = 8
    int_buffer = rest[:SIZE_OF_LEN]
    if len(int_buffer) < SIZE_OF_LEN:
        raise error.Abort(_(b"error deserializing shape: invalid length"))
    length = int.from_bytes(int_buffer, byteorder='little', signed=False)

    rest = rest[SIZE_OF_LEN:]
    includes = []
    excludes = []

    SIZE_OF_PREFIXES = 4

    for idx, line in enumerate(rest.splitlines()):
        if idx >= length:
            # There must be an empty line
            if idx == length and not line:
                # Don't break, let it fail if it loops more than expected
                continue
            else:
                msg = _(
                    b"error deserializing shape: too many paths, "
                    b"expected %d, got %d"
                )
                raise error.Abort(msg % (length, len(rest.splitlines())))
        prefix = line[:SIZE_OF_PREFIXES]
        if len(prefix) < SIZE_OF_PREFIXES:
            msg = _(b"error deserializing shape: invalid prefix '%s'")
            raise error.Abort(msg % prefix)

        path = line[SIZE_OF_PREFIXES:]
        if prefix == PREFIX_EXCLUDE:
            excludes.append(path)
        elif prefix == PREFIX_INCLUDE:
            includes.append(path)
        else:
            msg = _(b"error deserializing shape: invalid prefix '%s'")
            raise error.Abort(msg % prefix)

    return (includes, excludes)


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
    root: bytes,
    include: set[bytes],
    exclude: set[bytes] | None,
    warn=None,
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
        return pattern_tree.matcher(root, warn=warn)


def u2b(i: int, size: int) -> bytes:
    """helper to encode an `int` into `bytes`"""
    return i.to_bytes(length=size, byteorder='big', signed=False)


def b2u(data: bytes) -> int:
    """helper to decode an `int` from `bytes"""
    return int.from_bytes(data, byteorder='big', signed=False)


PATTERN_INCLUDED_FLAG = 1 << 15


def _serialize_v1(shape) -> bytes:
    """The shape patterns serialized in "v1" format

    This method is likely temporary, as the logic will be implemented in Rust
    soon enough.
    """
    includes, excludes = shape.patterns()

    patterns = [(p, True) for p in includes]
    patterns.extend((p, False) for p in excludes)
    assert len(patterns) == len(
        set(includes) | set(excludes)
    )  # sanity check duplicates

    patterns.sort(key=lambda x: zero_path(x[0]))

    pieces = [u2b(len(patterns), 4)]
    for pat, included in patterns:
        size = len(pat)
        assert size < PATTERN_INCLUDED_FLAG
        if included:
            size |= PATTERN_INCLUDED_FLAG
        pieces.append(u2b(size, 2))
    for pat, _included in patterns:
        pieces.append(pat)
    return b''.join(pieces)


def _deserialize_v1(data: bytes) -> tuple[set[bytes], set[bytes]]:
    """get patterns from a "v1" serialized block"""
    # XXX error handling needs to exists at some point
    assert len(data) >= 4  # XXX should be a proper error
    count = b2u(data[:4])
    cursor = 4
    if count == 0:
        return (set(), set())
    sizes = []
    for __ in range(count):
        sizes.append(b2u(data[cursor : cursor + 2]))
        cursor += 2
    includes = set()
    excludes = set()
    for s in sizes:
        if s & PATTERN_INCLUDED_FLAG:
            pats = includes
        else:
            pats = excludes
        s &= ~PATTERN_INCLUDED_FLAG
        pats.add(data[cursor : cursor + s])
        cursor += s
    assert cursor == len(data), (
        cursor,
        len(data),
    )  # XXX should be a proper error
    return (includes, excludes)


def _encode_fingerprints(fingerprints: list[bytes]) -> bytes:
    """encode a "fingerprints" block use by `store_shape` wireprotocol command"""
    pieces = [u2b(len(fingerprints), 1)]
    pieces.extend(u2b(len(fp), 1) for fp in fingerprints)
    pieces.extend(fingerprints)
    return b''.join(pieces)


def _decode_fingerprints(data: bytes) -> list[bytes]:
    """decode a "fingerprints" block use by `store_shape` wireprotocol command"""
    # XXX error handling needs to exists at some point
    count = b2u(data[:1])
    cursor = 1 + count
    fingerprints = []
    for idx in range(1, count + 1):
        fp_size = b2u(data[idx : idx + 1])
        fingerprints.append(data[cursor : cursor + fp_size])
        cursor += fp_size
    return fingerprints


def _encode_shards_sets(shards_sets: list[set[bytes]]) -> bytes:
    """encode a "shards_sets" block use by `store_shape` wireprotocol command"""
    pieces = [u2b(len(shards_sets), 1)]
    for s in shards_sets:
        assert len(s) >= 1
        lengths = set(len(shard_id) for shard_id in s)
        assert len(lengths) == 1
        length = lengths.pop()
        pieces.append(u2b(length, 1))
        pieces.append(u2b(len(s), 2))
    for s in shards_sets:
        pieces.extend(sorted(s))
    return b''.join(pieces)


def _decode_shards_sets(data: bytes) -> list[set[bytes]]:
    """decode a "shards_sets" block use by `store_shape` wireprotocol command"""
    # XXX error handling needs to exists at some point
    sets_count = b2u(data[:1])
    cursor = 1
    sets_info = []
    for __ in range(sets_count):
        sets_info.append(
            (
                b2u(data[cursor : cursor + 1]),
                b2u(data[cursor + 1 : cursor + 3]),
            )
        )
        cursor += 3
    shards_sets = []
    for id_size, count in sets_info:
        one_set = set()
        for __ in range(count):
            one_set.add(data[cursor : cursor + id_size])
            cursor += id_size
        shards_sets.append(one_set)
    assert cursor == len(data)
    return shards_sets


# XXX having this in the Python module and not in the Rust module is
# "unexpected" and should be fixed" sooner than later.
def wire_store_shape_encode(
    shards_sets: list[set[bytes]],
    shape,
) -> tuple[bytes, bytes, bytes]:
    """encode the three blocks used by `store_shape` wireprotocol command"""
    return (
        _encode_fingerprints([shape.fingerprint()]),
        _encode_shards_sets(shards_sets),
        _serialize_v1(shape),
    )


# XXX having this in the Python module and not in the Rust module is
# "unexpected" and should be fixed" sooner than later.
def wire_store_shape_decode(
    fingerprints_block: bytes,
    shards_sets_block: bytes,
    patterns_block: bytes,
) -> tuple[list[bytes], list[set[bytes]], tuple[set[bytes], set[bytes]]]:
    """decode the three blocks used by `store_shape` wireprotocol command"""
    return (
        _decode_fingerprints(fingerprints_block),
        _decode_shards_sets(shards_sets_block),
        _deserialize_v1(patterns_block),
    )
