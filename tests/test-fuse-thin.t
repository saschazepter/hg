#require rhg fuse

  $ . $TESTDIR/testlib/fuse-util.sh

Simple tests of the FUSE virtual filesystem for Mercurial
=========================================================

  $ LOWER_ROOT=$TESTTMP/fuse-mount-lower
  $ UPPER=$TESTTMP/upper
  $ WORK=$TESTTMP/work
  $ MERGED_ROOT=$TESTTMP/merged
  $ mkdir $LOWER_ROOT $UPPER $WORK $MERGED_ROOT

Source repo setup
-----------------

  $ SOURCE=$TESTTMP/source
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

  $ mount_FUSE "$LOWER_ROOT" --backend-mode thin
  hgvfs on $TESTTMP/fuse-mount-lower type fuse (ro,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)

Our thin working copy doesn't have a store or sharedpath, but does have a thin-backend file

  $ cd $LOWER_ROOT/commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files
  $ cat .hg/thin-backend
  local://$TESTTMP/source
  $ hg --config extensions.thin= debugrequires
  dirstate-tracked-key-v1
  dirstate-v2
  exp-v0-thin
  share-safe

Set up a fuse overlay so we can write to the working copy

  $ fuse-overlayfs -o lowerdir=$LOWER_ROOT/commits/017e3e0cea11ca4bd5cfa8c2b9922deb995f98ca/files,upperdir=$UPPER,workdir=$WORK $MERGED_ROOT
  $ wait_for_mount "fuse-overlayfs" "$MERGED_ROOT"
  fuse-overlayfs on $TESTTMP/merged type fuse.fuse-overlayfs (rw,nosuid,nodev,noatime,user_id=*,group_id=*,default_permissions) (glob)

We now have a working copy we can modify and commit to, and
commits show up in the backing repo

  $ cd $MERGED_ROOT
  $ echo "asdfjkl;" >> file1
  $ hg commit --config extensions.thin= -m "test thin commit"
  $ hg --cwd $SOURCE log -r tip -p
  changeset:   2:990e4e6866d3
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     test thin commit
  
  diff -r 017e3e0cea11 -r 990e4e6866d3 file1
  --- a/file1	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file1	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,2 +1,3 @@
   aaa
   aaa
  +asdfjkl;
  

  $ <file1 sed 's/a/b/g' >file1.out ; mv file1.out file1
  $ hg commit --config extensions.thin= -m "another thin commit"
  $ hg --cwd $SOURCE log -r tip -p
  changeset:   3:7b26e8d1a743
  tag:         tip
  parent:      1:017e3e0cea11
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another thin commit
  
  diff -r 017e3e0cea11 -r 7b26e8d1a743 file1
  --- a/file1	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file1	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,2 +1,3 @@
  -aaa
  -aaa
  +bbb
  +bbb
  +bsdfjkl;
  


Cleanup
-------

This also terminates the `debug::virtual-share` invocation

  $ cat $TESTTMP/fuse-error.log
  $ cd $TESTTMP # move out of the FUSE so we can unmount it
  $ fusermount -u "$MERGED_ROOT"
  $ fusermount -u "$LOWER_ROOT"
  $ killdaemons.py
