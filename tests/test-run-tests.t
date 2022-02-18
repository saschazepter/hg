This file tests the behavior of run-tests.py itself.

Avoid interference from actual test env:

  $ . "$TESTDIR/helper-runtests.sh"

Smoke test with install
============
  $ "$PYTHON" $TESTDIR/run-tests.py $HGTEST_RUN_TESTS_PURE -l
  running 0 tests using 0 parallel processes 
  
  # Ran 0 tests, 0 skipped, 0 failed.

Define a helper to avoid the install step
=============
  $ rt()
  > {
  >     "$PYTHON" $TESTDIR/run-tests.py --with-hg=$HGTEST_REAL_HG -j1 "$@"
  > }

error paths

#if symlink
  $ ln -s "/"bin"/"true hg
  $ "$PYTHON" $TESTDIR/run-tests.py --with-hg=./hg
  ^warning: --with-hg should specify an hg script, not: (true|coreutils)$ (re)
  running 0 tests using 0 parallel processes 
  
  # Ran 0 tests, 0 skipped, 0 failed.
  $ rm hg
#endif

#if execbit
  $ touch hg
  $ "$PYTHON" $TESTDIR/run-tests.py --with-hg=./hg
  usage: run-tests.py [options] [tests]
  run-tests.py: error: --with-hg must specify an executable hg script
  [2]
  $ rm hg
#endif

Features for testing optional lines
===================================

  $ cat > hghaveaddon.py <<EOF
  > import hghave
  > @hghave.check("custom", "custom hghave feature")
  > def has_custom():
  >     return True
  > @hghave.check("missing", "missing hghave feature")
  > def has_missing():
  >     return False
  > EOF

an empty test
=======================

  $ touch test-empty.t
  $ rt
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.
  $ rm test-empty.t

a succesful test
=======================

  $ cat > test-success.t << EOF
  >   $ echo babar
  >   babar
  >   $ echo xyzzy
  >   dont_print (?)
  >   nothing[42]line (re) (?)
  >   never*happens (glob) (?)
  >   more_nothing (?)
  >   xyzzy
  >   nor this (?)
  >   $ printf 'abc\ndef\nxyz\n'
  >   123 (?)
  >   abc
  >   def (?)
  >   456 (?)
  >   xyz
  >   $ printf 'zyx\nwvu\ntsr\n'
  >   abc (?)
  >   zyx (custom !)
  >   wvu
  >   no_print (no-custom !)
  >   tsr (no-missing !)
  >   missing (missing !)
  > EOF

  $ rt
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

failing test
==================

test churn with globs
  $ cat > test-failure.t <<EOF
  >   $ echo "bar-baz"; echo "bar-bad"; echo foo
  >   bar*bad (glob)
  >   bar*baz (glob)
  >   | fo (re)
  > EOF
  $ rt test-failure.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,4 +1,4 @@
     $ echo "bar-baz"; echo "bar-bad"; echo foo
  +  bar*baz (glob)
     bar*bad (glob)
  -  bar*baz (glob)
  -  | fo (re)
  +  foo
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

test how multiple globs gets matched with lines in output
  $ cat > test-failure-globs.t <<EOF
  >   $ echo "context"; echo "context"; \
  >     echo "key: 1"; echo "value: not a"; \
  >     echo "key: 2"; echo "value: not b"; \
  >     echo "key: 3"; echo "value: c"; \
  >     echo "key: 4"; echo "value: d"
  >   context
  >   context
  >   key: 1
  >   value: a
  >   key: 2
  >   value: b
  >   key: 3
  >   value: * (glob)
  >   key: 4
  >   value: * (glob)
  > EOF
  $ rt test-failure-globs.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure-globs.t
  +++ $TESTTMP/test-failure-globs.t.err
  @@ -2,9 +2,9 @@
     context
     context
     key: 1
  -  value: a
  +  value: not a
     key: 2
  -  value: b
  +  value: not b
     key: 3
     value: * (glob)
     key: 4
  
  ERROR: test-failure-globs.t output changed
  !
  Failed test-failure-globs.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ rm test-failure-globs.t

test diff colorisation

#if no-windows pygments
  $ rt test-failure.t --color always
  running 1 tests using 1 parallel processes 
  
  \x1b[38;5;124m--- $TESTTMP/test-failure.t\x1b[39m (esc)
  \x1b[38;5;28m+++ $TESTTMP/test-failure.t.err\x1b[39m (esc) (pygments211 !)
  \x1b[38;5;34m+++ $TESTTMP/test-failure.t.err\x1b[39m (esc) (no-pygments211 !)
  \x1b[38;5;90;01m@@ -1,4 +1,4 @@\x1b[39;00m (esc)
  \x1b[38;5;250m \x1b[39m  $ echo "bar-baz"; echo "bar-bad"; echo foo (esc) (pygments211 !)
     $ echo "bar-baz"; echo "bar-bad"; echo foo (no-pygments211 !)
  \x1b[38;5;28m+  bar*baz (glob)\x1b[39m (esc) (pygments211 !)
  \x1b[38;5;34m+  bar*baz (glob)\x1b[39m (esc) (no-pygments211 !)
  \x1b[38;5;250m \x1b[39m  bar*bad (glob) (esc) (pygments211 !)
     bar*bad (glob) (no-pygments211 !)
  \x1b[38;5;124m-  bar*baz (glob)\x1b[39m (esc)
  \x1b[38;5;124m-  | fo (re)\x1b[39m (esc)
  \x1b[38;5;28m+  foo\x1b[39m (esc) (pygments211 !)
  \x1b[38;5;34m+  foo\x1b[39m (esc) (no-pygments211 !)
  
  \x1b[38;5;88mERROR: \x1b[39m\x1b[38;5;9mtest-failure.t\x1b[39m\x1b[38;5;88m output changed\x1b[39m (esc)
  !
  \x1b[38;5;88mFailed \x1b[39m\x1b[38;5;9mtest-failure.t\x1b[39m\x1b[38;5;88m: output changed\x1b[39m (esc)
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rt test-failure.t 2> tmp.log
  running 1 tests using 1 parallel processes 
  [1]
  $ cat tmp.log
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,4 +1,4 @@
     $ echo "bar-baz"; echo "bar-bad"; echo foo
  +  bar*baz (glob)
     bar*bad (glob)
  -  bar*baz (glob)
  -  | fo (re)
  +  foo
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
#endif

  $ cat > test-failure.t << EOF
  >   $ true
  >   should go away (true !)
  >   $ true
  >   should stay (false !)
  > 
  > Should remove first line, not second or third
  >   $ echo 'testing'
  >   baz*foo (glob) (true !)
  >   foobar*foo (glob) (false !)
  >   te*ting (glob) (true !)
  > 
  > Should keep first two lines, remove third and last
  >   $ echo 'testing'
  >   test.ng (re) (true !)
  >   foo.ar (re) (false !)
  >   b.r (re) (true !)
  >   missing (?)
  >   awol (true !)
  > 
  > The "missing" line should stay, even though awol is dropped
  >   $ echo 'testing'
  >   test.ng (re) (true !)
  >   foo.ar (?)
  >   awol
  >   missing (?)
  > EOF
  $ rt test-failure.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,11 +1,9 @@
     $ true
  -  should go away (true !)
     $ true
     should stay (false !)
   
   Should remove first line, not second or third
     $ echo 'testing'
  -  baz*foo (glob) (true !)
     foobar*foo (glob) (false !)
     te*ting (glob) (true !)
   
     foo.ar (re) (false !)
     missing (?)
  @@ -13,13 +11,10 @@
     $ echo 'testing'
     test.ng (re) (true !)
     foo.ar (re) (false !)
  -  b.r (re) (true !)
     missing (?)
  -  awol (true !)
   
   The "missing" line should stay, even though awol is dropped
     $ echo 'testing'
     test.ng (re) (true !)
     foo.ar (?)
  -  awol
     missing (?)
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

basic failing test
  $ cat > test-failure.t << EOF
  >   $ echo babar
  >   rataxes
  > This is a noop statement so that
  > this test is still more bytes than success.
  > pad pad pad pad............................................................
  > pad pad pad pad............................................................
  > pad pad pad pad............................................................
  > pad pad pad pad............................................................
  > pad pad pad pad............................................................
  > pad pad pad pad............................................................
  > EOF

  >>> fh = open('test-failure-unicode.t', 'wb')
  >>> fh.write(u'  $ echo babar\u03b1\n'.encode('utf-8')) and None
  >>> fh.write(u'  l\u03b5\u03b5t\n'.encode('utf-8')) and None

  $ rt
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !.
  --- $TESTTMP/test-failure-unicode.t
  +++ $TESTTMP/test-failure-unicode.t.err
  @@ -1,2 +1,2 @@
     $ echo babar\xce\xb1 (esc)
  -  l\xce\xb5\xce\xb5t (esc)
  +  babar\xce\xb1 (esc)
  
  ERROR: test-failure-unicode.t output changed
  !
  Failed test-failure-unicode.t: output changed
  Failed test-failure.t: output changed
  # Ran 3 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]

test --outputdir
  $ mkdir output
  $ rt --outputdir output
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/output/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !.
  --- $TESTTMP/test-failure-unicode.t
  +++ $TESTTMP/output/test-failure-unicode.t.err
  @@ -1,2 +1,2 @@
     $ echo babar\xce\xb1 (esc)
  -  l\xce\xb5\xce\xb5t (esc)
  +  babar\xce\xb1 (esc)
  
  ERROR: test-failure-unicode.t output changed
  !
  Failed test-failure-unicode.t: output changed
  Failed test-failure.t: output changed
  # Ran 3 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]
  $ ls -a output
  .
  ..
  .testtimes
  test-failure-unicode.t.err
  test-failure.t.err

test --xunit support
  $ rt --xunit=xunit.xml
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !.
  --- $TESTTMP/test-failure-unicode.t
  +++ $TESTTMP/test-failure-unicode.t.err
  @@ -1,2 +1,2 @@
     $ echo babar\xce\xb1 (esc)
  -  l\xce\xb5\xce\xb5t (esc)
  +  babar\xce\xb1 (esc)
  
  ERROR: test-failure-unicode.t output changed
  !
  Failed test-failure-unicode.t: output changed
  Failed test-failure.t: output changed
  # Ran 3 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]
  $ cat xunit.xml
  <?xml version="1.0" encoding="utf-8"?>
  <testsuite errors="0" failures="2" name="run-tests" skipped="0" tests="3">
    <testcase name="test-success.t" time="*"/> (glob)
    <testcase name="test-failure-unicode.t" time="*"> (glob)
      <failure message="output changed" type="output-mismatch"><![CDATA[--- $TESTTMP/test-failure-unicode.t (py38 !)
      <failure message="output changed" type="output-mismatch"> (no-py38 !)
  <![CDATA[--- $TESTTMP/test-failure-unicode.t (no-py38 !)
  +++ $TESTTMP/test-failure-unicode.t.err
  @@ -1,2 +1,2 @@
     $ echo babar\xce\xb1 (esc)
  -  l\xce\xb5\xce\xb5t (esc)
  +  babar\xce\xb1 (esc)
  ]]></failure> (py38 !)
  ]]>    </failure> (no-py38 !)
    </testcase>
    <testcase name="test-failure.t" time="*"> (glob)
      <failure message="output changed" type="output-mismatch"><![CDATA[--- $TESTTMP/test-failure.t (py38 !)
      <failure message="output changed" type="output-mismatch"> (no-py38 !)
  <![CDATA[--- $TESTTMP/test-failure.t (no-py38 !)
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  ]]></failure> (py38 !)
  ]]>    </failure> (no-py38 !)
    </testcase>
  </testsuite>

  $ cat .testtimes
  test-empty.t * (glob)
  test-failure-globs.t * (glob)
  test-failure-unicode.t * (glob)
  test-failure.t * (glob)
  test-success.t * (glob)

  $ rt --list-tests
  test-failure-unicode.t
  test-failure.t
  test-success.t

  $ rt --list-tests --json
  test-failure-unicode.t
  test-failure.t
  test-success.t
  $ cat report.json
  testreport ={
      "test-failure-unicode.t": {
          "result": "success"
      },
      "test-failure.t": {
          "result": "success"
      },
      "test-success.t": {
          "result": "success"
      }
  } (no-eol)

  $ rt --list-tests --xunit=xunit.xml
  test-failure-unicode.t
  test-failure.t
  test-success.t
  $ cat xunit.xml
  <?xml version="1.0" encoding="utf-8"?>
  <testsuite errors="0" failures="0" name="run-tests" skipped="0" tests="0">
    <testcase name="test-failure-unicode.t"/>
    <testcase name="test-failure.t"/>
    <testcase name="test-success.t"/>
  </testsuite>

  $ rt --list-tests test-failure* --json --xunit=xunit.xml --outputdir output
  test-failure-unicode.t
  test-failure.t
  $ cat output/report.json
  testreport ={
      "test-failure-unicode.t": {
          "result": "success"
      },
      "test-failure.t": {
          "result": "success"
      }
  } (no-eol)
  $ cat xunit.xml
  <?xml version="1.0" encoding="utf-8"?>
  <testsuite errors="0" failures="0" name="run-tests" skipped="0" tests="0">
    <testcase name="test-failure-unicode.t"/>
    <testcase name="test-failure.t"/>
  </testsuite>

  $ rm test-failure-unicode.t

test for --retest
====================

  $ rt --retest
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

--retest works with --outputdir
  $ rm -r output
  $ mkdir output
  $ mv test-failure.t.err output
  $ rt --retest --outputdir output
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/output/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Selecting Tests To Run
======================

successful

  $ rt test-success.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

success w/ keyword
  $ rt -k xyzzy
  running 2 tests using 1 parallel processes 
  .
  # Ran 2 tests, 1 skipped, 0 failed.

failed

  $ rt test-failure.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

failure w/ keyword
  $ rt -k rataxes
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !
  Failed test-failure.t: output changed
  # Ran 2 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Verify that when a process fails to start we show a useful message
==================================================================

  $ cat > test-serve-fail.t <<EOF
  >   $ echo 'abort: child process failed to start blah'
  > EOF
  $ rt test-serve-fail.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-serve-fail.t
  +++ $TESTTMP/test-serve-fail.t.err
  @@ -1* +1,2 @@ (glob)
     $ echo 'abort: child process failed to start blah'
  +  abort: child process failed to start blah
  
  ERROR: test-serve-fail.t output changed
  !
  Failed test-serve-fail.t: server failed to start (HGPORT=*) (glob)
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ rm test-serve-fail.t

Verify that we can try other ports
===================================

Extensions aren't inherited by the invoked run-tests.py. An extension
introducing a repository requirement could cause this to fail. So we force
HGRCPATH to get a clean environment.

  $ HGRCPATH= hg init inuse
  $ hg serve -R inuse -p $HGPORT -d --pid-file=blocks.pid
  $ cat blocks.pid >> $DAEMON_PIDS
  $ cat > test-serve-inuse.t <<EOF
  >   $ hg serve -R `pwd`/inuse -p \$HGPORT -d --pid-file=hg.pid
  >   $ cat hg.pid >> \$DAEMON_PIDS
  > EOF
  $ rt test-serve-inuse.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.
  $ rm test-serve-inuse.t
  $ killdaemons.py $DAEMON_PIDS

Running In Debug Mode
======================

  $ rt --debug 2>&1 | grep -v pwd
  running 2 tests using 1 parallel processes 
  + echo *SALT* 0 0 (glob)
  *SALT* 0 0 (glob)
  + echo babar
  babar
  + echo *SALT* 10 0 (glob)
  *SALT* 10 0 (glob)
  *+ echo *SALT* 0 0 (glob)
  *SALT* 0 0 (glob)
  + echo babar
  babar
  + echo *SALT* 2 0 (glob)
  *SALT* 2 0 (glob)
  + echo xyzzy
  xyzzy
  + echo *SALT* 9 0 (glob)
  *SALT* 9 0 (glob)
  + printf *abc\ndef\nxyz\n* (glob)
  abc
  def
  xyz
  + echo *SALT* 15 0 (glob)
  *SALT* 15 0 (glob)
  + printf *zyx\nwvu\ntsr\n* (glob)
  zyx
  wvu
  tsr
  + echo *SALT* 22 0 (glob)
  *SALT* 22 0 (glob)
  .
  # Ran 2 tests, 0 skipped, 0 failed.

Parallel runs
==============

(duplicate the failing test to get predictable output)
  $ cp test-failure.t test-failure-copy.t

  $ rt --jobs 2 test-failure*.t -n
  running 2 tests using 2 parallel processes 
  !!
  Failed test-failure*.t: output changed (glob)
  Failed test-failure*.t: output changed (glob)
  # Ran 2 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]

failures in parallel with --first should only print one failure
  $ rt --jobs 2 --first test-failure*.t
  running 2 tests using 2 parallel processes 
  
  --- $TESTTMP/test-failure*.t (glob)
  +++ $TESTTMP/test-failure*.t.err (glob)
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  Failed test-failure*.t: output changed (glob)
  Failed test-failure*.t: output changed (glob)
  # Ran 2 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]


(delete the duplicated test file)
  $ rm test-failure-copy.t

multiple runs per test should be parallelized

  $ rt --jobs 2 --runs-per-test 2 test-success.t
  running 2 tests using 2 parallel processes 
  ..
  # Ran 2 tests, 0 skipped, 0 failed.

Interactive run
===============

(backup the failing test)
  $ cp test-failure.t backup

Refuse the fix

  $ echo 'n' | rt -i
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  Accept this change? [y/N] 
  ERROR: test-failure.t output changed
  !.
  Failed test-failure.t: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ cat test-failure.t
    $ echo babar
    rataxes
  This is a noop statement so that
  this test is still more bytes than success.
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................

Interactive with custom view

  $ echo 'n' | rt -i --view echo
  running 2 tests using 1 parallel processes 
  $TESTTMP/test-failure.t $TESTTMP/test-failure.t.err
  Accept this change? [y/N]* (glob)
  ERROR: test-failure.t output changed
  !.
  Failed test-failure.t: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

View the fix

  $ echo 'y' | rt --view echo
  running 2 tests using 1 parallel processes 
  $TESTTMP/test-failure.t $TESTTMP/test-failure.t.err
  
  ERROR: test-failure.t output changed
  !.
  Failed test-failure.t: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Accept the fix

  $ cat >> test-failure.t <<EOF
  >   $ echo 'saved backup bundle to \$TESTTMP/foo.hg'
  >   saved backup bundle to \$TESTTMP/foo.hg
  >   $ echo 'saved backup bundle to \$TESTTMP/foo.hg'
  >   saved backup bundle to $TESTTMP\\foo.hg
  >   $ echo 'saved backup bundle to \$TESTTMP/foo.hg'
  >   saved backup bundle to \$TESTTMP/*.hg (glob)
  > EOF
  $ echo 'y' | rt -i 2>&1
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  @@ -11,6 +11,6 @@
     $ echo 'saved backup bundle to $TESTTMP/foo.hg'
     saved backup bundle to $TESTTMP/foo.hg
     $ echo 'saved backup bundle to $TESTTMP/foo.hg'
  -  saved backup bundle to $TESTTMP\foo.hg
  +  saved backup bundle to $TESTTMP/foo.hg
     $ echo 'saved backup bundle to $TESTTMP/foo.hg'
     saved backup bundle to $TESTTMP/*.hg (glob)
  Accept this change? [y/N] ..
  # Ran 2 tests, 0 skipped, 0 failed.

  $ sed -e 's,(glob)$,&<,g' test-failure.t
    $ echo babar
    babar
  This is a noop statement so that
  this test is still more bytes than success.
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
  pad pad pad pad............................................................
    $ echo 'saved backup bundle to $TESTTMP/foo.hg'
    saved backup bundle to $TESTTMP/foo.hg
    $ echo 'saved backup bundle to $TESTTMP/foo.hg'
    saved backup bundle to $TESTTMP/foo.hg
    $ echo 'saved backup bundle to $TESTTMP/foo.hg'
    saved backup bundle to $TESTTMP/*.hg (glob)<

  $ rm test-failure.t

Race condition - test file was modified when test is running

  $ TESTRACEDIR=`pwd`
  $ export TESTRACEDIR
  $ cat > test-race.t <<EOF
  >   $ echo 1
  >   $ echo "# a new line" >> $TESTRACEDIR/test-race.t
  > EOF

  $ rt -i test-race.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-race.t
  +++ $TESTTMP/test-race.t.err
  @@ -1,2 +1,3 @@
     $ echo 1
  +  1
     $ echo "# a new line" >> $TESTTMP/test-race.t
  Reference output has changed (run again to prompt changes)
  ERROR: test-race.t output changed
  !
  Failed test-race.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rm test-race.t

When "#testcases" is used in .t files

  $ cat >> test-cases.t <<EOF
  > #testcases a b
  > #if a
  >   $ echo 1
  > #endif
  > #if b
  >   $ echo 2
  > #endif
  > EOF

  $ cat <<EOF | rt -i test-cases.t 2>&1
  > y
  > y
  > EOF
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/test-cases.t
  +++ $TESTTMP/test-cases.t#a.err
  @@ -1,6 +1,7 @@
   #testcases a b
   #if a
     $ echo 1
  +  1
   #endif
   #if b
     $ echo 2
  Accept this change? [y/N] .
  --- $TESTTMP/test-cases.t
  +++ $TESTTMP/test-cases.t#b.err
  @@ -5,4 +5,5 @@
   #endif
   #if b
     $ echo 2
  +  2
   #endif
  Accept this change? [y/N] .
  # Ran 2 tests, 0 skipped, 0 failed.

  $ cat test-cases.t
  #testcases a b
  #if a
    $ echo 1
    1
  #endif
  #if b
    $ echo 2
    2
  #endif

  $ cat >> test-cases.t <<'EOF'
  > #if a
  >   $ NAME=A
  > #else
  >   $ NAME=B
  > #endif
  >   $ echo $NAME
  >   A (a !)
  >   B (b !)
  > EOF
  $ rt test-cases.t
  running 2 tests using 1 parallel processes 
  ..
  # Ran 2 tests, 0 skipped, 0 failed.

When using multiple dimensions of "#testcases" in .t files

  $ cat > test-cases.t <<'EOF'
  > #testcases a b
  > #testcases c d
  > #if a d
  >   $ echo $TESTCASE
  >   a#d
  > #endif
  > #if b c
  >   $ echo yes
  >   no
  > #endif
  > EOF
  $ rt test-cases.t
  running 4 tests using 1 parallel processes 
  ..
  --- $TESTTMP/test-cases.t
  +++ $TESTTMP/test-cases.t#b#c.err
  @@ -6,5 +6,5 @@
   #endif
   #if b c
     $ echo yes
  -  no
  +  yes
   #endif
  
  ERROR: test-cases.t#b#c output changed
  !.
  Failed test-cases.t#b#c: output changed
  # Ran 4 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rt --retest
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/test-cases.t
  +++ $TESTTMP/test-cases.t#b#c.err
  @@ -6,5 +6,5 @@
   #endif
   #if b c
     $ echo yes
  -  no
  +  yes
   #endif
  
  ERROR: test-cases.t#b#c output changed
  !
  Failed test-cases.t#b#c: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ rm test-cases.t#b#c.err
  $ rm test-cases.t

(reinstall)
  $ mv backup test-failure.t

No Diff
===============

  $ rt --nodiff
  running 2 tests using 1 parallel processes 
  !.
  Failed test-failure.t: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

test --tmpdir support
  $ rt --tmpdir=$TESTTMP/keep test-success.t
  running 1 tests using 1 parallel processes 
  
  Keeping testtmp dir: $TESTTMP/keep/child1/test-success.t
  Keeping threadtmp dir: $TESTTMP/keep/child1 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

timeouts
========
  $ cat > test-timeout.t <<EOF
  >   $ sleep 2
  >   $ echo pass
  >   pass
  > EOF
  > echo '#require slow' > test-slow-timeout.t
  > cat test-timeout.t >> test-slow-timeout.t
  $ rt --timeout=1 --slowtimeout=3 test-timeout.t test-slow-timeout.t
  running 2 tests using 1 parallel processes 
  st
  Skipped test-slow-timeout.t: missing feature: allow slow tests (use --allow-slow-tests)
  Failed test-timeout.t: timed out
  # Ran 1 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ rt --timeout=1 --slowtimeout=3 \
  > test-timeout.t test-slow-timeout.t --allow-slow-tests
  running 2 tests using 1 parallel processes 
  .t
  Failed test-timeout.t: timed out
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ rm test-timeout.t test-slow-timeout.t

test for --time
==================

  $ rt test-success.t --time
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.
  # Producing time report
  start   end     cuser   csys    real      Test
  \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8}   test-success.t (re)

test for --time with --job enabled
====================================

  $ rt test-success.t --time --jobs 2
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.
  # Producing time report
  start   end     cuser   csys    real      Test
  \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8} \s*[\d\.]{5,8}   test-success.t (re)

Skips
================
  $ cat > test-skip.t <<EOF
  >   $ echo xyzzy
  > #if true
  > #require false
  > #end
  > EOF
  $ cat > test-noskip.t <<EOF
  > #if false
  > #require false
  > #endif
  > EOF
  $ rt --nodiff
  running 4 tests using 1 parallel processes 
  !.s.
  Skipped test-skip.t: missing feature: nail clipper
  Failed test-failure.t: output changed
  # Ran 3 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rm test-noskip.t
  $ rt --keyword xyzzy
  running 3 tests using 1 parallel processes 
  .s
  Skipped test-skip.t: missing feature: nail clipper
  # Ran 2 tests, 2 skipped, 0 failed.

Skips with xml
  $ rt --keyword xyzzy \
  >  --xunit=xunit.xml
  running 3 tests using 1 parallel processes 
  .s
  Skipped test-skip.t: missing feature: nail clipper
  # Ran 2 tests, 2 skipped, 0 failed.
  $ cat xunit.xml
  <?xml version="1.0" encoding="utf-8"?>
  <testsuite errors="0" failures="0" name="run-tests" skipped="2" tests="2">
    <testcase name="test-success.t" time="*"/> (glob)
    <testcase name="test-skip.t">
      <skipped><![CDATA[missing feature: nail clipper]]></skipped> (py38 !)
      <skipped> (no-py38 !)
  <![CDATA[missing feature: nail clipper]]>    </skipped> (no-py38 !)
    </testcase>
  </testsuite>

Missing skips or blacklisted skips don't count as executed:
  $ mkdir tests
  $ echo tests/test-failure.t > blacklist
  $ cp test-failure.t tests
  $ rt --blacklist=blacklist --json\
  >   tests/test-failure.t tests/test-bogus.t
  running 2 tests using 1 parallel processes 
  ss
  Skipped test-bogus.t: Doesn't exist
  Skipped test-failure.t: blacklisted
  # Ran 0 tests, 2 skipped, 0 failed.
  $ cat tests/report.json
  testreport ={
      "test-bogus.t": {
          "result": "skip"
      },
      "test-failure.t": {
          "result": "skip"
      }
  } (no-eol)
  $ rm -r tests
  $ echo test-failure.t > blacklist

Whitelist trumps blacklist
  $ echo test-failure.t > whitelist
  $ rt --blacklist=blacklist --whitelist=whitelist --json\
  >   test-failure.t test-bogus.t
  running 2 tests using 1 parallel processes 
  s
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !
  Skipped test-bogus.t: Doesn't exist
  Failed test-failure.t: output changed
  # Ran 1 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Ensure that --test-list causes only the tests listed in that file to
be executed.
  $ echo test-success.t >> onlytest
  $ rt --test-list=onlytest
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.
  $ echo test-bogus.t >> anothertest
  $ rt --test-list=onlytest --test-list=anothertest
  running 2 tests using 1 parallel processes 
  s.
  Skipped test-bogus.t: Doesn't exist
  # Ran 1 tests, 1 skipped, 0 failed.
  $ rm onlytest anothertest

test for --json
==================

  $ rt --json
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !.s
  Skipped test-skip.t: missing feature: nail clipper
  Failed test-failure.t: output changed
  # Ran 2 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ cat report.json
  testreport ={
      "test-failure.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "---.+\+\+\+.+", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "failure", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-skip.t": {
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "skip", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-success.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "success", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }
  } (no-eol)
--json with --outputdir

  $ rm report.json
  $ rm -r output
  $ mkdir output
  $ rt --json --outputdir output
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/output/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  
  ERROR: test-failure.t output changed
  !.s
  Skipped test-skip.t: missing feature: nail clipper
  Failed test-failure.t: output changed
  # Ran 2 tests, 1 skipped, 1 failed.
  python hash seed: * (glob)
  [1]
  $ f report.json
  report.json: file not found
  $ cat output/report.json
  testreport ={
      "test-failure.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "---.+\+\+\+.+", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "failure", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-skip.t": {
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "skip", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-success.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "success", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }
  } (no-eol)
  $ ls -a output
  .
  ..
  .testtimes
  report.json
  test-failure.t.err

Test that failed test accepted through interactive are properly reported:

  $ cp test-failure.t backup
  $ echo y | rt --json -i
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/test-failure.t
  +++ $TESTTMP/test-failure.t.err
  @@ -1,5 +1,5 @@
     $ echo babar
  -  rataxes
  +  babar
   This is a noop statement so that
   this test is still more bytes than success.
   pad pad pad pad............................................................
  Accept this change? [y/N] ..s
  Skipped test-skip.t: missing feature: nail clipper
  # Ran 2 tests, 1 skipped, 0 failed.

  $ cat report.json
  testreport ={
      "test-failure.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "success", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-skip.t": {
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "skip", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }, ? (re)
      "test-success.t": [\{] (re)
          "csys": "\s*\d+\.\d{3,4}", ? (re)
          "cuser": "\s*\d+\.\d{3,4}", ? (re)
          "diff": "", ? (re)
          "end": "\s*\d+\.\d{3,4}", ? (re)
          "result": "success", ? (re)
          "start": "\s*\d+\.\d{3,4}", ? (re)
          "time": "\s*\d+\.\d{3,4}" (re)
      }
  } (no-eol)
  $ mv backup test-failure.t

backslash on end of line with glob matching is handled properly

  $ cat > test-glob-backslash.t << EOF
  >   $ echo 'foo bar \\'
  >   foo * \ (glob)
  > EOF

  $ rt test-glob-backslash.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

  $ rm -f test-glob-backslash.t

Test globbing of local IP addresses
  $ echo 172.16.18.1
  $LOCALIP (glob)
  $ echo dead:beef::1
  $LOCALIP (glob)

Add support for external test formatter
=======================================

  $ CUSTOM_TEST_RESULT=basic_test_result "$PYTHON" $TESTDIR/run-tests.py --with-hg=$HGTEST_REAL_HG -j1 "$@" test-success.t test-failure.t
  running 2 tests using 1 parallel processes 
  
  # Ran 2 tests, 0 skipped, 0 failed.
  ON_START! <__main__.TestSuite tests=[<__main__.TTest testMethod=test-failure.t>, <__main__.TTest testMethod=test-success.t>]>
  FAILURE! test-failure.t output changed
  SUCCESS! test-success.t
  ON_END!

Test reusability for third party tools
======================================

  $ THISTESTDIR="$TESTDIR"
  $ export THISTESTDIR
  $ THISTESTTMP="$TESTTMP"
  $ export THISTESTTMP

#if windows

  $ NEWTESTDIR="$THISTESTTMP"\\anothertests

#else

  $ NEWTESTDIR="$THISTESTTMP"/anothertests

#endif

  $ export NEWTESTDIR

  $ echo creating some new test in: $NEWTESTDIR
  creating some new test in: $TESTTMP\anothertests (windows !)
  creating some new test in: $TESTTMP/anothertests (no-windows !)
  $ mkdir "$NEWTESTDIR"
  $ cd "$NEWTESTDIR"

test that `run-tests.py` can execute hghave, even if it runs not in
Mercurial source tree.

  $ cat > test-hghave.t <<EOF
  > #require true
  >   $ echo foo
  >   foo
  > EOF
  $ rt test-hghave.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

test that RUNTESTDIR refers the directory, in which `run-tests.py` now
running is placed.


  $ cat > test-runtestdir.t <<EOF
  > # \$THISTESTDIR, in which test-run-tests.t (this test file) is placed
  > # \$THISTESTTMP, in which test-run-tests.t (this test file) is placed
  > # \$TESTDIR, in which test-runtestdir.t is placed (expanded at runtime)
  > # \$RUNTESTDIR, in which run-tests.py is placed (expanded at runtime)
  > 
  >   $ test "\$TESTDIR" = "\$NEWTESTDIR"
  > If this prints a path, that means RUNTESTDIR didn't equal
  > THISTESTDIR as it should have.
  >   $ test "\$RUNTESTDIR" = "\$THISTESTDIR" || echo "\$RUNTESTDIR"
  > This should print the start of check-code. If this passes but the
  > previous check failed, that means we found a copy of check-code at whatever
  > RUNTESTSDIR ended up containing, even though it doesn't match THISTESTDIR.
  >   $ head -n 3 "\$RUNTESTDIR"/../contrib/check-code.py | sed 's@.!.*python3@#!USRBINENVPY@'
  >   #!USRBINENVPY
  >   #
  >   # check-code - a style and portability checker for Mercurial
  > EOF
  $ rt test-runtestdir.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

#if execbit

test that TESTDIR is referred in PATH

  $ cat > custom-command.sh <<EOF
  > #!/bin/sh
  > echo "hello world"
  > EOF
  $ chmod +x custom-command.sh
  $ cat > test-testdir-path.t <<EOF
  >   $ custom-command.sh
  >   hello world
  > EOF
  $ rt test-testdir-path.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

#endif

test support for --allow-slow-tests
  $ cat > test-very-slow-test.t <<EOF
  > #require slow
  >   $ echo pass
  >   pass
  > EOF
  $ rt test-very-slow-test.t
  running 1 tests using 1 parallel processes 
  s
  Skipped test-very-slow-test.t: missing feature: allow slow tests (use --allow-slow-tests)
  # Ran 0 tests, 1 skipped, 0 failed.
  $ rt $HGTEST_RUN_TESTS_PURE --allow-slow-tests test-very-slow-test.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

support for running a test outside the current directory
  $ mkdir nonlocal
  $ cat > nonlocal/test-is-not-here.t << EOF
  >   $ echo pass
  >   pass
  > EOF
  $ rt nonlocal/test-is-not-here.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

support for automatically discovering test if arg is a folder
  $ mkdir tmp && cd tmp

  $ cat > test-uno.t << EOF
  >   $ echo line
  >   line
  > EOF

  $ cp test-uno.t test-dos.t
  $ cd ..
  $ cp -R tmp tmpp
  $ cp tmp/test-uno.t test-solo.t

  $ rt tmp/ test-solo.t tmpp
  running 5 tests using 1 parallel processes 
  .....
  # Ran 5 tests, 0 skipped, 0 failed.
  $ rm -rf tmp tmpp

support for running run-tests.py from another directory
  $ mkdir tmp && cd tmp

  $ cat > useful-file.sh << EOF
  > important command
  > EOF

  $ cat > test-folder.t << EOF
  >   $ cat \$TESTDIR/useful-file.sh
  >   important command
  > EOF

  $ cat > test-folder-fail.t << EOF
  >   $ cat \$TESTDIR/useful-file.sh
  >   important commando
  > EOF

  $ cd ..
  $ rt tmp/test-*.t
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/tmp/test-folder-fail.t
  +++ $TESTTMP/anothertests/tmp/test-folder-fail.t.err
  @@ -1,2 +1,2 @@
     $ cat $TESTDIR/useful-file.sh
  -  important commando
  +  important command
  
  ERROR: test-folder-fail.t output changed
  !.
  Failed test-folder-fail.t: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

support for bisecting failed tests automatically
  $ hg init bisect
  $ cd bisect
  $ cat >> test-bisect.t <<EOF
  >   $ echo pass
  >   pass
  > EOF
  $ hg add test-bisect.t
  $ hg ci -m 'good'
  $ cat >> test-bisect.t <<EOF
  >   $ echo pass
  >   fail
  > EOF
  $ hg ci -m 'bad'
  $ rt --known-good-rev=0 test-bisect.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/bisect/test-bisect.t
  +++ $TESTTMP/anothertests/bisect/test-bisect.t.err
  @@ -1,4 +1,4 @@
     $ echo pass
     pass
     $ echo pass
  -  fail
  +  pass
  
  ERROR: test-bisect.t output changed
  !
  Failed test-bisect.t: output changed
  test-bisect.t broken by 72cbf122d116 (bad)
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ cd ..

support bisecting a separate repo

  $ hg init bisect-dependent
  $ cd bisect-dependent
  $ cat > test-bisect-dependent.t <<EOF
  >   $ tail -1 \$TESTDIR/../bisect/test-bisect.t
  >     pass
  > EOF
  $ hg commit -Am dependent test-bisect-dependent.t

  $ rt --known-good-rev=0 test-bisect-dependent.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/bisect-dependent/test-bisect-dependent.t
  +++ $TESTTMP/anothertests/bisect-dependent/test-bisect-dependent.t.err
  @@ -1,2 +1,2 @@
     $ tail -1 $TESTDIR/../bisect/test-bisect.t
  -    pass
  +    fail
  
  ERROR: test-bisect-dependent.t output changed
  !
  Failed test-bisect-dependent.t: output changed
  Failed to identify failure point for test-bisect-dependent.t
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rt --bisect-repo=../test-bisect test-bisect-dependent.t
  usage: run-tests.py [options] [tests]
  run-tests.py: error: --bisect-repo cannot be used without --known-good-rev
  [2]

  $ rt --known-good-rev=0 --bisect-repo=../bisect test-bisect-dependent.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/bisect-dependent/test-bisect-dependent.t
  +++ $TESTTMP/anothertests/bisect-dependent/test-bisect-dependent.t.err
  @@ -1,2 +1,2 @@
     $ tail -1 $TESTDIR/../bisect/test-bisect.t
  -    pass
  +    fail
  
  ERROR: test-bisect-dependent.t output changed
  !
  Failed test-bisect-dependent.t: output changed
  test-bisect-dependent.t broken by 72cbf122d116 (bad)
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ cd ..

Test a broken #if statement doesn't break run-tests threading.
==============================================================
  $ mkdir broken
  $ cd broken
  $ cat > test-broken.t <<EOF
  > true
  > #if notarealhghavefeature
  >   $ false
  > #endif
  > EOF
  $ for f in 1 2 3 4 ; do
  > cat > test-works-$f.t <<EOF
  > This is test case $f
  >   $ sleep 1
  > EOF
  > done
  $ rt -j 2
  running 5 tests using 2 parallel processes 
  ....
  # Ran 5 tests, 0 skipped, 0 failed.
  skipped: unknown feature: notarealhghavefeature
  
  $ cd ..
  $ rm -rf broken

Test cases in .t files
======================
  $ mkdir cases
  $ cd cases
  $ cat > test-cases-abc.t <<'EOF'
  > #testcases A B C
  >   $ V=B
  > #if A
  >   $ V=A
  > #endif
  > #if C
  >   $ V=C
  > #endif
  >   $ echo $V | sed 's/A/C/'
  >   C
  > #if C
  >   $ [ $V = C ]
  > #endif
  > #if A
  >   $ [ $V = C ]
  >   [1]
  > #endif
  > #if no-C
  >   $ [ $V = C ]
  >   [1]
  > #endif
  >   $ [ $V = D ]
  >   [1]
  > EOF
  $ rt
  running 3 tests using 1 parallel processes 
  .
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !.
  Failed test-cases-abc.t#B: output changed
  # Ran 3 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

--restart works

  $ rt --restart
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !.
  Failed test-cases-abc.t#B: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

--restart works with outputdir

  $ mkdir output
  $ mv test-cases-abc.t#B.err output
  $ rt --restart --outputdir output
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/output/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !.
  Failed test-cases-abc.t#B: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Test TESTCASE variable

  $ cat > test-cases-ab.t <<'EOF'
  >   $ dostuff() {
  >   >   echo "In case $TESTCASE"
  >   > }
  > #testcases A B
  > #if A
  >   $ dostuff
  >   In case A
  > #endif
  > #if B
  >   $ dostuff
  >   In case B
  > #endif
  > EOF
  $ rt test-cases-ab.t
  running 2 tests using 1 parallel processes 
  ..
  # Ran 2 tests, 0 skipped, 0 failed.

Support running a specific test case

  $ rt "test-cases-abc.t#B"
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !
  Failed test-cases-abc.t#B: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Support running multiple test cases in the same file

  $ rt test-cases-abc.t#B test-cases-abc.t#C
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !.
  Failed test-cases-abc.t#B: output changed
  # Ran 2 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Support ignoring invalid test cases

  $ rt test-cases-abc.t#B test-cases-abc.t#D
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-abc.t
  +++ $TESTTMP/anothertests/cases/test-cases-abc.t#B.err
  @@ -7,7 +7,7 @@
     $ V=C
   #endif
     $ echo $V | sed 's/A/C/'
  -  C
  +  B
   #if C
     $ [ $V = C ]
   #endif
  
  ERROR: test-cases-abc.t#B output changed
  !
  Failed test-cases-abc.t#B: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Support running complex test cases names

  $ cat > test-cases-advanced-cases.t <<'EOF'
  > #testcases simple case-with-dashes casewith_-.chars
  >   $ echo $TESTCASE
  >   simple
  > EOF

  $ cat test-cases-advanced-cases.t
  #testcases simple case-with-dashes casewith_-.chars
    $ echo $TESTCASE
    simple

  $ rt test-cases-advanced-cases.t
  running 3 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-advanced-cases.t
  +++ $TESTTMP/anothertests/cases/test-cases-advanced-cases.t#case-with-dashes.err
  @@ -1,3 +1,3 @@
   #testcases simple case-with-dashes casewith_-.chars
     $ echo $TESTCASE
  -  simple
  +  case-with-dashes
  
  ERROR: test-cases-advanced-cases.t#case-with-dashes output changed
  !
  --- $TESTTMP/anothertests/cases/test-cases-advanced-cases.t
  +++ $TESTTMP/anothertests/cases/test-cases-advanced-cases.t#casewith_-.chars.err
  @@ -1,3 +1,3 @@
   #testcases simple case-with-dashes casewith_-.chars
     $ echo $TESTCASE
  -  simple
  +  casewith_-.chars
  
  ERROR: test-cases-advanced-cases.t#casewith_-.chars output changed
  !.
  Failed test-cases-advanced-cases.t#case-with-dashes: output changed
  Failed test-cases-advanced-cases.t#casewith_-.chars: output changed
  # Ran 3 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]

  $ rt "test-cases-advanced-cases.t#case-with-dashes"
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-advanced-cases.t
  +++ $TESTTMP/anothertests/cases/test-cases-advanced-cases.t#case-with-dashes.err
  @@ -1,3 +1,3 @@
   #testcases simple case-with-dashes casewith_-.chars
     $ echo $TESTCASE
  -  simple
  +  case-with-dashes
  
  ERROR: test-cases-advanced-cases.t#case-with-dashes output changed
  !
  Failed test-cases-advanced-cases.t#case-with-dashes: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

  $ rt "test-cases-advanced-cases.t#casewith_-.chars"
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-cases-advanced-cases.t
  +++ $TESTTMP/anothertests/cases/test-cases-advanced-cases.t#casewith_-.chars.err
  @@ -1,3 +1,3 @@
   #testcases simple case-with-dashes casewith_-.chars
     $ echo $TESTCASE
  -  simple
  +  casewith_-.chars
  
  ERROR: test-cases-advanced-cases.t#casewith_-.chars output changed
  !
  Failed test-cases-advanced-cases.t#casewith_-.chars: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

Test automatic pattern replacement
==================================

  $ cat << EOF >> common-pattern.py
  > substitutions = [
  >     (br'foo-(.*)\\b',
  >      br'\$XXX=\\1\$'),
  >     (br'bar\\n',
  >      br'\$YYY$\\n'),
  > ]
  > EOF

  $ cat << EOF >> test-substitution.t
  >   $ echo foo-12
  >   \$XXX=12$
  >   $ echo foo-42
  >   \$XXX=42$
  >   $ echo bar prior
  >   bar prior
  >   $ echo lastbar
  >   last\$YYY$
  >   $ echo foo-bar foo-baz
  > EOF

  $ rt test-substitution.t
  running 1 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-substitution.t
  +++ $TESTTMP/anothertests/cases/test-substitution.t.err
  @@ -7,3 +7,4 @@
     $ echo lastbar
     last$YYY$
     $ echo foo-bar foo-baz
  +  $XXX=bar foo-baz$
  
  ERROR: test-substitution.t output changed
  !
  Failed test-substitution.t: output changed
  # Ran 1 tests, 0 skipped, 1 failed.
  python hash seed: * (glob)
  [1]

--extra-config-opt works

  $ cat << EOF >> test-config-opt.t
  >   $ hg init test-config-opt
  >   $ hg -R test-config-opt purge
  >   $ echo "HGTESTEXTRAEXTENSIONS: \$HGTESTEXTRAEXTENSIONS"
  >   HGTESTEXTRAEXTENSIONS: purge
  > EOF

  $ rt --extra-config-opt extensions.purge= \
  >    --extra-config-opt not.an.extension=True test-config-opt.t
  running 1 tests using 1 parallel processes 
  .
  # Ran 1 tests, 0 skipped, 0 failed.

Test conditional output matching
================================

  $ cat << EOF >> test-conditional-matching.t
  > #testcases foo bar
  >   $ echo richtig
  >   richtig (true !)
  >   $ echo falsch
  >   falsch (false !)
  > #if foo
  >   $ echo arthur
  >   arthur (bar !)
  > #endif
  >   $ echo celeste
  >   celeste (foo !)
  >   $ echo zephir
  >   zephir (bar !)
  > EOF

  $ rt test-conditional-matching.t
  running 2 tests using 1 parallel processes 
  
  --- $TESTTMP/anothertests/cases/test-conditional-matching.t
  +++ $TESTTMP/anothertests/cases/test-conditional-matching.t#bar.err
  @@ -3,11 +3,13 @@
     richtig (true !)
     $ echo falsch
     falsch (false !)
  +  falsch
   #if foo
     $ echo arthur
     arthur \(bar !\) (re)
   #endif
     $ echo celeste
     celeste \(foo !\) (re)
  +  celeste
     $ echo zephir
     zephir \(bar !\) (re)
  
  ERROR: test-conditional-matching.t#bar output changed
  !
  --- $TESTTMP/anothertests/cases/test-conditional-matching.t
  +++ $TESTTMP/anothertests/cases/test-conditional-matching.t#foo.err
  @@ -3,11 +3,14 @@
     richtig (true !)
     $ echo falsch
     falsch (false !)
  +  falsch
   #if foo
     $ echo arthur
     arthur \(bar !\) (re)
  +  arthur
   #endif
     $ echo celeste
     celeste \(foo !\) (re)
     $ echo zephir
     zephir \(bar !\) (re)
  +  zephir
  
  ERROR: test-conditional-matching.t#foo output changed
  !
  Failed test-conditional-matching.t#bar: output changed
  Failed test-conditional-matching.t#foo: output changed
  # Ran 2 tests, 0 skipped, 2 failed.
  python hash seed: * (glob)
  [1]

Test that a proper "python" has been set up
===========================================

(with a small check-code work around)
  $ printf "#!/usr/bi" > test-py3.tmp
  $ printf "n/en" >> test-py3.tmp
  $ cat << EOF >> test-py3.tmp
  > v python3
  > import sys
  > print('.'.join(str(x) for x in sys.version_info))
  > EOF
  $ mv test-py3.tmp test-py3.py
  $ chmod +x test-py3.py

(with a small check-code work around)
  $ printf "#!/usr/bi" > test-py.tmp
  $ printf "n/en" >> test-py.tmp
  $ cat << EOF >> test-py.tmp
  > v python
  > import sys
  > print('.'.join(str(x) for x in sys.version_info))
  > EOF
  $ mv test-py.tmp test-py.py
  $ chmod +x test-py.py

  $ ./test-py3.py
  3.* (glob)
  $ ./test-py.py
  2.* (glob) (no-py3 !)
  3.* (glob) (py3 !)
