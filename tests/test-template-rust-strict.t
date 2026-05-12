Verify that the Rust template parser is wired up to the command line. The
parser's behavior is tested in test-template-rust.py.

#require rust

  $ hg init r
  $ cd r
  $ echo a > a
  $ hg ci -qAm initial

A template renders through the Rust parser:

  $ hg log -r 0 -T 'rev: {rev}'
  rev: 0 (no-eol)

The devel.template-rust-strict config reaches the parser. A template the Rust
parser cannot handle falls back to Python by default, but raises when strict:

  $ hg log -r 0 -T '{\"foo\"}'
  foo (no-eol)
  $ hg log -r 0 -T '{\"foo\"}' --config devel.template-rust-strict=yes
  hg: parse error at 1: * (glob)
  [10]
