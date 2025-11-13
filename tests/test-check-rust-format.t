#require rustfmt test-repo

  $ . "$TESTDIR/helpers-testrepo.sh"

  $ cd "$TESTDIR"/..

Warning: Keep this in sync with hghave.py
  $ RUSTFMT=$(rustup which --toolchain nightly-2024-07-16 rustfmt)
  $ for f in `testrepohg files 'set:("**/*.rs") - contrib/**/*.rs - mercurial/thirdparty/**'` ; do
  >   $RUSTFMT --check --unstable-features --color=never $f
  > done
