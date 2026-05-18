#require rhg fuse

  $ . $TESTDIR/testlib/common.sh

Make sure the FUSE still works even after a reclone
===================================================

  $ FUSE_ROOT=$TESTTMP/fuse-mount
  $ mkdir $FUSE_ROOT

Setup remote and clone
----------------------

  $ REMOTE=$TESTTMP/remote
  $ mkdir $REMOTE
  $ cd $REMOTE
  $ hg init

  $ mkcommit 0

  $ CLONE=$TESTTMP/clone
  $ hg clone -q $REMOTE $CLONE

  $ mkcommit 1a
  $ rev1a=$(hg script::revs .)
  $ mkcommit 1b
  $ rev1b=$(hg script::revs .)

  $ hg up -q 0
  $ mkcommit 2a
  created new head
  $ mkcommit 2b

  $ hg up -q 0
  $ mkcommit 3a
  created new head
  $ rev3a=$(hg script::revs .)
  $ mkcommit 3b
  $ rev3b=$(hg script::revs .)

  $ cd $CLONE
  $ hg up -q 0
  $ mkcommit 4a
  $ hg pull -q -r $rev3b
  $ mkcommit 4b
  $ mkcommit 4c
  $ hg pull -q -r $rev1b

The revisions numbers in the clone do not match the remote:
- rev3b is 6 in the remote, 3 in the clone
- rev1b is 2 in the remote, 7 in the clone

  $ hg --cwd $REMOTE log -r $rev3b -T "{rev}\n"
  6
  $ hg --cwd $CLONE log -r $rev3b -T "{rev}\n"
  3

  $ hg --cwd $REMOTE log -r $rev1b -T "{rev}\n"
  2
  $ hg --cwd $CLONE log -r $rev1b -T "{rev}\n"
  7

Create and test the FUSE
------------------------

  $ cd $TESTTMP
  $ hg debug::virtual-share --cwd $CLONE $FUSE_ROOT --pid-file=$TESTTMP/fuse.pid 2>error.log &

Wait for it to be mounted, timeout after a short period

  $ iterations=0
  $ maxiterations=50
  > while ! (mount | grep "hgvfs on $FUSE_ROOT") && [ $iterations -lt $maxiterations ]
  > do
  >   sleep 0.1
  >   iterations=`expr $iterations + 1`
  > done
  hgvfs on $TESTTMP/fuse-mount type fuse (ro,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)
  $ [ $iterations -ge $maxiterations ] && echo "timed out waiting for the FUSE to mount" || true

  $ cat $TESTTMP/fuse.pid >> $DAEMON_PIDS
  $ cat error.log

Check FUSE contents

  $ cd $FUSE_ROOT
  $ ls commits/$rev3b/files
  0
  3a
  3b
  $ ls commits/$rev1b/files
  0
  1a
  1b

Do a reclone, which changes revision numbers. Now they match:

  $ rm -rf $CLONE
  $ hg clone -q $REMOTE $CLONE

  $ hg --cwd $REMOTE log -r $rev3b -T "{rev}\n"
  6
  $ hg --cwd $CLONE log -r $rev3b -T "{rev}\n"
  6

  $ hg --cwd $REMOTE log -r $rev1b -T "{rev}\n"
  2
  $ hg --cwd $CLONE log -r $rev1b -T "{rev}\n"
  2

FUSE contents are still valid

  $ ls commits/$rev3b/files
  0
  3a
  3b
  $ ls commits/$rev1b/files
  0
  1a
  1b

  $ ls commits/$rev3a/files
  0
  3a
  $ ls commits/$rev1a/files
  0
  1a

Cleanup
-------

  $ cat $TESTTMP/error.log
  $ cd $TESTTMP # move out of the FUSE so we can unmount it
  $ fusermount -u $FUSE_ROOT
  $ killdaemons.py

