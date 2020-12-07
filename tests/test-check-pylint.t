#require test-repo pylint hg10

Run pylint for known rules we care about.
-----------------------------------------

There should be no recorded failures; fix the codebase before introducing a
new check.

Current checks:
- W0102: no mutable default argument

  $ touch $TESTTMP/fakerc
  $ pylint --rcfile=$TESTTMP/fakerc --disable=all \
  >   --enable=W0102,C0321 \
  >   --reports=no \
  >   --ignore=thirdparty \
  >   mercurial hgdemandimport hgext hgext3rd | sed 's/\r$//'
  Using config file *fakerc (glob) (?)
   (?)
  ------------------------------------* (glob) (?)
  Your code has been rated at 10.00/10* (glob) (?)
   (?)
