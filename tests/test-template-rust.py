import unittest

from mercurial import (
    error,
    templater,
)

# Templates that the Rust parser fully supports. For each, the tree it produces must
# match the Python parser exactly.
SUPPORTED = [
    b"rev: {rev}",
]

# Templates the Rust parser does not handle but the Python parser does. Under
# strict mode Rust must raise; otherwise parsing must fall back to Python.
FALLBACK = [
    rb'{\"foo\n\"}',  # legacy escape-quoted string literal
    rb"\a",  # unrecognized backslash escape
]


@unittest.skipIf(
    templater.rustmod is None,
    "rust extensions the templater relies on are not available",
)
class RustTemplateParseTest(unittest.TestCase):
    """Test that the Rust parser handles supported templates the same way the Python
    parser does."""

    def python_parse(self, tmpl):
        rustmod = templater.rustmod
        templater.rustmod = None
        try:
            return templater.parse(tmpl)
        finally:
            templater.rustmod = rustmod

    def test_supported_matches_python(self):
        for tmpl in SUPPORTED:
            self.assertEqual(
                templater.parse(tmpl, rust_strict=True),
                self.python_parse(tmpl),
                tmpl,
            )

    def test_unsupported_falls_back(self):
        for tmpl in FALLBACK:
            with self.assertRaises(error.ParseError):
                templater.parse(tmpl, rust_strict=True)
            self.assertEqual(
                templater.parse(tmpl, rust_strict=False),
                self.python_parse(tmpl),
                tmpl,
            )


if __name__ == "__main__":
    import silenttestrunner

    silenttestrunner.main(__name__)
