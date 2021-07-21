#testcases flat tree
#testcases lfs-on lfs-off

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution=createmarkers
  > EOF

#if lfs-on
  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > lfs =
  > EOF
#endif

  $ . "$TESTDIR/narrow-library.sh"

#if tree
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > treemanifest = 1
  > EOF
#endif

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [narrow]
  > serveellipses=True
  > EOF
  $ for x in `$TESTDIR/seq.py 0 10`
  > do
  >   mkdir d$x
  >   echo $x > d$x/f
  >   hg add d$x/f
  >   hg commit -m "add d$x/f"
  > done
  $ hg log -T "{rev}: {desc}\n"
  10: add d10/f
  9: add d9/f
  8: add d8/f
  7: add d7/f
  6: add d6/f
  5: add d5/f
  4: add d4/f
  3: add d3/f
  2: add d2/f
  1: add d1/f
  0: add d0/f
  $ cd ..

Error if '.' or '..' are in the directory to track.
  $ hg clone --narrow ssh://user@dummy/master foo --include ./asdf
  abort: "." and ".." are not allowed in narrowspec paths
  [255]
  $ hg clone --narrow ssh://user@dummy/master foo --include asdf/..
  abort: "." and ".." are not allowed in narrowspec paths
  [255]
  $ hg clone --narrow ssh://user@dummy/master foo --include a/./c
  abort: "." and ".." are not allowed in narrowspec paths
  [255]

Names with '.' in them are OK.
  $ hg clone --narrow ./master should-work --include a/.b/c
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets * (glob)
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test repo with local changes
  $ hg clone --narrow ssh://user@dummy/master narrow-local-changes --include d0 --include d3 --include d6
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 3 changes to 3 files
  new changesets *:* (glob)
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd narrow-local-changes
  $ echo local change >> d0/f
  $ hg ci -m 'local change to d0'
  $ hg co '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo local change >> d3/f
  $ hg ci -m 'local hidden change to d3'
  created new head
  $ hg ci --amend -m 'local change to d3'
  $ hg tracked --removeinclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  * (glob)
  abort: local changes found
  (use --force-delete-local-changes to ignore)
  [20]
Check that nothing was removed by the failed attempts
  $ hg tracked
  I path:d0
  I path:d3
  I path:d6
  $ hg files
  d0/f
  d3/f
  d6/f
  $ find *
  d0
  d0/f
  d3
  d3/f
  d6
  d6/f
  $ hg verify -q
Force deletion of local changes
  $ hg log -T "{rev}: {desc} {outsidenarrow}\n"
  8: local change to d3 
  6: local change to d0 
  5: add d10/f outsidenarrow
  4: add d6/f 
  3: add d5/f outsidenarrow
  2: add d3/f 
  1: add d2/f outsidenarrow
  0: add d0/f 
  $ hg tracked --removeinclude d0 --force-delete-local-changes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  * (glob)
  moving unwanted changesets to backup
  saved backup bundle to $TESTTMP/narrow-local-changes/.hg/strip-backup/*-narrow.hg (glob)
  deleting data/d0/f.i (reporevlogstore !)
  deleting meta/d0/00manifest.i (tree !)
  deleting data/d0/f/362fef284ce2ca02aecc8de6d5e8a1c3af0556fe (reposimplestore !)
  deleting data/d0/f/4374b5650fc5ae54ac857c0f0381971fdde376f7 (reposimplestore !)
  deleting data/d0/f/index (reposimplestore !)
  deleting unwanted files from working copy

  $ hg log -T "{rev}: {desc} {outsidenarrow}\n"
  7: local change to d3 
  5: add d10/f outsidenarrow
  4: add d6/f 
  3: add d5/f outsidenarrow
  2: add d3/f 
  1: add d2/f outsidenarrow
  0: add d0/f outsidenarrow
Can restore stripped local changes after widening
  $ hg tracked --addinclude d0 -q
  $ hg unbundle .hg/strip-backup/*-narrow.hg -q
  $ hg --hidden co -r 'desc("local change to d0")' -q
  $ cat d0/f
  0
  local change
Pruned commits affecting removed paths should not prevent narrowing
  $ hg co '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg debugobsolete `hg log -T '{node}' -r 'desc("local change to d0")'`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg tracked --removeinclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  moving unwanted changesets to backup
  saved backup bundle to $TESTTMP/narrow-local-changes/.hg/strip-backup/*-narrow.hg (glob)
  deleting data/d0/f.i (reporevlogstore !)
  deleting meta/d0/00manifest.i (tree !)
  deleting data/d0/f/362fef284ce2ca02aecc8de6d5e8a1c3af0556fe (reposimplestore !)
  deleting data/d0/f/4374b5650fc5ae54ac857c0f0381971fdde376f7 (reposimplestore !)
  deleting data/d0/f/index (reposimplestore !)
  deleting unwanted files from working copy

Updates off of stripped commit if necessary
  $ hg co -r 'desc("local change to d3")' -q
  $ echo local change >> d6/f
  $ hg ci -m 'local change to d6'
  $ hg tracked --removeinclude d3 --force-delete-local-changes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  * (glob)
  * (glob)
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  moving unwanted changesets to backup
  saved backup bundle to $TESTTMP/narrow-local-changes/.hg/strip-backup/*-narrow.hg (glob)
  deleting data/d3/f.i (reporevlogstore !)
  deleting meta/d3/00manifest.i (tree !)
  deleting data/d3/f/2661d26c649684b482d10f91960cc3db683c38b4 (reposimplestore !)
  deleting data/d3/f/99fa7136105a15e2045ce3d9152e4837c5349e4d (reposimplestore !)
  deleting data/d3/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg log -T '{desc}\n' -r .
  add d10/f
Updates to nullid if necessary
  $ hg tracked --addinclude d3 -q
  $ hg co null -q
  $ mkdir d3
  $ echo local change > d3/f
  $ hg add d3/f
  $ hg ci -m 'local change to d3'
  created new head
  $ hg tracked --removeinclude d3 --force-delete-local-changes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  * (glob)
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  moving unwanted changesets to backup
  saved backup bundle to $TESTTMP/narrow-local-changes/.hg/strip-backup/*-narrow.hg (glob)
  deleting data/d3/f.i (reporevlogstore !)
  deleting meta/d3/00manifest.i (tree !)
  deleting data/d3/f/2661d26c649684b482d10f91960cc3db683c38b4 (reposimplestore !)
  deleting data/d3/f/5ce0767945cbdbca3b924bb9fbf5143f72ab40ac (reposimplestore !)
  deleting data/d3/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg id
  000000000000
  $ cd ..

Narrowing doesn't resurrect old commits (unlike what regular `hg strip` does)
  $ hg clone --narrow ssh://user@dummy/master narrow-obsmarkers --include d0 --include d3 -q
  $ cd narrow-obsmarkers
  $ echo a >> d0/f2
  $ hg add d0/f2
  $ hg ci -m 'modify d0/'
  $ echo a >> d3/f2
  $ hg add d3/f2
  $ hg commit --amend -m 'modify d0/ and d3/'
  $ hg log -T "{rev}: {desc}\n"
  5: modify d0/ and d3/
  3: add d10/f
  2: add d3/f
  1: add d2/f
  0: add d0/f
  $ hg tracked --removeinclude d3 --force-delete-local-changes -q
  $ hg log -T "{rev}: {desc}\n"
  3: add d10/f
  2: add d3/f
  1: add d2/f
  0: add d0/f
  $ cd ..

Widening doesn't lose bookmarks
  $ hg clone --narrow ssh://user@dummy/master widen-bookmarks --include d0 -q
  $ cd widen-bookmarks
  $ hg bookmark my-bookmark
  $ hg log -T "{rev}: {desc} {bookmarks}\n"
  1: add d10/f my-bookmark
  0: add d0/f 
  $ hg tracked --addinclude d3 -q
  $ hg log -T "{rev}: {desc} {bookmarks}\n"
  3: add d10/f my-bookmark
  2: add d3/f 
  1: add d2/f 
  0: add d0/f 
  $ cd ..

Can remove last include, making repo empty
  $ hg clone --narrow ssh://user@dummy/master narrow-empty --include d0 -r 5
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 1 changes to 1 files
  new changesets *:* (glob)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd narrow-empty
  $ hg tracked --removeinclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  deleting data/d0/f.i (reporevlogstore !)
  deleting meta/d0/00manifest.i (tree !)
  deleting data/d0/f/362fef284ce2ca02aecc8de6d5e8a1c3af0556fe (reposimplestore !)
  deleting data/d0/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg tracked
  $ hg files
  [1]
  $ test -d d0
  [1]
Do some work in the empty clone
  $ hg diff --change .
  $ hg branch foo
  marked working directory as branch foo
  (branches are permanent and global, did you want a bookmark?)
  $ hg ci -m empty
  $ hg log -T "{rev}: {desc} {outsidenarrow}\n"
  2: empty 
  1: add d5/f outsidenarrow
  0: add d0/f outsidenarrow
  $ hg pull -q
Can widen the empty clone
  $ hg tracked --addinclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  saved backup bundle to $TESTTMP/narrow-empty/.hg/strip-backup/*-widen.hg (glob)
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 1 changes to 1 files (+1 heads)
  $ hg tracked
  I path:d0
  $ hg files
  d0/f
  $ find *
  d0
  d0/f
  $ cd ..

TODO(martinvonz): test including e.g. d3/g and then removing it once
https://bitbucket.org/Google/narrowhg/issues/6 is fixed

  $ hg clone --narrow ssh://user@dummy/master narrow --include d0 --include d3 --include d6 --include d9
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 4 changes to 4 files
  new changesets *:* (glob)
  updating to branch default
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd narrow
  $ hg tracked
  I path:d0
  I path:d3
  I path:d6
  I path:d9
  $ hg tracked --removeinclude d6
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  deleting data/d6/f.i (reporevlogstore !)
  deleting meta/d6/00manifest.i (tree !)
  deleting data/d6/f/7339d30678f451ac8c3f38753beeb4cf2e1655c7 (reposimplestore !)
  deleting data/d6/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg tracked
  I path:d0
  I path:d3
  I path:d9
#if repofncache
  $ hg debugrebuildfncache
  fncache already up to date
#endif
  $ find *
  d0
  d0/f
  d3
  d3/f
  d9
  d9/f
  $ hg verify -q
  $ hg tracked --addexclude d3/f
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  deleting data/d3/f.i (reporevlogstore !)
  deleting data/d3/f/2661d26c649684b482d10f91960cc3db683c38b4 (reposimplestore !)
  deleting data/d3/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg tracked
  I path:d0
  I path:d3
  I path:d9
  X path:d3/f
#if repofncache
  $ hg debugrebuildfncache
  fncache already up to date
#endif
  $ find *
  d0
  d0/f
  d9
  d9/f
  $ hg verify -q
  $ hg tracked --addexclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  deleting data/d0/f.i (reporevlogstore !)
  deleting meta/d0/00manifest.i (tree !)
  deleting data/d0/f/362fef284ce2ca02aecc8de6d5e8a1c3af0556fe (reposimplestore !)
  deleting data/d0/f/index (reposimplestore !)
  deleting unwanted files from working copy
  $ hg tracked
  I path:d3
  I path:d9
  X path:d0
  X path:d3/f
#if repofncache
  $ hg debugrebuildfncache
  fncache already up to date
#endif
  $ find *
  d9
  d9/f

Make a 15 of changes to d9 to test the path without --verbose
(Note: using regexes instead of "* (glob)" because if the test fails, it
produces more sensible diffs)
  $ hg tracked
  I path:d3
  I path:d9
  X path:d0
  X path:d3/f
  $ for x in `$TESTDIR/seq.py 1 15`
  > do
  >   echo local change >> d9/f
  >   hg commit -m "change $x to d9/f"
  > done
  $ hg tracked --removeinclude d9
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ...and 5 more, use --verbose to list all
  abort: local changes found
  (use --force-delete-local-changes to ignore)
  [20]
Now test it *with* verbose.
  $ hg tracked --removeinclude d9 --verbose
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  The following changeset(s) or their ancestors have local changes not on the remote:
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  ^[0-9a-f]{12}$ (re)
  abort: local changes found
  (use --force-delete-local-changes to ignore)
  [20]
  $ cd ..

Test --auto-remove-includes
  $ hg clone --narrow ssh://user@dummy/master narrow-auto-remove -q \
  > --include d0 --include d1 --include d2
  $ cd narrow-auto-remove
  $ echo a >> d0/f
  $ hg ci -m 'local change to d0'
  $ hg co '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo a >> d1/f
  $ hg ci -m 'local change to d1'
  created new head
  $ hg debugobsolete $(hg log -T '{node}' -r 'desc("local change to d0")')
  1 new obsolescence markers
  obsoleted 1 changesets
  $ echo n | hg tracked --auto-remove-includes --config ui.interactive=yes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for unused includes to remove
  path:d0
  path:d2
  remove these unused includes (yn)? n
  $ hg tracked --auto-remove-includes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for unused includes to remove
  path:d0
  path:d2
  remove these unused includes (yn)? y
  looking for local changes to affected paths
  moving unwanted changesets to backup
  saved backup bundle to $TESTTMP/narrow-auto-remove/.hg/strip-backup/*-narrow.hg (glob)
  deleting data/d0/f.i
  deleting data/d2/f.i
  deleting meta/d0/00manifest.i (tree !)
  deleting meta/d2/00manifest.i (tree !)
  deleting unwanted files from working copy
  $ hg tracked
  I path:d1
  $ hg files
  d1/f
  $ hg tracked --auto-remove-includes
  comparing with ssh://user@dummy/master
  searching for changes
  looking for unused includes to remove
  found no unused includes
Test --no-backup
  $ hg tracked --addinclude d0 --addinclude d2 -q
  $ hg unbundle .hg/strip-backup/*-narrow.hg -q
  $ rm .hg/strip-backup/*
  $ hg tracked --auto-remove-includes --no-backup
  comparing with ssh://user@dummy/master
  searching for changes
  looking for unused includes to remove
  path:d0
  path:d2
  remove these unused includes (yn)? y
  looking for local changes to affected paths
  deleting unwanted changesets
  deleting data/d0/f.i
  deleting data/d2/f.i
  deleting meta/d0/00manifest.i (tree !)
  deleting meta/d2/00manifest.i (tree !)
  deleting unwanted files from working copy
  $ ls .hg/strip-backup/


Test removing include while concurrently modifying file in that path
  $ hg clone --narrow ssh://user@dummy/master narrow-concurrent-modify -q \
  > --include d0 --include d1
  $ cd narrow-concurrent-modify
  $ hg --config 'hooks.pretxnopen = echo modified >> d0/f' tracked --removeinclude d0
  comparing with ssh://user@dummy/master
  searching for changes
  looking for local changes to affected paths
  deleting data/d0/f.i
  deleting meta/d0/00manifest.i (tree !)
  deleting unwanted files from working copy
  not deleting possibly dirty file d0/f
