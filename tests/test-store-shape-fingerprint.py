"""Compare Python and Rust fingerprint computations."""
from __future__ import annotations

import hashlib
import unittest

import silenttestrunner

from mercurial import shape


def expected_fingerprint(
    includes: set[bytes], excludes: set[bytes]
) -> shape.ShapeFingerprint:
    """The fingerprint of an already normalized tree, given as the paths it
    includes and excludes (rooted at `b''`)"""
    patterns = shape.serialize_patterns(includes, excludes)
    digest = hashlib.sha256(patterns).digest()
    return shape.ShapeFingerprint(shape.FINGERPRINT_VERSION, digest)


def py_fingerprint(
    includes: set[bytes], excludes: set[bytes]
) -> shape.ShapeFingerprint | None:
    return shape.py_fingerprint_for_patterns(set(includes), set(excludes))


def rust_fingerprint(
    includes: set[bytes], excludes: set[bytes]
) -> shape.ShapeFingerprint | None:
    fp = shape.rustmod.fingerprint_for_patterns(set(includes), set(excludes))
    return None if fp is None else shape.ShapeFingerprint(**fp)


@unittest.skipIf(shape.rustmod is None, "Rust extensions are not available")
class FingerprintTests(unittest.TestCase):
    def assert_fingerprint(
        self,
        includes: set[bytes],
        excludes: set[bytes],
        expected: shape.ShapeFingerprint,
    ) -> None:
        """Check that both implementations give `expected` for these
        patterns"""
        self.assertEqual(py_fingerprint(includes, excludes), expected)
        self.assertEqual(rust_fingerprint(includes, excludes), expected)

    def test_nested(self):
        self.assert_fingerprint(
            {b'path:foo'},
            {b'path:foo/bar'},
            expected_fingerprint({b'foo'}, {b'', b'foo/bar'}),
        )

    def test_path_is_both_included_and_excluded(self):
        self.assert_fingerprint(
            {b'path:foo', b'path:bar'},
            {b'path:foo'},
            expected_fingerprint({b'bar'}, {b''}),
        )
        self.assert_fingerprint(
            {b'path:foo'},
            {b'path:foo'},
            expected_fingerprint(set(), {b''}),
        )
        self.assert_fingerprint(
            {b'path:'},
            {b'path:'},
            expected_fingerprint(set(), {b''}),
        )

    def test_path_after_path_prefix_is_literal(self):
        self.assert_fingerprint(
            {b'path:path:foo'},
            set(),
            expected_fingerprint({b'path:foo'}, {b''}),
        )
        self.assert_fingerprint(
            {b'path:glob:foo'},
            set(),
            expected_fingerprint({b'glob:foo'}, {b''}),
        )


if __name__ == '__main__':
    silenttestrunner.main(__name__)
