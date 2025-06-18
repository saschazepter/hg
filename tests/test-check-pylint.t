#require test-repo pylint

Run pylint for known rules we care about.
-----------------------------------------

There should be no recorded failures; fix the codebase before introducing a
new check.

Current checks:
- W0102: no mutable default argument
- C0321: only one statement on a single line

  $ touch $TESTTMP/fakerc

#if windows
  $ PYTHONPATH="`dirname $TESTDIR`;$PYTHONPATH"
#else
  $ PYTHONPATH="`dirname $TESTDIR`:$PYTHONPATH"
#endif

  $ export PYTHONPATH
  $ pylint --rcfile=$TESTTMP/fakerc --disable=all \
  >   --enable=W0102,C0321 \
  >   --reports=no \
  >   --ignore=thirdparty \
  >   --score=no \
  >   mercurial hgdemandimport hgext | sed 's/\r$//'
