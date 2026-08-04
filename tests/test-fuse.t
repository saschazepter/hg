#require rhg fuse

  $ . $TESTDIR/testlib/fuse-util.sh

Simple tests of the FUSE virtual filesystem for Mercurial
=========================================================

  $ FUSE_ROOT=$TESTTMP/fuse-mount
  $ mkdir $FUSE_ROOT

Source repo setup
-----------------

  $ hg init source
  $ cd source
  $ mkdir -p nested/dir
  $ echo "untouched" >> file0
  $ echo "aaa" >> file1
  $ echo "bb" >> file2
  $ echo "c" >> nested/dir/file.txt
  $ echo "untouched" >> nested/dir/file2.txt
  $ mkdir -p otherdir/incremental_ancestor
  $ echo untouched > otherdir/untouched
  $ echo changeme > otherdir/incremental_ancestor/changed
  $ echo removeme > otherdir/incremental_ancestor/removeme
  $ hg commit -Aqm0
  $ rev0=$(hg log -r . -T "{node}\n")
  $ echo "aaa" >> file1
  $ echo "bb" >> file2
  $ echo "c" >> nested/dir/file.txt
  $ ln -s ../file1 nested/symlink1
  $ touch nested/file
  $ echo changed > otherdir/incremental_ancestor/changed
  $ hg commit -Aqm1
  $ rev1=$(hg log -r . -T "{node}\n")
  $ hg log -T'{node}\n'
  4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2
  c4c0a106bc0f83ef55a9aad7733dee971022e582

Create and test the FUSE
------------------------

  $ mount_FUSE $FUSE_ROOT
  hgvfs on $TESTTMP/fuse-mount type fuse (ro,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)

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

  $ ls commits/$rev0
  files
  $ ls commits/$rev1
  files


We can access the contents of each revision

  $ ls -l commits/$rev0/files
  total * (glob)
  -rw------- * file0 (glob)
  -rw------- * file1 (glob)
  -rw------- * file2 (glob)
  drwx------ * nested (glob)
  drwx------ * otherdir (glob)

  $ ls -l commits/$rev1/files
  total * (glob)
  -rw------- * file0 (glob)
  -rw------- * file1 (glob)
  -rw------- * file2 (glob)
  drwx------ * nested (glob)
  drwx------ * otherdir (glob)

  $ ls -l commits/$rev1/files/.hg
  total 3
  -rw------- * branch (glob)
  -rw------- * dirstate (glob)
  -rw------- * dirstate-tracked-hint (glob)
  -rw------- * dirstate.* (glob)
  -rw------- * requires (glob)
  -rw------- * sharedpath (glob)

  $ ls -l commits/$rev1/files/nested
  total 1
  drwx------ * dir (glob)
  -rw------- 1 * file (glob)
  lrwxrwxrwx 1 * symlink1 -> ../file1 (glob)

We can access contents of files
  $ cat commits/$rev1/files/file1
  aaa
  aaa

Check that files that have not changed from the first revision also work
(catch bad incremental computation)
  $ cat commits/$rev1/files/file0
  untouched
  $ cat commits/$rev1/files/nested/dir/file2.txt
  untouched
  $ cat commits/$rev1/files/otherdir/untouched
  untouched

#TODO symlink may be a problem, but not really?

We can read through symlinks
  $ cat commits/$rev1/files/nested/symlink1
  aaa
  aaa

We can read symlinks themselves
  $ readlink.py commits/$rev1/files/nested/symlink1
  commits/4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2/files/nested/symlink1 -> ../file1

Test output of readdir
  $ $RUNTESTDIR/testlib/scandir.py commits/$rev1/files/nested
  d dir
  f file
  l symlink1

Test the virtual share as a repo
--------------------------------

  $ cd commits/$rev1/files

hg finds a repo and can handle it fine

We can read the store fine

  $ hg root --share-source
  $TESTTMP/source
  $ hg id
  4ba7c48f1f1f tip
  $ hg log
  changeset:   1:4ba7c48f1f1f
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  changeset:   0:c4c0a106bc0f
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0
  

The working copy as well
  $ hg root
  $TESTTMP/fuse-mount/commits/4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2/files
  $ hg st -A
  C file0
  C file1
  C file2
  C nested/dir/file.txt
  C nested/dir/file2.txt
  C nested/file
  C nested/symlink1
  C otherdir/incremental_ancestor/changed
  C otherdir/incremental_ancestor/removeme
  C otherdir/untouched

It's read-only and hg tells the user

  $ hg up 0
  abort: could not lock working directory of $TESTTMP/fuse-mount/commits/4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2/files: Read-only file system
  [20]


Test new revisions in the source
--------------------------------

Create a new revision in the source

  $ cd $TESTTMP/source
  $ echo "after repo update" >> file1
  $ hg commit -Aqm2
  $ rev2=$(hg log -r . -T "{node}\n")
  $ hg log -T"{node}\n"
  08b3f2617733cfc557fd9105a13d97ac83cfda6a
  4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2
  c4c0a106bc0f83ef55a9aad7733dee971022e582

We can access the new revision

  $ cd $FUSE_ROOT/commits/$rev2/files

  $ hg st -A
  C file0
  C file1
  C file2
  C nested/dir/file.txt
  C nested/dir/file2.txt
  C nested/file
  C nested/symlink1
  C otherdir/incremental_ancestor/changed
  C otherdir/incremental_ancestor/removeme
  C otherdir/untouched
  $ cat file1
  aaa
  aaa
  after repo update

Test merge commits
------------------

Create two merge commits with the same contents

  $ cd $TESTTMP/source
  $ hg up -q $rev1
  $ echo "c" > nested/dir/file.txt
  $ hg commit -Aqm head1
  $ hg up -q $rev2
  $ hg merge -qr 'desc(head1)'
  $ hg commit -qm merge1
  $ merge1=$(hg log -r . -T "{node}\n")
  $ hg up -q $rev1
  $ echo "c" > nested/dir/file.txt
  $ hg commit -Aqm head2
  $ hg up -q $rev2
  $ hg merge -qr 'desc(head2)'
  $ hg commit -qm merge2
  $ merge2=$(hg log -r . -T "{node}\n")

Test that the first one works
  $ cd $FUSE_ROOT/commits/$merge1/files
  $ hg st
  $ cat nested/dir/file.txt
  c

And that incremental update to the other one with the same contents works
  $ cd $FUSE_ROOT/commits/$merge2/files
  $ hg st
  $ cat nested/dir/file.txt
  c


Test incremental removals
-------------------------

  $ cd $TESTTMP/source
  $ hg up $merge2
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg rm otherdir/incremental_ancestor/removeme
  $ hg commit -Aqm removal
  $ rev3=$(hg log -r . -T "{node}\n")

  $ cd $FUSE_ROOT/commits/$rev3/files

This file should be removed

  $ test -f otherdir/incremental_ancestor/removeme
  [1]

Its ancestry is accessible
(since we're based on dirstate-v2, which rewrites up to the root)

  $ ls -l otherdir
  total 1
  drwx------ * incremental_ancestor (glob)
  -rw------- * untouched (glob)

  $ cat otherdir/untouched
  untouched

Test that a change in repo requirements triggers an error
---------------------------------------------------------
TODO improve error reporting

  $ cd $TESTTMP/source
  $ echo "requirements change" >> file1
  $ hg commit -Aqmrequirements
  $ revrequirements=$(hg log -r . -T "{node}\n")
  $ hg log -T"{node}\n"
  8630f295ab69f8a5c51bb86a4e33ed94fd492b5f
  fa7188024a9ab44e839c0d82d6dc934077511460
  1626a4e8f5acff9b2b3443a5d312f9672129019f
  e1d28f47fc4c205825a80c1f56106d05c9954191
  469232f93e679a415c931783b00edcb762eefa72
  7c5b2d9c2a999cfdf0e484bb3b36830fd6da9403
  08b3f2617733cfc557fd9105a13d97ac83cfda6a
  4ba7c48f1f1fdd97c8b9db9101505b2a1bddf4f2
  c4c0a106bc0f83ef55a9aad7733dee971022e582
  $ hg debugupgraderepo --config format.use-fileindex-v1=yes --run -q | grep 'added: fileindex-v1'
     added: fileindex-v1

  $ ls $FUSE_ROOT/commits/$revrequirements/files
  ls: cannot access '$TESTTMP/fuse-mount/commits/8630f295ab69f8a5c51bb86a4e33ed94fd492b5f/files': Input/output error
  [2]


Cleanup
-------

This also terminates the `debug::virtual-share` invocation
XXX teach run-tests.py to do it itself?

  $ cat $TESTTMP/fuse-error.log
  $ cd $TESTTMP # move out of the FUSE so we can unmount it
  $ fusermount -u $FUSE_ROOT
  $ killdaemons.py
