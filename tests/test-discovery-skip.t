==========================================================
Test hacky experimental option to skip changeset discovery
==========================================================


  $ . $TESTDIR/testlib/common.sh

  $ hg init server
  $ hg clone ssh://user@dummy/server client
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg clone ssh://user@dummy/server client-pull
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client
  $ mkcommit one
  $ mkcommit two
  $ hg update --rev 'desc("one")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit three
  created new head
  $ mkcommit four
  $ hg merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m five
  $ ONE=`hg script::revs 'desc("one")' -T "{node}"`
  $ TWO=`hg script::revs 'desc("two")' -T "{node}"`
  $ THREE=`hg script::revs 'desc("three")' -T "{node}"`
  $ FOUR=`hg script::revs 'desc("four")' -T "{node}"`
  $ FIVE=`hg script::revs 'desc("five")' -T "{node}"`
  $ hg log -G
  @    changeset:   4:7b24f21f167f
  |\   tag:         tip
  | |  parent:      3:fa78e750c446
  | |  parent:      1:5ac72c0599bf
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     five
  | |
  | o  changeset:   3:fa78e750c446
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     four
  | |
  | o  changeset:   2:20a6168d3b4d
  | |  parent:      0:3d578b4a1f53
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     three
  | |
  o |  changeset:   1:5ac72c0599bf
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     two
  |
  o  changeset:   0:3d578b4a1f53
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     one
  

push things
===========

initial normal push
-------------------

  $ hg push -r $ONE
  pushing to ssh://user@dummy/server
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files

common is a parent
------------------

  $ hg push --force -r $TWO \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$ONE
  pushing to ssh://user@dummy/server
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files

common is descendant of parent
------------------------------

  $ hg push --force -r $THREE \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$TWO
  pushing to ssh://user@dummy/server
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (+1 heads)

common is a list
----------------

  $ hg push --force -r $FIVE \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$TWO,$THREE
  pushing to ssh://user@dummy/server
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 2 changesets with 1 changes to 1 files (-1 heads)

pull things
===========

  $ cd ../client-pull

initial normal push
-------------------

  $ hg pull -r $ONE
  pulling from ssh://user@dummy/server
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 3d578b4a1f53
  (run 'hg update' to get a working copy)

common is a parent
------------------

  $ hg pull -r $TWO \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$ONE
  pulling from ssh://user@dummy/server
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 5ac72c0599bf
  (run 'hg update' to get a working copy)

common is descendant of parent
------------------------------

  $ hg pull -r $THREE \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$TWO
  pulling from ssh://user@dummy/server
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets 20a6168d3b4d
  (run 'hg heads' to see heads, 'hg merge' to merge)

common is a list
----------------

  $ hg pull -r $FIVE \
  > --config experimental.skip-changeset-discovery=yes \
  > --config experimental.skip-changeset-discovery.common=$TWO,$THREE
  pulling from ssh://user@dummy/server
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 1 changes to 1 files (-1 heads)
  new changesets fa78e750c446:7b24f21f167f
  (run 'hg update' to get a working copy)
