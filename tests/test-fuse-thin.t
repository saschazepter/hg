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
TODO call [hg requires] instead of directly [cat]ing the file once thin.py
allows [hg requires] to succeed here
  $ cat .hg/requires | sort
  dirstate-tracked-key-v1
  dirstate-v2
  exp-v0-thin
  share-safe

Cleanup
-------

This also terminates the `debug::virtual-share` invocation

  $ cat $TESTTMP/fuse-error.log
  $ cd $TESTTMP # move out of the FUSE so we can unmount it
  $ fusermount -u "$LOWER_ROOT"
  $ killdaemons.py
