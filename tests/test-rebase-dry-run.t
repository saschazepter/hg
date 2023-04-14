======================
rebase --dry-run tests
======================

Test behavior associated with `hg rebase --dry-run`

Setup
=====

  $ hg init r1
  $ cd r1
  $ echo one > f01.txt
  $ echo two > f02.txt
  $ echo three > f03.txt
  $ hg add
  adding f01.txt
  adding f02.txt
  adding f03.txt
  $ hg ci -m 'ci-1' f01.txt f02.txt f03.txt
  $ hg book base; hg book -i
  $ echo add-to-one >> f01.txt
  $ hg ci -m 'br-1' f01.txt
  $ hg book branch-1; hg book -i
  $ hg up base; hg book -i
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark base)
  $ echo add-to-two >> f02.txt
  $ hg ci -m 'br-2' f02.txt
  created new head
  $ hg book branch-2; hg book -i
  $ hg up branch-1; hg book -i
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark branch-1)
  $ hg log -G
  o  changeset:   2:d408211b0a6f
  |  bookmark:    branch-2
  |  tag:         tip
  |  parent:      0:99418d161ee0
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     br-2
  |
  | @  changeset:   1:ab62441498e5
  |/   bookmark:    branch-1
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     br-1
  |
  o  changeset:   0:99418d161ee0
     bookmark:    base
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ci-1
  


Check the working copy changes do not get wiped out
===================================================

  $ echo add-to-three >> f03.txt

f03 is modified

  $ hg st
  M f03.txt
  $ hg diff
  diff -r ab62441498e5 f03.txt
  --- a/f03.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/f03.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,2 @@
   three
  +add-to-three


  $ hg rebase -v -n -s branch-2 -d branch-1 --config extensions.rebase=
  starting dry-run rebase; repository will not be changed
  rebasing 2:d408211b0a6f branch-2 tip "br-2"
  resolving manifests
  getting f02.txt
  committing files:
  f02.txt
  committing manifest
  committing changelog
  rebase merging completed
  dry-run rebase completed successfully; run without -n/--dry-run to perform this rebase

f03 changes are lost

  $ hg st
  M f03.txt
  $ hg diff
  diff -r ab62441498e5 f03.txt
  --- a/f03.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/f03.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,2 @@
   three
  +add-to-three
