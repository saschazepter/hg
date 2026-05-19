Verify that the Rust template parser is wired up to the command line. The
parser's behavior is tested in test-template-rust.py.

#require rust

  $ hg init r
  $ cd r
  $ echo a > a
  $ hg ci -qAm initial
