#require rhg fuse

Simple tests of the FUSE virtual filesystem for Mercurial
=========================================================

  $ FUSE_ROOT=$TESTTMP/fuse-mount
  $ mkdir $FUSE_ROOT

Source repo setup
-----------------

  $ hg init source
  $ cd source
  $ mkdir -p nested/dir
  $ touch file1 file2 nested/dir/file.txt
  $ echo "aaa" >> file1
  $ echo "bb" >> file2
  $ echo "c" >> nested/dir/file.txt
  $ hg commit -Aqm0
  $ echo "aaa" >> file1
  $ echo "bb" >> file2
  $ echo "c" >> nested/dir/file.txt
  $ ln -s ../file1 nested/symlink1
  $ hg commit -Aqm1
  $ hg log -T'{node}\n'
  017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca
  1bed6038501e18cfa5551b71175be951891ced70

Create and test the FUSE
------------------------

  $ hg debug::virtual-share $FUSE_ROOT --pid-file=$TESTTMP/fuse.pid 2>error.log &

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

We can list the root

  $ cd $FUSE_ROOT
  $ ls -1
  commits
  meta

Listing the commits is forbidden

  $ ls commits
  ls: reading directory 'commits': $EACCES$
  [2]

Changeset folders can be listed

  $ ls commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca
  files
  $ ls commits/1bed6038501e18cfa5551b71175be951891ced70
  files


We can access the contents of each revision

  $ ls -l commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files
  total * (glob)
  -rw------- * file1 (glob)
  -rw------- * file2 (glob)
  drwx------ * nested (glob)
  $ ls -l commits/1bed6038501e18cfa5551b71175be951891ced70/files
  total * (glob)
  -rw------- * file1 (glob)
  -rw------- * file2 (glob)
  drwx------ * nested (glob)


  $ ls -l commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files/nested
  total 1
  drwx------ * dir (glob)
  lrw------- 1 * symlink1 -> ../file1 (glob)


We can access contents of files
  $ cat commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files/file1
  aaa
  aaa

We can read through symlinks
  $ cat commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files/nested/symlink1
  aaa
  aaa

We can read symlinks themselves
  $ readlink.py commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files/nested/symlink1
  commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files/nested/symlink1 -> ../file1


Test the virtual share as a repo
--------------------------------

  $ cd commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files

hg finds a repo and can handle it fine

We can read the store fine

  $ hg root --share-source
  $TESTTMP/source
  $ hg id
  017e3e0cea11 tip
  $ hg log
  changeset:   1:017e3e0cea11
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  changeset:   0:1bed6038501e
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0
  

The working copy as well
  $ hg root
  $TESTTMP/fuse-mount/commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files
  $ hg st -A
  C file1
  C file2
  C nested/dir/file.txt
  C nested/symlink1

It's read-only and hg tells the user

  $ hg up 0
  abort: could not lock working directory of $TESTTMP/fuse-mount/commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files: Read-only file system
  [20]


Test new revisions in the source
--------------------------------

Create a new revision in the source

  $ cd $TESTTMP/source
  $ echo "after repo update" >> file1
  $ hg commit -Aqm2
  $ hg log -T"{node}\n"
  df38c26fa2f9c99a713635376e2df59076a5a2cf
  017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca
  1bed6038501e18cfa5551b71175be951891ced70

We can access the new revision

  $ cd $FUSE_ROOT/commits/df38c26fa2f9c99a713635376e2df59076a5a2cf/files
  $ hg st -A
  C error.log
  C file1
  C file2
  C nested/dir/file.txt
  C nested/symlink1
  $ cat file1
  aaa
  aaa
  after repo update

Test that a change in repo requirements triggers an error
TODO improve error reporting

  $ cd $TESTTMP/source
  $ echo "requirements change" >> file1
  $ hg commit -Aqm3
  $ hg log -T"{node}\n"
  56cfdc65ceb2a449d20c252c94dc1d9b514fed9f
  df38c26fa2f9c99a713635376e2df59076a5a2cf
  017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca
  1bed6038501e18cfa5551b71175be951891ced70
  $ hg debugupgraderepo --config format.use-fileindex-v1=yes --run -q | grep 'added: fileindex-v1'
     added: fileindex-v1

  $ ls $FUSE_ROOT/commits/56cfdc65ceb2a449d20c252c94dc1d9b514fed9f/files
  ls: cannot access '$TESTTMP/fuse-mount/commits/56cfdc65ceb2a449d20c252c94dc1d9b514fed9f/files': Input/output error
  [2]


Cleanup
-------

This also terminates the `debug::virtual-share` invocation
XXX teach run-tests.py to do it itself?

  $ cd $TESTTMP # move out of the FUSE so we can unmount it
  $ umount $FUSE_ROOT
