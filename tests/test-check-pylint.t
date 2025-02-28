#require test-repo pylint

Run pylint for known rules we care about.
-----------------------------------------

There should be no recorded failures; fix the codebase before introducing a
new check.

Current checks:
- W0102: no mutable default argument
- C0321: only one statement on a single line

  $ touch $TESTTMP/fakerc
  $ pylint --rcfile=$TESTTMP/fakerc --disable=all \
  >   --enable=W0102,C0321 \
  >   --reports=no \
  >   --ignore=thirdparty \
  >   mercurial hgdemandimport hgext | sed 's/\r$//'
  Using config file *fakerc (glob) (?)
   (?)
  ------------------------------------* (glob) (?)
  Your code has been rated at 10.00/10* (glob) (?)
   (?)
