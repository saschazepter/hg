==============================================================================
Check potential race conditions between a dirstate's read and other operations
==============================================================================

Some commands, like `hg status`, do not need to take the wlock but need to
access dirstate data.
Other commands might update the dirstate data while this happens.

This can create issues if repository data is read in the wrong order, or for
the dirstate-v2 format where the data is contained in multiple files.

This test file is meant to test various cases where such parallel operations
happen and make sure the reading process behaves fine. We do so with a `hg
status` command since it is probably the most advanced of such read-only
command.

It bears simililarity with `tests/test-dirstate-status-race.t ` but tests a
different type of race.

Setup
=====

  $ directories="dir dir/nested dir2"
  $ first_files="dir/nested/a dir/b dir/c dir/d dir2/e f"
  $ second_files="g dir/nested/h dir/i dir/j dir2/k dir2/l dir/nested/m"
  $ extra_files="dir/n dir/o p q"

  $ hg init reference-repo
  $ cd reference-repo
  $ mkdir -p dir/nested dir2
  $ touch -t 200001010000 $first_files $directories
  $ hg commit -Aqm "recreate a bunch of files to facilitate dirstate-v2 append"
  $ touch -t 200001010010 $second_files $directories
  $ hg commit -Aqm "more files to have two commit"
  $ hg log -G -v
  @  changeset:   1:9a86dcbfb938
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       dir/i dir/j dir/nested/h dir/nested/m dir2/k dir2/l g
  |  description:
  |  more files to have two commit
  |
  |
  o  changeset:   0:4f23db756b09
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     files:       dir/b dir/c dir/d dir/nested/a dir2/e f
     description:
     recreate a bunch of files to facilitate dirstate-v2 append
  
  
  $ hg manifest
  dir/b
  dir/c
  dir/d
  dir/i
  dir/j
  dir/nested/a
  dir/nested/h
  dir/nested/m
  dir2/e
  dir2/k
  dir2/l
  f
  g

Add some unknown files and refresh the dirstate

  $ touch -t 200001010020 $extra_files
  $ hg add dir/o
  $ hg remove dir/nested/m

  $ hg st --config devel.dirstate.v2.data_update_mode=force-new
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ hg debugstate
  n 644          0 2000-01-01 00:00:00 dir/b
  n 644          0 2000-01-01 00:00:00 dir/c
  n 644          0 2000-01-01 00:00:00 dir/d
  n 644          0 2000-01-01 00:10:00 dir/i
  n 644          0 2000-01-01 00:10:00 dir/j
  n 644          0 2000-01-01 00:00:00 dir/nested/a
  n 644          0 2000-01-01 00:10:00 dir/nested/h
  r ?????????????????????????????????? dir/nested/m (glob)
  a ?????????????????????????????????? dir/o (glob)
  n 644          0 2000-01-01 00:00:00 dir2/e
  n 644          0 2000-01-01 00:10:00 dir2/k
  n 644          0 2000-01-01 00:10:00 dir2/l
  n 644          0 2000-01-01 00:00:00 f
  n 644          0 2000-01-01 00:10:00 g
  $ hg debugstate > ../reference
  $ cd ..

Actual Testing
==============

Race with a `hg add`
-------------------

  $ cp -a reference-repo race-with-add
  $ cd race-with-add

spin a `hg status` with some caches to update

  $ hg st >$TESTTMP/status-race-lock.out 2>$TESTTMP/status-race-lock.log \
  > --config rhg.on-unsupported=abort \
  > --config devel.sync.dirstate.pre-read-file=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting

Add a file

  $ hg add dir/n $d2args
  $ touch $TESTTMP/status-race-lock
  $ wait

The file should in a "added" state

  $ hg status
  A dir/n
  A dir/o
  R dir/nested/m
  ? p
  ? q

The status process should return a consistent result and not crash.

  $ cat $TESTTMP/status-race-lock.out
  A dir/n
  A dir/o
  R dir/nested/m
  ? p
  ? q
  $ cat $TESTTMP/status-race-lock.log

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..

Race with a `hg commit`
-----------------------

  $ cp -a reference-repo race-with-commit
  $ cd race-with-commit

spin a `hg status with some cache to update

  $ hg st >$TESTTMP/status-race-lock.out 2>$TESTTMP/status-race-lock.log \
  > --config rhg.on-unsupported=abort \
  > --config devel.sync.dirstate.pre-read-file=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting

Add a do a commit

  $ hg status
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ hg commit -m 'racing commit'
  $ touch $TESTTMP/status-race-lock
  $ wait

commit was created, and status is now clean

  $ hg log -GT '{node|short} {desc}\n'
  @  02a67a77ee9b racing commit
  |
  o  9a86dcbfb938 more files to have two commit
  |
  o  4f23db756b09 recreate a bunch of files to facilitate dirstate-v2 append
  
  $ hg status
  ? dir/n
  ? p
  ? q

The status process should return a consistent result and not crash.

  $ cat $TESTTMP/status-race-lock.out
  M dir/o (known-bad-output no-rhg !)
  ? dir/n
  ? p
  ? q
  $ cat $TESTTMP/status-race-lock.log
  warning: ignoring unknown working parent 02a67a77ee9b! (known-bad-output no-rhg !)

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..

Race with a `hg update`
-----------------------

  $ cp -a reference-repo race-with-update
  $ cd race-with-update

spin a `hg status` with some caches to update

  $ hg st >$TESTTMP/status-race-lock.out 2>$TESTTMP/status-race-lock.log \
  > --config rhg.on-unsupported=abort \
  > --config devel.sync.dirstate.pre-read-file=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting
do an update

  $ hg status
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ hg log -GT '{node|short} {desc}\n'
  @  9a86dcbfb938 more files to have two commit
  |
  o  4f23db756b09 recreate a bunch of files to facilitate dirstate-v2 append
  
  $ hg update --merge .^
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved
  $ touch $TESTTMP/status-race-lock
  $ wait
  $ hg log -GT '{node|short} {desc}\n'
  o  9a86dcbfb938 more files to have two commit
  |
  @  4f23db756b09 recreate a bunch of files to facilitate dirstate-v2 append
  
  $ hg status
  A dir/o
  ? dir/n
  ? p
  ? q

The status process should return a consistent result and not crash.

  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  ? dir/n
  ? p
  ? q
  $ cat $TESTTMP/status-race-lock.log

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..
