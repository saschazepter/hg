=======================================================================
Check potential race condition around transaction and working copy data
=======================================================================

#testcases bookmarks-in-store bookmarks-wc-level

The transaction is garanteed to run with the lock, but may runs without the
wlock. So if the transaction backup/restore some content related to the
working-copy and protected by the wlock, we might run into trouble if another
process grab the wlock and modify them.

This test file is testing various cases where such parallel changes happens to
validate the transaction behavior.

Other is used to get a simple pull source. As pull is a simple way to create
transaction without the wlock.

Setup
=====

Avoid long deadlock

  $ cat << EOF >> $HGRCPATH
  > [ui]
  > timeout=10
  > EOF

#if bookmarks-in-store
  $ cat << EOF >> $HGRCPATH
  > [format]
  > bookmarks-in-store = yes
  > EOF
#endif


  $ hg init repo
  $ cd repo
  $ for filename in a b c d e f g h i j k l m; do
  >     echo $filename > default_$filename
  >     hg add default_$filename
  >     hg commit --quiet --message default_$filename
  > done
  $ hg bookmark --rev . foo
  $ hg branch babar
  marked working directory as branch babar
  (branches are permanent and global, did you want a bookmark?)
  $ for filename in a b c d e f g h i j k l m; do
  >     echo $filename > babar_$filename
  >     hg add babar_$filename
  >     hg commit --quiet --message babar_$filename
  > done
  $ hg bookmark --rev . bar
  $ hg up 'desc("default_m")'
  0 files updated, 0 files merged, 13 files removed, 0 files unresolved
  $ hg log -G -T '[{branch}] ({bookmarks}) {desc}\n'
  o  [babar] (bar) babar_m
  |
  o  [babar] () babar_l
  |
  o  [babar] () babar_k
  |
  o  [babar] () babar_j
  |
  o  [babar] () babar_i
  |
  o  [babar] () babar_h
  |
  o  [babar] () babar_g
  |
  o  [babar] () babar_f
  |
  o  [babar] () babar_e
  |
  o  [babar] () babar_d
  |
  o  [babar] () babar_c
  |
  o  [babar] () babar_b
  |
  o  [babar] () babar_a
  |
  @  [default] (foo) default_m
  |
  o  [default] () default_l
  |
  o  [default] () default_k
  |
  o  [default] () default_j
  |
  o  [default] () default_i
  |
  o  [default] () default_h
  |
  o  [default] () default_g
  |
  o  [default] () default_f
  |
  o  [default] () default_e
  |
  o  [default] () default_d
  |
  o  [default] () default_c
  |
  o  [default] () default_b
  |
  o  [default] () default_a
  

  $ cat << EOF >> ../txn-close.sh
  > rm -f $TESTTMP/transaction-continue
  > $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-continue $TESTTMP/transaction-waiting
  > rm -f $TESTTMP/transaction-waiting
  > exit 1
  > EOF
  $ cat << EOF >> .hg/hgrc
  > [hooks]
  > pretxnclose.test = sh $TESTTMP/txn-close.sh
  > EOF

Check the overall logic is working, the transaction is holding the `lock` , but
not the `wlock`, then get aborted on a signal-file.

  $ hg phase --rev 0
  0: draft
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ echo y | hg --config ui.interactive=yes debuglock --set-wlock
  ready to release the lock (y)?  y
  $ echo y | hg --config ui.interactive=yes debuglock --set-lock
  abort: lock is already held
  [255]
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg phase --rev 0
  0: draft
  $ cat ../log.err
  transaction abort!
  rollback completed
  abort: pretxnclose.test hook exited with status 1

Actual testing
==============

Changing tracked file
---------------------

  $ hg status
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg forget default_a
  $ hg status
  R default_a
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg status
  R default_a (missing-correct-output !)
  $ hg revert --all --quiet

Changing branch from default
----------------------------

  $ hg branch
  default
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg branch celeste
  marked working directory as branch celeste
  $ hg branch
  celeste
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg branch
  celeste

Changing branch from another one
--------------------------------

  $ hg up babar --quiet
  $ hg branch
  babar
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg branch celeste
  marked working directory as branch celeste
  $ hg branch
  celeste
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg branch
  celeste

updating working copy
---------------------

  $ hg st
  $ hg log --rev . -T '{desc}\n'
  babar_m
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg update "parents(.)" --quiet
  $ hg log --rev . -T '{desc}\n'
  babar_l
  $ hg st
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg log --rev . -T '{desc}\n'
  babar_l (missing-correct-output !)
  babar_m (known-bad-output !)
  $ hg st
  ! babar_m (known-bad-output !)

  $ hg purge --no-confirm
  $ hg up --quiet babar

Activating a bookmark
---------------------
(without going through the bookmark command)

Show the activation/desactivation pattern that exist without taking the store
lock.

  $ hg log -r . -T '= {activebookmark} =\n'
  =  =
  $ hg up bar
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark bar)
  $ hg log -r . -T '= {activebookmark} =\n'
  = bar =
  $ hg up .
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (leaving bookmark bar)
  $ hg log -r . -T '= {activebookmark} =\n'
  =  =

Activating the bookmark during a transaction

  $ hg up . --quiet
  $ hg log -r . -T '= {activebookmark} =\n'
  =  =
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg up bar
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark bar)
  $ hg log -r . -T '= {activebookmark} =\n'
  = bar =
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg log -r . -T '= {activebookmark} =\n'
  = bar =

Deactivating the bookmark

  $ hg up bar --quiet
  $ hg log -r . -T '= {activebookmark} =\n'
  = bar =
  $ hg phase --public --rev 0 2> ../log.err &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/transaction-waiting
  $ hg up .
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (leaving bookmark bar)
  $ hg log -r . -T '= {activebookmark} =\n'
  =  =
  $ touch $TESTTMP/transaction-continue
  $ wait
  $ hg log -r . -T '= {activebookmark} =\n'
  =  =
