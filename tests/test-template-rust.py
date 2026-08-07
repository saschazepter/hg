import unittest

from mercurial import (
    error,
    templater,
)

# Templates that the Rust parser fully supports. For each, the tree it produces must
# match the Python parser exactly.
SUPPORTED = [
    b"rev: {rev}",
    rb"rev: {rev}\n",
    b"{short(node)}",
    b"{pad(rev, 4, left=desc)}",
    rb'{if(rev, "rev is {rev}\n")}',
    b"{'on branch {branch}'}",
    rb"{r'a\nb'}",
    rb"a\0b",
    rb"a\08b",
    rb'{"a\0b"}',
    b"{node|short}",
    b"{-(1 + 2) * 3}",
    rb'{files % "{file}\n"}',
    b"{0}",
    b"{(0)}",
    b"a\xe9b",
    b"{ifcontains('\xe9', files, 'wow', 'not')}",
]

# Templates the Rust parser does not handle but the Python parser does. Under
# strict mode Rust must raise; otherwise parsing must fall back to Python.
FALLBACK = [
    rb'{\"foo\n\"}',  # legacy escape-quoted string literal
    rb"\a",  # unrecognized backslash escape
    rb"a\000b",  # octal escape
    rb"{join(files, '\000')}",  # octal escape in a string literal
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
