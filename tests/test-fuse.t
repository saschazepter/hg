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

  $ hg debug::virtual-share $FUSE_ROOT &

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


Cleanup
-------

This also terminates the `debug::virtual-share` invocation
XXX teach run-tests.py to do it itself?

  $ cd  # move out of the FUSE so we can unmount it
  $ umount $FUSE_ROOT
