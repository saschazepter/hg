  $ rm -rf a
  $ hg init a
  $ cd a
  $ echo a > a
  $ hg ci -Am0
  adding a
  $ hg tag t1 # 1
  $ hg tag --remove t1 # 2

  $ hg co 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg tag -f -r0 t1
  $ hg tags
  tip                                3:a49829c4fc11
  t1                                 0:f7b1eb17ad24

Ensure that the username access fails gracefully if assumptions about the
environment made by python do not hold.

#if windows
  >>> import os
  >>> from mercurial import util
  >>> os.environ.pop('LOGNAME', None) and None
  >>> os.environ.pop('USER', None) and None
  >>> os.environ.pop('LNAME', None) and None
  >>> os.environ.pop('USERNAME', None) and None
  >>> print(util.username())
  None
#endif

  $ cd ..
