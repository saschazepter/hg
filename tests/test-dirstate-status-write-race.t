=====================================================================
Check potential race conditions between a status and other operations
=====================================================================

The `hg status` command can run without the wlock, however it might end up
having to update the on-disk dirstate files, for example to mark ambiguous
files as clean, or to update directory caches information with dirstate-v2.


If another process updates the dirstate in the meantime we might run into
trouble. Especially, commands doing semantic changes like `hg add` or
 `hg commit` should not see their update erased by a concurrent status.

Unlike commands like `add` or `commit`, `status` only writes the dirstate
to update caches, no actual information is lost if we fail to write to disk.


This test file is meant to test various cases where such parallel operations
between a status with reasons to update the dirstate and another semantic
changes happen.


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
  $ hg commit -Aqm "more files to have two commits"
  $ hg log -G -v
  @  changeset:   1:c349430a1631
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       dir/i dir/j dir/nested/h dir/nested/m dir2/k dir2/l g
  |  description:
  |  more files to have two commits
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

  $ hg st
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

Explain / verify the test principles
------------------------------------

First, we can properly copy the reference

  $ cp -a reference-repo sanity-check
  $ cd sanity-check
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
  $ hg debugstate > ../post-copy
  $ diff ../reference ../post-copy

And status thinks the cache is in a proper state

  $ hg st
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
  $ hg debugstate > ../post-status
  $ diff ../reference ../post-status

Then we can start a status that:
- has some update to do (the touch call)
- will wait AFTER running status, but before updating the cache on disk

  $ touch -t 200001010001 dir/c
  $ hg st >$TESTTMP/status-race-lock.out 2>$TESTTMP/status-race-lock.log \
  > --config rhg.on-unsupported=abort \
  > --config devel.sync.status.pre-dirstate-write-file=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting

We check it runs the status first by modifying a file and updating another timestamp

  $ touch -t 200001010003 dir/i
  $ echo babar > dir/j
  $ touch $TESTTMP/status-race-lock
  $ wait

The test process should have reported a status before the change we made,
and should have missed the timestamp update

  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ cat $TESTTMP/status-race-lock.log
  $ hg debugstate | grep dir/c
  n 644          0 2000-01-01 00:01:00 dir/c
  $ hg debugstate | grep dir/i
  n 644          0 2000-01-01 00:10:00 dir/i
  $ hg debugstate | grep dir/j
  n 644          0 2000-01-01 00:10:00 dir/j

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..
