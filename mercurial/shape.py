# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import hashlib
import itertools
import re
import struct
import typing

from .i18n import _
from .node import (
    bin,
    hex,
)
from .thirdparty import attr
from . import (
    error,
    match as matchmod,
    policy,
    pycompat,
    util,
)

if typing.TYPE_CHECKING:
    import attr
    from .interfaces.types import RepoT
    from .interfaces.repository import (
        FingerprintT,
        ShapeFingerprintT,
        ShardFingerprintT,
    )
else:
    FingerprintT = ShapeFingerprintT = ShardFingerprintT = object

rustmod = policy.importrust("shape")


# The version of the fingerprint computation that we currently produce
FINGERPRINT_VERSION = 0
# Size in bytes of the digest of a fingerprint
FINGERPRINT_DIGEST_SIZE = 32
# Validator regex for a text representation of a fingerprint
_FINGERPRINT_TEXT_RE = re.compile(
    br'(shape|shard)([0-9]{2,3})-([0-9a-f]{%d})' % (2 * FINGERPRINT_DIGEST_SIZE)
)


def _check_digest(inst, attr, value: bytes):
    if len(value) != FINGERPRINT_DIGEST_SIZE:
        raise ValueError("invalid fingerprint digest: %r" % value)


@attr.s(frozen=True, slots=True)
class Fingerprint(FingerprintT):
    """Identifies a given set of files in the store. Two semantically
    equivalent shapes (or shards) have the same fingerprint.

    Fingerprinting can be evolved over time, so it is tagged with the version
    of the computation that produced it. A fingerprint with a version that we
    do not know about is valid, it simply cannot match anything we compute.

    The text form (see `to_text`) is only used for user-facing things."""

    TARGET: str
    """used for error and debug"""

    TEXT_PREFIX: bytes
    """The prefix of the text form, making it explicit which kind of object a
    fingerprint identifies"""

    version = attr.ib(type=int)
    """The version of the computation that produced `digest`"""

    digest = attr.ib(type=bytes, validator=_check_digest)
    """The hash of the normalized shape"""

    def to_bytes(self) -> bytes:
        """The binary form of this fingerprint: one byte for the version,
        followed by the digest"""
        return u2b(self.version, 1) + self.digest

    @classmethod
    def from_bytes(cls, data: bytes) -> typing.Self:
        """Parse the binary form of a fingerprint of the given `kind`"""
        return cls(b2u(data[:1]), data[1:])

    def to_text(self) -> bytes:
        r"""The textual form of this fingerprint: `shapeXY-<hex>` for a shape
        and `shardXY-<hex>` for a shard, with `XY` the version as a decimal
        number padded to two digits and `<hex>` the hexadecimal digest

        >>> ShapeFingerprint(0, b'\xab' * 32).to_text()
        b'shape00-abababababababababababababababababababababababababababababababab'
        >>> ShardFingerprint(0, b'\xab' * 32).to_text()
        b'shard00-abababababababababababababababababababababababababababababababab'
        >>> ShapeFingerprint(12, b'\x01' * 32).to_text()
        b'shape12-0101010101010101010101010101010101010101010101010101010101010101'
        >>> ShapeFingerprint(255, b'\x01' * 32).to_text()
        b'shape255-0101010101010101010101010101010101010101010101010101010101010101'
        """
        prefix = self.TEXT_PREFIX
        return b'%s%02d-%s' % (prefix, self.version, hex(self.digest))

    @classmethod
    def from_text(cls, text: bytes) -> typing.Self:
        r"""Parse the textual form of a fingerprint

        Raises `ValueError` if `text` is not the textual form of such a
        fingerprint.

        >>> fp = ShapeFingerprint.from_text(b'shape12-' + b'ab' * 32)
        >>> fp == ShapeFingerprint(12, b'\xab' * 32)
        True
        >>> fp = ShapeFingerprint.from_text(b'shape255-' + b'01' * 32)
        >>> fp == ShapeFingerprint(255, b'\x01' * 32)
        True
        >>> for invalid in [b'', b'abab', b'shape00-', b'shape00-' + b'ab' * 31,
        ...                 b'shape00-' + b'ab' * 33, b'shape00-' + b'AB' * 32,
        ...                 b'shape00-' + b'ab' * 32 + b' ',
        ...                 b'shape00:' + b'ab' * 32, b'shape-' + b'ab' * 32,
        ...                 b'shape0-' + b'ab' * 32, b'shape256-' + b'ab' * 32,
        ...                 b'shape012-' + b'ab' * 32, b'00-' + b'ab' * 32,
        ...                 b'shard00-' + b'ab' * 32]:
        ...     try:
        ...         ShapeFingerprint.from_text(invalid)
        ...     except ValueError:
        ...         pass
        ...     else:
        ...         raise AssertionError(invalid)
        >>> ShardFingerprint.from_text(b'shape00-abab')
        Traceback (most recent call last):
            ...
        ValueError: not a shard fingerprint: b'shape00-abab'
        """
        m = _FINGERPRINT_TEXT_RE.fullmatch(text)
        if m is not None and m.group(1) == cls.TEXT_PREFIX:
            raw_version = m.group(2)
            version = int(raw_version)
            if version <= 255 and raw_version == b'%02d' % version:
                return cls(version, bin(m.group(3)))
        msg = "not a %s fingerprint: %r"
        raise ValueError(msg % (cls.TARGET, text))


class ShapeFingerprint(Fingerprint, ShapeFingerprintT):
    TARGET = "shape"
    """used for error and debug"""

    TEXT_PREFIX = b'shape'


class ShardFingerprint(Fingerprint, ShardFingerprintT):
    TARGET = "shard"
    """used for error and debug"""

    TEXT_PREFIX = b'shard'


# File listing filenames of the saved `server-shapes` configs.
PREVIOUS_SHAPES_LIST = b'server-shapes-previous-list'


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

    def fingerprint(self) -> ShapeFingerprint:
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

        digest = hashlib.sha256(b"".join(buf)).digest()
        return ShapeFingerprint(FINGERPRINT_VERSION, digest)


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
) -> ShapeFingerprint | None:
    """The fingerprint of these patterns, `None` if it cannot be computed

    Uses the Rust implementation if available."""
    if rustmod is None:
        return py_fingerprint_for_patterns(include_pats, exclude_pats)
    fp = rustmod.fingerprint_for_patterns(include_pats, exclude_pats)
    if fp is None:
        return None
    return ShapeFingerprint(**fp)


def py_fingerprint_for_patterns(
    include_pats: set[bytes], exclude_pats: set[bytes]
) -> ShapeFingerprint:
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

_PATTERNS_COUNT_SIZE = 4
_PATTERN_SIZE_SIZE = 2


def serialize_patterns(
    includes: typing.Iterable[bytes], excludes: typing.Iterable[bytes]
) -> bytes:
    r"""Serialize includes and excludes into a "patterns block"

    The binary format is the following (all integers are big-endian):

        `<COUNT>[<SIZE>...][<PATH>...]`

    With:
    - `<COUNT>`, the number of paths as a 32 bits integer
    - `[X...]` is syntax for "for each path, X"
    - `<SIZE>`, the size in bytes of i-th path as a 16 bits integer. Its
      highest bit is set if the path is included, and unset if it is
      excluded (see `PATTERN_INCLUDED_FLAG`)
    - `<PATH>`, the raw bytes of the i-th path, rooted at the empty path

    Paths are sorted by `zero_path`, so a directory is directly followed by
    its contents.

    >>> serialize_patterns({b'foo', b'foo-x'}, {b'', b'foo/bar'})
    b'\x00\x00\x00\x04\x00\x00\x80\x03\x00\x07\x80\x05foofoo/barfoo-x'
    >>> serialize_patterns(set(), set())
    b'\x00\x00\x00\x00'
    """
    includes = set(includes)
    excludes = set(excludes)
    if includes & excludes:
        raise error.ProgrammingError(b"duplicated paths in patterns")
    patterns = [(p, True) for p in includes]
    patterns.extend((p, False) for p in excludes)

    patterns.sort(key=lambda x: zero_path(x[0]))

    pieces = [u2b(len(patterns), _PATTERNS_COUNT_SIZE)]
    for pat, included in patterns:
        size = len(pat)
        if size >= PATTERN_INCLUDED_FLAG:
            raise error.Abort(_(b"path is too long: %d bytes") % size)
        if included:
            size |= PATTERN_INCLUDED_FLAG
        pieces.append(u2b(size, _PATTERN_SIZE_SIZE))
    for pat, _included in patterns:
        pieces.append(pat)
    return b''.join(pieces)


def _check_patterns_length(data: bytes, expected: int, exact: bool = False):
    """Abort if the patterns block `data` is shorter than `expected` bytes,
    or of any other size if `exact` is set"""
    invalid = len(data) != expected if exact else len(data) < expected
    if invalid:
        msg = _(
            b"error deserializing shape: invalid length "
            b"(expected %d, got %d)"
        )
        raise error.Abort(msg % (expected, len(data)))


def _deserialize_patterns(data: bytes) -> tuple[set[bytes], set[bytes]]:
    r"""Return the includes and excludes from a "patterns block"

    See `serialize_patterns` for details about the format.

    >>> block = (b'\x00\x00\x00\x04\x00\x00\x80\x03\x00\x07\x80\x05'
    ...          b'foofoo/barfoo-x')
    >>> includes, excludes = _deserialize_patterns(block)
    >>> sorted(includes), sorted(excludes)
    ([b'foo', b'foo-x'], [b'', b'foo/bar'])
    >>> _deserialize_patterns(b'\x00\x00\x00\x00')
    (set(), set())
    >>> def check(data):
    ...     try:
    ...         _deserialize_patterns(data)
    ...     except error.Abort as e:
    ...         print(e.message.decode())
    >>> check(b'\x00\x00\x01')
    error deserializing shape: invalid length (expected 4, got 3)
    >>> check(b'\x00\x00\x00\x02\x80\x03')
    error deserializing shape: invalid length (expected 8, got 6)
    >>> check(b'\x00\x00\x00\x01\x80\x03fo')
    error deserializing shape: invalid length (expected 9, got 8)
    >>> check(b'\x00\x00\x00\x01\x80\x03fooo')
    error deserializing shape: invalid length (expected 9, got 10)
    >>> check(b'\x00\x00\x00\x00f')
    error deserializing shape: invalid length (expected 4, got 5)
    >>> check(b'\x00\x00\x00\x01\x00\x02/f')
    error deserializing shape: invalid path '/f'
    """
    # Validate everything we can from the fixed-size information first
    _check_patterns_length(data, _PATTERNS_COUNT_SIZE)
    count = b2u(data[:_PATTERNS_COUNT_SIZE])
    paths_start = _PATTERNS_COUNT_SIZE + count * _PATTERN_SIZE_SIZE
    _check_patterns_length(data, paths_start)

    sizes = []
    for cursor in range(_PATTERNS_COUNT_SIZE, paths_start, _PATTERN_SIZE_SIZE):
        raw = b2u(data[cursor : cursor + _PATTERN_SIZE_SIZE])
        included = bool(raw & PATTERN_INCLUDED_FLAG)
        sizes.append((raw & ~PATTERN_INCLUDED_FLAG, included))
    paths_size = sum(size for size, _included in sizes)
    _check_patterns_length(data, paths_start + paths_size, exact=True)

    includes = set()
    excludes = set()
    cursor = paths_start
    for size, included in sizes:
        path = data[cursor : cursor + size]
        cursor += size
        if (
            b'\0' in path
            or b'//' in path
            or path.startswith(b'/')
            or path.endswith(b'/')
        ):
            msg = _(b"error deserializing shape: invalid path '%s'")
            raise error.Abort(msg % path)
        if included:
            includes.add(path)
        else:
            excludes.add(path)
    return (includes, excludes)


def _encode_fingerprints(fingerprints: list[ShapeFingerprint]) -> bytes:
    """encode a "fingerprints" block use by `store_shape` wireprotocol command"""
    pieces = [u2b(len(fingerprints), 1)]
    pieces.extend(u2b(len(fp.to_bytes()), 1) for fp in fingerprints)
    pieces.extend(fp.to_bytes() for fp in fingerprints)
    return b''.join(pieces)


def _decode_fingerprints(data: bytes) -> list[ShapeFingerprint]:
    """decode a "fingerprints" block use by `store_shape` wireprotocol command"""
    # XXX error handling needs to exists at some point
    count = b2u(data[:1])
    cursor = 1 + count
    fingerprints = []
    for idx in range(1, count + 1):
        fp_size = b2u(data[idx : idx + 1])
        raw = data[cursor : cursor + fp_size]
        fingerprints.append(ShapeFingerprint.from_bytes(raw))
        cursor += fp_size
    return fingerprints


def _encode_shards_sets(shards_sets: list[set[ShardFingerprint]]) -> bytes:
    """encode a "shards_sets" block use by `store_shape` wireprotocol command"""
    pieces = [u2b(len(shards_sets), 1)]
    for s in shards_sets:
        assert len(s) >= 1
        lengths = set(len(shard_id.to_bytes()) for shard_id in s)
        assert len(lengths) == 1
        length = lengths.pop()
        pieces.append(u2b(length, 1))
        pieces.append(u2b(len(s), 2))
    for s in shards_sets:
        pieces.extend(sorted(shard_id.to_bytes() for shard_id in s))
    return b''.join(pieces)


def _decode_shards_sets(data: bytes) -> list[set[ShardFingerprint]]:
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
            raw = data[cursor : cursor + id_size]
            one_set.add(ShardFingerprint.from_bytes(raw))
            cursor += id_size
        shards_sets.append(one_set)
    assert cursor == len(data)
    return shards_sets


# XXX having this in the Python module and not in the Rust module is
# "unexpected" and should be fixed" sooner than later.
def wire_store_shape_encode(
    shards_sets: list[set[ShardFingerprint]],
    shape,
) -> tuple[bytes, bytes, bytes]:
    """encode the three blocks used by `store_shape` wireprotocol command"""
    fingerprint = ShapeFingerprint(**shape.fingerprint())
    return (
        _encode_fingerprints([fingerprint]),
        _encode_shards_sets(shards_sets),
        serialize_patterns(*shape.patterns()),
    )


# XXX having this in the Python module and not in the Rust module is
# "unexpected" and should be fixed" sooner than later.
def wire_store_shape_decode(
    fingerprints_block: bytes,
    shards_sets_block: bytes,
    patterns_block: bytes,
) -> tuple[
    list[ShapeFingerprint],
    list[set[ShardFingerprint]],
    tuple[set[bytes], set[bytes]],
]:
    """decode the three blocks used by `store_shape` wireprotocol command"""
    return (
        _decode_fingerprints(fingerprints_block),
        _decode_shards_sets(shards_sets_block),
        _deserialize_patterns(patterns_block),
    )


def previous_configs(repo: RepoT) -> list[bytes]:
    """The filename of each saved `server-shapes` config, oldest first."""
    return repo.svfs.tryread(PREVIOUS_SHAPES_LIST).splitlines()


def read_previous_configs(repo: RepoT) -> list[tuple[bytes, bytes]]:
    """The (filename, contents) of each saved `server-shapes` config."""
    configs = []
    for name in previous_configs(repo):
        if contents := repo.svfs.tryread(name):
            configs.append((name, contents))
    return configs


def shard_fingerprints_sets(shards_sets) -> list[set[ShardFingerprint]]:
    """Wrap the sets of shard fingerprints returned by the Rust bindings"""
    return [{ShardFingerprint(**fp) for fp in s} for s in shards_sets]


def previous_shards_sets(
    repo: RepoT,
    name: str,
    fingerprint: ShapeFingerprint,
) -> list[set[ShardFingerprint]]:
    """Shard fingerprint sets from previous versions of the `server-shapes` config.

    During the period of time between an admin resharding the store and the new sharded
    bundles getting generated, clients must still be able to clone via the old bundles.
    Saving and reading the previous versions of the `server-shapes` config allows the
    old bundles to still be usable.

    Only configs that still define `name` with `fingerprint` are used since a different
    fingerprint means the shape covers a different set of files."""
    sets = []
    for __, contents in read_previous_configs(repo):
        previous = rustmod.get_store_shards_from_bytes(contents)
        previous_shape = previous.shape(name)
        if previous_shape is None:
            continue
        previous_fp = previous_shape.fingerprint()
        if ShapeFingerprint(**previous_fp) != fingerprint:
            continue
        previous_sets = previous.shard_fingerprints_for_shape(name) or []
        sets.extend(shard_fingerprints_sets(previous_sets))
    return sets


def save_previous_config(repo: RepoT, contents: bytes) -> bytes:
    """Save `contents` as a previous `server-shapes` config.

    Must be called with the store shapes lock held, since it updates the list
    of saved configs. Returns the filename it was written to."""
    digest = pycompat.sysbytes(hashlib.sha256(contents).hexdigest())
    name = b'server-shapes-previous-' + digest[:12]
    repo.svfs.write(name, contents, atomictemp=True)
    saved = previous_configs(repo)
    if name not in saved:
        data = b'\n'.join(saved + [name])
        repo.svfs.write(PREVIOUS_SHAPES_LIST, data, atomictemp=True)
    return name


def clear_previous_configs(repo: RepoT) -> list[bytes]:
    """Clear every saved `server-shapes` config.

    Must be called with the store shapes lock held, since it updates the list
    of saved configs. Returns the filenames that were removed."""
    cleared = previous_configs(repo)
    for name in cleared:
        repo.svfs.tryunlink(name)
    repo.svfs.write(PREVIOUS_SHAPES_LIST, b'', atomictemp=True)
    return cleared
