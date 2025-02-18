==============================================================================
Check potential race conditions between a dirstate's read and other operations
==============================================================================

#testcases dirstate-v1 dirstate-v2-append dirstate-v2-rewrite
#testcases pre-all-read pre-some-read

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

  $ cat >> $HGRCPATH << EOF
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF

#if no-dirstate-v1
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=yes
  > EOF
#else
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=no
  > EOF
#endif

#if dirstate-v2-rewrite
  $ d2args="--config devel.dirstate.v2.data_update_mode=force-new"
#endif
#if dirstate-v2-append
  $ d2args="--config devel.dirstate.v2.data_update_mode=force-append"
#endif


#if dirstate-v1
  $ cfg="devel.sync.dirstate.pre-read-file"
#else
#if pre-all-read
  $ cfg="devel.sync.dirstate.pre-read-file"
#else
  $ cfg="devel.sync.dirstate.post-docket-read-file"
#endif
#endif

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
  > --config ${cfg}=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting

Add a file

  $ hg $d2args add dir/n
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

#if rust dirstate-v2-append pre-some-read
  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
#else
  $ cat $TESTTMP/status-race-lock.out
  A dir/n
  A dir/o
  R dir/nested/m
  ? p
  ? q
#endif
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
  > --config ${cfg}=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting

Add a do a commit

  $ hg status
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ hg $d2args commit -m 'racing commit'
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

(The "pre-commit" state is only visible to (any) rust variant because the pure
python implementation always rewrites, so we are never really in the "-append"
case).

  $ cat $TESTTMP/status-race-lock.out
  A dir/o (dirstate-v2-append pre-some-read rust !)
  R dir/nested/m (dirstate-v2-append pre-some-read rust !)
  ? dir/n
  ? p
  ? q

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
  > --config ${cfg}=$TESTTMP/status-race-lock \
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
  
(double check the working copy location before and after the update+concurrent status)
  $ hg log -T '{node|short}\n' --rev "."
  9a86dcbfb938
(update destination)
  $ hg log -T '{node|short}\n' --rev ".~1"
  4f23db756b09
  $ hg $d2args update --merge ".~1"
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved
  $ touch $TESTTMP/status-race-lock
  $ wait
(the working copy should have been updated)
  $ hg log -T '{node|short}\n' --rev "."
  4f23db756b09
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

#if rust dirstate-v2-append pre-some-read
  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  R dir/nested/m
  ! dir/i
  ! dir/j
  ! dir/nested/h
  ! dir2/k
  ! dir2/l
  ! g
  ? dir/n
  ? p
  ? q
#else
  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  ? dir/n
  ? p
  ? q
#endif
  $ cat $TESTTMP/status-race-lock.log

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..

Race with a cache updating `hg status`
--------------------------------------

It is interesting to race with "read-only" operation (that still update its cache)

  $ cp -a reference-repo race-with-status
  $ cd race-with-status

spin a `hg status` with some caches to update

  $ hg st >$TESTTMP/status-race-lock.out 2>$TESTTMP/status-race-lock.log \
  > --config rhg.on-unsupported=abort \
  > --config ${cfg}=$TESTTMP/status-race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/status-race-lock.waiting
do an update

  $ touch -t 200001020006 f
  $ hg $d2args status
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ touch $TESTTMP/status-race-lock
  $ wait

The status process should return a consistent result and not crash.

  $ cat $TESTTMP/status-race-lock.out
  A dir/o
  R dir/nested/m
  ? dir/n
  ? p
  ? q
  $ cat $TESTTMP/status-race-lock.log

final cleanup

  $ rm $TESTTMP/status-race-lock $TESTTMP/status-race-lock.waiting
  $ cd ..
