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
  $ echo 1 > foo
  $ hg ci -Am1
  adding foo
  $ cd ..

Actual tests
============

Simple invocation
-----------------

  $ hg init repo
  $ cd repo
  $ hg admin::chainsaw-update --rev default --source ../src
  breaking locks, if any
  recovering after interrupted transaction, if any
  no interrupted transaction available
  pulling from ../src
  updating to revision 'default'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  chainsaw-update to revision 'default' for repository at '$TESTTMP/repo' done

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

  $ hg admin::chainsaw-update --no-purge-ignored --rev default --source ../src -q
  no interrupted transaction available

Test file purging capabilities
------------------------------

Let's also add local modifications (tracked and untracked) to demonstrate the
purging.

  $ echo untracked > bar
  $ echo modified > foo
  $ hg status -A
  M foo
  ? bar

  $ echo 2 > ../src/foo
  $ hg -R ../src commit -m2
  $ hg admin::chainsaw-update --rev default --source ../src -q
  no interrupted transaction available
  $ hg status -A
  C foo
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

  $ hg admin::chainsaw-update --no-purge-ignored --rev default --source ../src -q
  no interrupted transaction available
  $ hg status --all
  I bar
  C .hgignore
  C foo
  $ cat bar
  ignored

  $ hg admin::chainsaw-update --rev default --source ../src -q
  no interrupted transaction available
  $ hg status --all
  C .hgignore
  C foo
  $ test -f bar
  [1]

