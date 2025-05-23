  $ . "$TESTDIR/helpers-testrepo.sh"

  $ . "$TESTDIR/helper-runtests.sh"

Testing that hghave does not crash when checking features

  $ hghave --test-features 2>/dev/null

Testing hghave extensibility for third party tools

  $ cat > hghaveaddon.py <<EOF
  > import hghave
  > @hghave.check("custom", "custom hghave feature")
  > def has_custom():
  >     return True
  > EOF

(invocation via run-tests.py)

  $ cat > test-hghaveaddon.t <<EOF
  > #require custom
  >   $ echo foo
  >   foo
  > EOF

# We use --pure install to avoid doing a full build and install of Mercurial in
# the middle of the test (and the associated dependencies)

  $ ( \
  > testrepohgenv; \
  > "$PYTHON" $TESTDIR/run-tests.py \
  >     --with-hg=$HGTEST_REAL_HG \
  >     --jobs 1 \
  >     --pure \
  >     test-hghaveaddon.t \
  > )
  installed Mercurial in * seconds  (glob) (?)
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

(invocation via command line)

  $ unset TESTDIR
  $ hghave custom

(terminate with exit code 2 at failure of importing hghaveaddon.py)

  $ rm hghaveaddon.*
  $ cat > hghaveaddon.py <<NO_CHECK_EOF
  > importing this file should cause syntax error
  > NO_CHECK_EOF

  $ hghave custom
  failed to import hghaveaddon.py from '.': invalid syntax (hghaveaddon.py, line 1)
  [2]
