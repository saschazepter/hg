============================================
Tests for the admin::chainsaw-update command
============================================

setup
=====

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > chainsaw=
  > EOF

  $ hg init src
  $ cd src
  $ echo 1 > root
  $ hg add root
  $ hg ci -Am R_0
  $ hg branch A
  marked working directory as branch A
  (branches are permanent and global, did you want a bookmark?)
  $ echo 42 > bar
  $ hg add bar
  $ hg ci -Am A_0
  $ echo 1337 > bar
  $ hg ci -Am A_1
  $ hg update 'desc(R_0)'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo 1 > foo
  $ hg add foo
  $ hg ci -Am B_0
  $ hg log -G
  @  changeset:   3:bfcb8e629987
  |  tag:         tip
  |  parent:      0:06f48e4098b8
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     B_0
  |
  | o  changeset:   2:7fd8de258aa4
  | |  branch:      A
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     A_1
  | |
  | o  changeset:   1:ae1692b8aadb
  |/   branch:      A
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     A_0
  |
  o  changeset:   0:06f48e4098b8
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     R_0
  
  $ cd ..

Actual tests
============

Simple invocation
-----------------

  $ hg init repo
  $ cd repo
  $ hg admin::chainsaw-update --rev default --source ../src
  recovering after interrupted transaction, if any
  no interrupted transaction available
  pulling from ../src
  updating to revision 'default'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  chainsaw-update to revision 'default' for repository at '$TESTTMP/repo' done

  $ hg log -G
  @  changeset:   1:bfcb8e629987
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     B_0
  |
  o  changeset:   0:06f48e4098b8
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     R_0
  
  $ hg status -A
  C foo
  C root
  $ cat foo
  1

Test lock breacking capabilities
--------------------------------

Demonstrate lock-breaking capabilities with locks that regular Mercurial
operation would not break, because the hostnames registered in locks differ
from the current hostname (happens a lot with succesive containers):

  $ ln -s invalid.host.test/effffffc:171814 .hg/store/lock
  $ ln -s invalid.host.test/effffffc:171814 .hg/wlock
  $ hg debuglock
  lock:  (.*?), process 171814, host invalid.host.test/effffffc \((\d+)s\) (re)
  wlock: (.*?), process 171814, host invalid.host.test/effffffc \((\d+)s\) (re)
  [2]

  $ hg admin::chainsaw-update --no-purge-ignored --rev default --source ../src
  had to break store lock
  had to break working copy lock
  recovering after interrupted transaction, if any
  no interrupted transaction available
  pulling from ../src
  updating to revision 'default'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  chainsaw-update to revision 'default' for repository at '$TESTTMP/repo' done

Test file purging capabilities
------------------------------

Let's also add local modifications (tracked and untracked) to demonstrate the
purging.

  $ echo untracked > bar
  $ echo modified > foo
  $ hg status -A
  M foo
  ? bar
  C root

  $ echo 2 > ../src/foo
  $ hg -R ../src commit -m2
  $ hg admin::chainsaw-update --rev default --source ../src -q
  no interrupted transaction available
  $ hg status -A
  C foo
  C root
  $ cat foo
  2

Now behaviour with respect to ignored files: they are not purged if
the --no-purge-ignored flag is passed, but they are purged by default

  $ echo bar > .hgignore
  $ hg ci -Aqm hgignore
  $ echo ignored > bar
  $ hg status --all
  I bar
  C .hgignore
  C foo
  C root

  $ hg admin::chainsaw-update --no-purge-ignored --rev default --source ../src -q
  no interrupted transaction available
  $ hg status --all
  I bar
  C .hgignore
  C foo
  C root
  $ cat bar
  ignored

  $ hg admin::chainsaw-update --rev default --source ../src -q
  no interrupted transaction available
  $ hg status --all
  C .hgignore
  C foo
  C root
  $ test -f bar
  [1]

