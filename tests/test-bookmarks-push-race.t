============================================
Testing various race condition while pushing
============================================

  $ cat << EOF >> $HGRCPATH
  > [command-templates]
  > log={rev}:{node|short} {desc|firstline} {bookmarks}
  > [ui]
  > timeout = 20
  > [phases]
  > publish=False
  > EOF

Initial Setup
=============

  $ hg init dst
  $ echo a > dst/a-file
  $ hg --cwd dst add a-file
  $ hg --cwd dst commit -m root
  $ hg --cwd dst bookmark my-book
  $ hg --cwd dst bookmarks
   * my-book                   0:a64e49638499
  $ hg --cwd dst log -G
  @  0:a64e49638499 root my-book
  

  $ hg clone ssh://user@dummy/dst src
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets a64e49638499 (1 drafts)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg --cwd src update my-book
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark my-book)
  $ hg --cwd src log -G
  @  0:a64e49638499 root my-book
  

  $ echo b > src/a-file
  $ hg --cwd src commit -m cA0_
  $ hg --cwd src log -G
  @  1:e89d3a6ed79b cA0_ my-book
  |
  o  0:a64e49638499 root
  

Race condition while pushing a forward moving bookmarks
=======================================================

This is currently slightly broken as we eventually don't push the bookmark.
However at least we do not delete the remote one.

  $ echo c > src/a-file
  $ hg --cwd src push -B my-book --config hooks.prelock="hg commit -m cA1_"
  pushing to ssh://user@dummy/dst
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  $ hg --cwd src log -G
  @  2:08d837bbfe8d cA1_ my-book
  |
  o  1:e89d3a6ed79b cA0_
  |
  o  0:a64e49638499 root
  
  $ hg --cwd dst log -G
  o  1:e89d3a6ed79b cA0_
  |
  @  0:a64e49638499 root my-book
  

create a side-moving bookmark
Race condition while pushing a side moving bookmarks
=======================================================

resynchronize the repo and setup test
-------------------------------------

  $ hg --cwd src push -B my-book
  pushing to ssh://user@dummy/dst
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  updating bookmark my-book
  $ hg --cwd dst log -G
  o  2:08d837bbfe8d cA1_ my-book
  |
  o  1:e89d3a6ed79b cA0_
  |
  @  0:a64e49638499 root
  

  $ hg --cwd src up 'desc("root")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (leaving bookmark my-book)
  $ echo d > src/a-file
  $ hg --cwd src commit -m cB0_
  created new head
  $ hg --cwd src bookmark --force my-book
  $ echo e > src/a-file
  $ hg --cwd src log -G
  @  3:726401661fe5 cB0_ my-book
  |
  | o  2:08d837bbfe8d cA1_
  | |
  | o  1:e89d3a6ed79b cA0_
  |/
  o  0:a64e49638499 root
  

Push the bookmark while a commit is being made
----------------------------------------------

This is currently slightly broken as we eventually don't push the bookmark.
However at least we do not delete the remote one.

  $ hg --cwd src push -f -r 'desc("cB0_")' -B my-book --config hooks.prelock="hg commit -m cB1_"
  pushing to ssh://user@dummy/dst
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (+1 heads)
  $ hg --cwd src log -G
  @  4:a7f9cbf631a0 cB1_ my-book
  |
  o  3:726401661fe5 cB0_
  |
  | o  2:08d837bbfe8d cA1_
  | |
  | o  1:e89d3a6ed79b cA0_
  |/
  o  0:a64e49638499 root
  

  $ hg --cwd dst log -G
  o  3:726401661fe5 cB0_
  |
  | o  2:08d837bbfe8d cA1_ my-book
  | |
  | o  1:e89d3a6ed79b cA0_
  |/
  @  0:a64e49638499 root
  
