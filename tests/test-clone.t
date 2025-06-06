Prepare repo a:

  $ hg init a
  $ cd a
  $ echo a > a
  $ hg add a
  $ hg commit -m test
  $ echo first line > b
  $ hg add b

Create a non-inlined filelog:

  $ "$PYTHON" -c 'open("data1", "wb").write(b"".join(b"%d\n" % x for x in range(10000)))'
  $ for j in 0 1 2 3 4 5 6 7 8 9; do
  >   cat data1 >> b
  >   hg commit -m test
  > done

List files in store/data (should show a 'b.d'):

  $ for i in .hg/store/data/*; do
  >   echo $i
  > done
  .hg/store/data/a.i
  .hg/store/data/b.d
  .hg/store/data/b.i

Trigger branchcache creation:

  $ hg branches
  default                       10:a7949464abda
  $ ls .hg/cache
  branch2-served
  rbc-names-v2
  rbc-revs-v2

Default operation:

  $ hg clone . ../b
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../b

Ensure branchcache got copied over:

  $ ls .hg/cache
  branch2-base
  branch2-served
  rbc-names-v2
  rbc-revs-v2
  tags2
  tags2-served

  $ cat a
  a
  $ hg verify -q

Invalid dest '' must abort:

  $ hg clone . ''
  abort: empty destination path is not valid
  [10]

No update, with debug option:

#if hardlink
  $ hg --debug clone -U . ../c --config progress.debug=true
  linking: 1/12 files (8.33%) (no-rust !)
  linking: 2/12 files (16.67%) (no-rust !)
  linking: 3/12 files (25.00%) (no-rust !)
  linking: 4/12 files (33.33%) (no-rust !)
  linking: 5/12 files (41.67%) (no-rust !)
  linking: 6/12 files (50.00%) (no-rust !)
  linking: 7/12 files (58.33%) (no-rust !)
  linking: 8/12 files (66.67%) (no-rust !)
  linking: 9/12 files (75.00%) (no-rust !)
  linking: 10/12 files (83.33%) (no-rust !)
  linking: 11/12 files (91.67%) (no-rust !)
  linking: 12/12 files (100.00%) (no-rust !)
  linked 12 files (no-rust !)
  linking: 1/14 files (7.14%) (rust !)
  linking: 2/14 files (14.29%) (rust !)
  linking: 3/14 files (21.43%) (rust !)
  linking: 4/14 files (28.57%) (rust !)
  linking: 5/14 files (35.71%) (rust !)
  linking: 6/14 files (42.86%) (rust !)
  linking: 7/14 files (50.00%) (rust !)
  linking: 8/14 files (57.14%) (rust !)
  linking: 9/14 files (64.29%) (rust !)
  linking: 10/14 files (71.43%) (rust !)
  linking: 11/14 files (78.57%) (rust !)
  linking: 12/14 files (85.71%) (rust !)
  linking: 13/14 files (92.86%) (rust !)
  linking: 14/14 files (100.00%) (rust !)
  linked 14 files (rust !)
  updating the branch cache
#else
  $ hg --debug clone -U . ../c --config progress.debug=true
  linking: 1 files
  copying: 2 files
  copying: 3 files
  copying: 4 files
  copying: 5 files
  copying: 6 files
  copying: 7 files
  copying: 8 files
#endif
  $ cd ../c

Ensure branchcache got copied over:

  $ ls .hg/cache
  branch2-base
  branch2-served
  rbc-names-v2
  rbc-revs-v2
  tags2
  tags2-served

  $ cat a 2>/dev/null || echo "a not present"
  a not present
  $ hg verify -q

Default destination:

  $ mkdir ../d
  $ cd ../d
  $ hg clone ../a
  destination directory: a
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd a
  $ hg cat a
  a
  $ cd ../..

Check that we drop the 'file:' from the path before writing the .hgrc:

  $ hg clone file:a e
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ grep 'file:' e/.hg/hgrc
  [1]

Check that path aliases are expanded:

  $ hg clone -q -U --config 'paths.foobar=a#0' foobar f
  $ hg -R f showconfig paths.default
  $TESTTMP/a#0

Use --pull:

  $ hg clone --pull a g
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 11 changesets with 11 changes to 2 files
  new changesets acb14030fe0a:a7949464abda
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R g verify -q

Invalid dest '' with --pull must abort (issue2528):

  $ hg clone --pull a ''
  abort: empty destination path is not valid
  [10]

Clone to '.':

  $ mkdir h
  $ cd h
  $ hg clone ../a .
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ..


*** Tests for option -u ***

Adding some more history to repo a:

  $ cd a
  $ hg tag ref1
  $ echo the quick brown fox >a
  $ hg ci -m "hacked default"
  $ hg up ref1
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg branch stable
  marked working directory as branch stable
  (branches are permanent and global, did you want a bookmark?)
  $ echo some text >a
  $ hg ci -m "starting branch stable"
  $ hg tag ref2
  $ echo some more text >a
  $ hg ci -m "another change for branch stable"
  $ hg up ref2
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg parents
  changeset:   13:e8ece76546a6
  branch:      stable
  tag:         ref2
  parent:      10:a7949464abda
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     starting branch stable
  

Repo a has two heads:

  $ hg heads
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

  $ cd ..


Testing --noupdate with --updaterev (must abort):

  $ hg clone --noupdate --updaterev 1 a ua
  abort: cannot specify both --noupdate and --updaterev
  [10]


Testing clone -u:

  $ hg clone -u . a ua
  updating to branch stable
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has both heads:

  $ hg -R ua heads
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

Same revision checked out in repo a and ua:

  $ hg -R a parents --template "{node|short}\n"
  e8ece76546a6
  $ hg -R ua parents --template "{node|short}\n"
  e8ece76546a6

  $ rm -r ua


Testing clone --pull -u:

  $ hg clone --pull -u . a ua
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 16 changesets with 16 changes to 3 files (+1 heads)
  new changesets acb14030fe0a:0aae7cf88f0d
  updating to branch stable
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has both heads:

  $ hg -R ua heads
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

Same revision checked out in repo a and ua:

  $ hg -R a parents --template "{node|short}\n"
  e8ece76546a6
  $ hg -R ua parents --template "{node|short}\n"
  e8ece76546a6

  $ rm -r ua


Testing clone -u <branch>:

  $ hg clone -u stable a ua
  updating to branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has both heads:

  $ hg -R ua heads
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

Branch 'stable' is checked out:

  $ hg -R ua parents
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  

  $ rm -r ua


Testing default checkout:

  $ hg clone a ua
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has both heads:

  $ hg -R ua heads
  changeset:   15:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

Branch 'default' is checked out:

  $ hg -R ua parents
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  
Test clone with a branch named "@" (issue3677)

  $ hg -R ua branch @
  marked working directory as branch @
  $ hg -R ua commit -m 'created branch @'
  $ hg clone ua atbranch
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R atbranch heads
  changeset:   16:798b6d97153e
  branch:      @
  tag:         tip
  parent:      12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     created branch @
  
  changeset:   15:0aae7cf88f0d
  branch:      stable
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  
  $ hg -R atbranch parents
  changeset:   12:f21241060d6a
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     hacked default
  

  $ rm -r ua atbranch


Testing #<branch>:

  $ hg clone -u . a#stable ua
  adding changesets
  adding manifests
  adding file changes
  added 14 changesets with 14 changes to 3 files
  new changesets acb14030fe0a:0aae7cf88f0d
  updating to branch stable
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has branch 'stable' and 'default' (was changed in fd511e9eeea6):

  $ hg -R ua heads
  changeset:   13:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   10:a7949464abda
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     test
  

Same revision checked out in repo a and ua:

  $ hg -R a parents --template "{node|short}\n"
  e8ece76546a6
  $ hg -R ua parents --template "{node|short}\n"
  e8ece76546a6

  $ rm -r ua


Testing -u -r <branch>:

  $ hg clone -u . -r stable a ua
  adding changesets
  adding manifests
  adding file changes
  added 14 changesets with 14 changes to 3 files
  new changesets acb14030fe0a:0aae7cf88f0d
  updating to branch stable
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has branch 'stable' and 'default' (was changed in fd511e9eeea6):

  $ hg -R ua heads
  changeset:   13:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   10:a7949464abda
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     test
  

Same revision checked out in repo a and ua:

  $ hg -R a parents --template "{node|short}\n"
  e8ece76546a6
  $ hg -R ua parents --template "{node|short}\n"
  e8ece76546a6

  $ rm -r ua


Testing -r <branch>:

  $ hg clone -r stable a ua
  adding changesets
  adding manifests
  adding file changes
  added 14 changesets with 14 changes to 3 files
  new changesets acb14030fe0a:0aae7cf88f0d
  updating to branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Repo ua has branch 'stable' and 'default' (was changed in fd511e9eeea6):

  $ hg -R ua heads
  changeset:   13:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  
  changeset:   10:a7949464abda
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     test
  

Branch 'stable' is checked out:

  $ hg -R ua parents
  changeset:   13:0aae7cf88f0d
  branch:      stable
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     another change for branch stable
  

  $ rm -r ua


Issue2267: Error in 1.6 hg.py: TypeError: 'NoneType' object is not
iterable in addbranchrevs()

  $ cat <<EOF > simpleclone.py
  > from mercurial import hg, ui as uimod
  > myui = uimod.ui.load()
  > repo = hg.repository(myui, b'a')
  > hg.clone(myui, {}, repo, dest=b"ua")
  > EOF

  $ "$PYTHON" simpleclone.py
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ rm -r ua

  $ cat <<EOF > branchclone.py
  > from mercurial import extensions, hg, ui as uimod
  > myui = uimod.ui.load()
  > extensions.loadall(myui)
  > extensions.populateui(myui)
  > repo = hg.repository(myui, b'a')
  > hg.clone(myui, {}, repo, dest=b"ua", branch=[b"stable"])
  > EOF

  $ "$PYTHON" branchclone.py
  adding changesets
  adding manifests
  adding file changes
  added 14 changesets with 14 changes to 3 files
  new changesets acb14030fe0a:0aae7cf88f0d
  updating to branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ rm -r ua

Local clones don't get confused by unusual experimental.evolution options

  $ hg clone \
  >   --config experimental.evolution=allowunstable,allowdivergence,exchange \
  >   a ua
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ rm -r ua

  $ hg clone \
  >   --config experimental.evolution.createmarkers=no \
  >   --config experimental.evolution.allowunstable=yes \
  >   --config experimental.evolution.allowdivergence=yes \
  >   --config experimental.evolution.exchange=yes \
  >   a ua
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ rm -r ua

Test clone with special '@' bookmark:
  $ cd a
  $ hg bookmark -r a7949464abda @  # branch point of stable from default
  $ hg clone . ../i
  updating to bookmark @
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg id -i ../i
  a7949464abda
  $ rm -r ../i

  $ hg bookmark -f -r stable @
  $ hg bookmarks
     @                         15:0aae7cf88f0d
  $ hg clone . ../i
  updating to bookmark @ on branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg id -i ../i
  0aae7cf88f0d
  $ cd "$TESTTMP"


Testing failures:

  $ mkdir fail
  $ cd fail

No local source

  $ hg clone a b
  abort: repository a not found
  [255]

Invalid URL

  $ hg clone http://invalid:url/a b
  abort: error: nonnumeric port: 'url'
  [100]

No remote source

  $ hg clone http://$LOCALIP:3121/a b
  abort: error: $ECONNREFUSED$
  [100]

  $ rm -rf b # work around bug with http clone


#if unix-permissions no-root

Inaccessible source

  $ mkdir a
  $ chmod 000 a
  $ hg clone a b
  abort: $EACCES$: *$TESTTMP/fail/a/.hg* (glob)
  [255]

Inaccessible destination

  $ hg init b
  $ cd b
  $ hg clone . ../a
  abort: $EACCES$: *../a* (glob)
  [255]
  $ cd ..
  $ chmod 700 a
  $ rm -r a b

#endif


#if fifo

Source of wrong type

  $ mkfifo a
  $ hg clone a b
  abort: $ENOTDIR$: *$TESTTMP/fail/a/.hg* (glob)
  [255]
  $ rm a

#endif

Default destination, same directory

  $ hg init q
  $ hg clone q
  destination directory: q
  abort: destination 'q' is not empty
  [10]

destination directory not empty

  $ mkdir a
  $ echo stuff > a/a
  $ hg clone q a
  abort: destination 'a' is not empty
  [10]


#if unix-permissions no-root

leave existing directory in place after clone failure

  $ hg init c
  $ cd c
  $ echo c > c
  $ hg commit -A -m test
  adding c
  $ chmod -rx .hg/store/data
  $ cd ..
  $ mkdir d
  $ hg clone c d 2> err
  [255]
  $ test -d d
  $ test -d d/.hg
  [1]

re-enable perm to allow deletion

  $ chmod +rx c/.hg/store/data

#endif

  $ cd ..

Test clone from the repository in (emulated) revlog format 0 (issue4203):

  $ mkdir issue4203
  $ mkdir -p src/.hg
  $ echo foo > src/foo
  $ hg -R src add src/foo
  $ hg -R src commit -m '#0'
  $ hg -R src log -q
  0:e1bab28bca43
  $ hg -R src debugrevlog -c | grep -E 'format|flags'
  format : 0
  flags  : (none)
  $ hg root -R src -T json | sed 's|\\\\|\\|g'
  [
   {
    "hgpath": "$TESTTMP/src/.hg",
    "reporoot": "$TESTTMP/src",
    "storepath": "$TESTTMP/src/.hg"
   }
  ]
  $ hg clone -U -q src dst
  $ hg -R dst log -q
  0:e1bab28bca43

Create repositories to test auto sharing functionality

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > share=
  > EOF

  $ hg init empty
  $ hg init source1a
  $ cd source1a
  $ echo initial1 > foo
  $ hg -q commit -A -m initial
  $ echo second > foo
  $ hg commit -m second
  $ cd ..

  $ hg init filteredrev0
  $ cd filteredrev0
  $ cat >> .hg/hgrc << EOF
  > [experimental]
  > evolution.createmarkers=True
  > EOF
  $ echo initial1 > foo
  $ hg -q commit -A -m initial0
  $ hg -q up -r null
  $ echo initial2 > foo
  $ hg -q commit -A -m initial1
  $ hg debugobsolete c05d5c47a5cf81401869999f3d05f7d699d2b29a e082c1832e09a7d1e78b7fd49a592d372de854c8
  1 new obsolescence markers
  obsoleted 1 changesets
  $ cd ..

  $ hg -q clone --pull source1a source1b
  $ cd source1a
  $ hg bookmark bookA
  $ echo 1a > foo
  $ hg commit -m 1a
  $ cd ../source1b
  $ hg -q up -r 0
  $ echo head1 > foo
  $ hg commit -m head1
  created new head
  $ hg bookmark head1
  $ hg -q up -r 0
  $ echo head2 > foo
  $ hg commit -m head2
  created new head
  $ hg bookmark head2
  $ hg -q up -r 0
  $ hg branch branch1
  marked working directory as branch branch1
  (branches are permanent and global, did you want a bookmark?)
  $ echo branch1 > foo
  $ hg commit -m branch1
  $ hg -q up -r 0
  $ hg branch branch2
  marked working directory as branch branch2
  $ echo branch2 > foo
  $ hg commit -m branch2
  $ cd ..
  $ hg init source2
  $ cd source2
  $ echo initial2 > foo
  $ hg -q commit -A -m initial2
  $ echo second > foo
  $ hg commit -m second
  $ cd ..

Clone with auto share from an empty repo should not result in share

  $ mkdir share
  $ hg --config share.pool=share clone empty share-empty
  (not using pooled storage: remote appears to be empty)
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ ls share
  $ test -d share-empty/.hg/store
  $ test -f share-empty/.hg/sharedpath
  [1]

Clone with auto share from a repo with filtered revision 0 should not result in share

  $ hg --config share.pool=share clone filteredrev0 share-filtered
  (not using pooled storage: unable to resolve identity of remote)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets e082c1832e09
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Clone from repo with content should result in shared store being created

  $ hg --config share.pool=share clone source1a share-dest1a
  (sharing from new pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  new changesets b5f04eac9d8f:e5bfe23c0b47
  searching for changes
  no changes found
  adding remote bookmark bookA
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

The shared repo should have been created

  $ ls share
  b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1

The destination should point to it

  $ cat share-dest1a/.hg/sharedpath; echo
  $TESTTMP/share/b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1/.hg

The destination should have bookmarks

  $ hg -R share-dest1a bookmarks
     bookA                     2:e5bfe23c0b47

The default path should be the remote, not the share

  $ hg -R share-dest1a config paths.default
  $TESTTMP/source1a

Clone with existing share dir should result in pull + share

  $ hg --config share.pool=share clone source1b share-dest1b
  (sharing from existing pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark head1
  adding remote bookmark head2
  added 4 changesets with 4 changes to 1 files (+4 heads)
  new changesets 4a8dc1ab4c13:6bacf4683960
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ ls share
  b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1

  $ cat share-dest1b/.hg/sharedpath; echo
  $TESTTMP/share/b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1/.hg

We only get bookmarks from the remote, not everything in the share

  $ hg -R share-dest1b bookmarks
     head1                     3:4a8dc1ab4c13
     head2                     4:99f71071f117

Default path should be source, not share.

  $ hg -R share-dest1b config paths.default
  $TESTTMP/source1b

Checked out revision should be head of default branch

  $ hg -R share-dest1b log -r .
  changeset:   4:99f71071f117
  bookmark:    head2
  parent:      0:b5f04eac9d8f
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     head2
  

Clone from unrelated repo should result in new share

  $ hg --config share.pool=share clone source2 share-dest2
  (sharing from new pooled repository 22aeff664783fd44c6d9b435618173c118c3448e)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets 22aeff664783:63cf6c3dba4a
  searching for changes
  no changes found
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ ls share
  22aeff664783fd44c6d9b435618173c118c3448e
  b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1

remote naming mode works as advertised

  $ hg --config share.pool=shareremote --config share.poolnaming=remote clone source1a share-remote1a
  (sharing from new pooled repository 195bb1fcdb595c14a6c13e0269129ed78f6debde)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  new changesets b5f04eac9d8f:e5bfe23c0b47
  searching for changes
  no changes found
  adding remote bookmark bookA
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ ls shareremote
  195bb1fcdb595c14a6c13e0269129ed78f6debde

  $ hg --config share.pool=shareremote --config share.poolnaming=remote clone source1b share-remote1b
  (sharing from new pooled repository c0d4f83847ca2a873741feb7048a45085fd47c46)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 6 changes to 1 files (+4 heads)
  new changesets b5f04eac9d8f:6bacf4683960
  searching for changes
  no changes found
  adding remote bookmark head1
  adding remote bookmark head2
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ ls shareremote
  195bb1fcdb595c14a6c13e0269129ed78f6debde
  c0d4f83847ca2a873741feb7048a45085fd47c46

request to clone a single revision is respected in sharing mode

  $ hg --config share.pool=sharerevs clone -r 4a8dc1ab4c13 source1b share-1arev
  (sharing from new pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets b5f04eac9d8f:4a8dc1ab4c13
  no changes found
  adding remote bookmark head1
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg -R share-1arev log -G
  @  changeset:   1:4a8dc1ab4c13
  |  bookmark:    head1
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     head1
  |
  o  changeset:   0:b5f04eac9d8f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  

making another clone should only pull down requested rev

  $ hg --config share.pool=sharerevs clone -r 99f71071f117 source1b share-1brev
  (sharing from existing pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark head1
  adding remote bookmark head2
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets 99f71071f117
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg -R share-1brev log -G
  @  changeset:   2:99f71071f117
  |  bookmark:    head2
  |  tag:         tip
  |  parent:      0:b5f04eac9d8f
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     head2
  |
  | o  changeset:   1:4a8dc1ab4c13
  |/   bookmark:    head1
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     head1
  |
  o  changeset:   0:b5f04eac9d8f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  

Request to clone a single branch is respected in sharing mode

  $ hg --config share.pool=sharebranch clone -b branch1 source1b share-1bbranch1
  (sharing from new pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets b5f04eac9d8f:5f92a6c1a1b1
  no changes found
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg -R share-1bbranch1 log -G
  o  changeset:   1:5f92a6c1a1b1
  |  branch:      branch1
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     branch1
  |
  @  changeset:   0:b5f04eac9d8f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  

  $ hg --config share.pool=sharebranch clone -b branch2 source1b share-1bbranch2
  (sharing from existing pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets 6bacf4683960
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg -R share-1bbranch2 log -G
  o  changeset:   2:6bacf4683960
  |  branch:      branch2
  |  tag:         tip
  |  parent:      0:b5f04eac9d8f
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     branch2
  |
  | o  changeset:   1:5f92a6c1a1b1
  |/   branch:      branch1
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     branch1
  |
  @  changeset:   0:b5f04eac9d8f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  

-U is respected in share clone mode

  $ hg --config share.pool=share clone -U source1a share-1anowc
  (sharing from existing pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  searching for changes
  no changes found
  adding remote bookmark bookA

  $ ls -A share-1anowc
  .hg

Test that auto sharing doesn't cause failure of "hg clone local remote"

  $ cd $TESTTMP
  $ hg -R a id -r 0
  acb14030fe0a
  $ hg id -R remote -r 0
  abort: repository remote not found
  [255]
  $ hg --config share.pool=share -q clone a ssh://user@dummy/remote
  $ hg -R remote id -r 0
  acb14030fe0a

Cloning into pooled storage doesn't race (issue5104)

  $ HGPOSTLOCKDELAY=2.0 hg --config share.pool=racepool --config extensions.lockdelay=$TESTDIR/lockdelay.py clone source1a share-destrace1 > race1.log 2>&1 &
  $ HGPRELOCKDELAY=1.0 hg --config share.pool=racepool --config extensions.lockdelay=$TESTDIR/lockdelay.py clone source1a share-destrace2  > race2.log 2>&1
  $ wait

  $ hg -R share-destrace1 log -r tip
  changeset:   2:e5bfe23c0b47
  bookmark:    bookA
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1a
  

  $ hg -R share-destrace2 log -r tip
  changeset:   2:e5bfe23c0b47
  bookmark:    bookA
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1a
  
One repo should be new, the other should be shared from the pool. We
don't care which is which, so we just make sure we always print the
one containing "new pooled" first, then one one containing "existing
pooled".

  $ (grep 'new pooled' race1.log > /dev/null && cat race1.log || cat race2.log) | grep -v lock
  (sharing from new pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  new changesets b5f04eac9d8f:e5bfe23c0b47
  searching for changes
  no changes found
  adding remote bookmark bookA
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ (grep 'existing pooled' race1.log > /dev/null && cat race1.log || cat race2.log) | grep -v lock
  (sharing from existing pooled repository b5f04eac9d8f7a6a9fcb070243cccea7dc5ea0c1)
  searching for changes
  no changes found
  adding remote bookmark bookA
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

SEC: check for unsafe ssh url

  $ cat >> $HGRCPATH << EOF
  > [ui]
  > ssh = sh -c "read l; read l; read l"
  > EOF

  $ hg clone 'ssh://-oProxyCommand=touch${IFS}owned/path'
  abort: potentially unsafe url: 'ssh://-oProxyCommand=touch${IFS}owned/path'
  [255]
  $ hg clone 'ssh://%2DoProxyCommand=touch${IFS}owned/path'
  abort: potentially unsafe url: 'ssh://-oProxyCommand=touch${IFS}owned/path'
  [255]
  $ hg clone 'ssh://fakehost|touch%20owned/path'
  abort: no suitable response from remote hg
  [255]
  $ hg clone 'ssh://fakehost%7Ctouch%20owned/path'
  abort: no suitable response from remote hg
  [255]

  $ hg clone 'ssh://-oProxyCommand=touch owned%20foo@example.com/nonexistent/path'
  abort: potentially unsafe url: 'ssh://-oProxyCommand=touch owned foo@example.com/nonexistent/path'
  [255]

#if windows
  $ hg clone "ssh://%26touch%20owned%20/" --debug
  running sh -c "read l; read l; read l" "&touch owned " "hg -R . serve --stdio"
  sending hello command
  sending between command
  abort: no suitable response from remote hg
  [255]
  $ hg clone "ssh://example.com:%26touch%20owned%20/" --debug
  running sh -c "read l; read l; read l" -p "&touch owned " example.com "hg -R . serve --stdio"
  sending hello command
  sending between command
  abort: no suitable response from remote hg
  [255]
#else
  $ hg clone "ssh://%3btouch%20owned%20/" --debug
  running sh -c "read l; read l; read l" ';touch owned ' 'hg -R . serve --stdio'
  sending hello command
  sending between command
  abort: no suitable response from remote hg
  [255]
  $ hg clone "ssh://example.com:%3btouch%20owned%20/" --debug
  running sh -c "read l; read l; read l" -p ';touch owned ' example.com 'hg -R . serve --stdio'
  sending hello command
  sending between command
  abort: no suitable response from remote hg
  [255]
#endif

  $ hg clone "ssh://v-alid.example.com/" --debug
  running sh -c "read l; read l; read l" v-alid\.example\.com ['"]hg -R \. serve --stdio['"] (re)
  sending hello command
  sending between command
  abort: no suitable response from remote hg
  [255]

We should not have created a file named owned - if it exists, the
attack succeeded.
  $ if test -f owned; then echo 'you got owned'; fi

Cloning without fsmonitor enabled does not print a warning for small repos

  $ hg clone a fsmonitor-default
  updating to bookmark @ on branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Lower the warning threshold to simulate a large repo

  $ cat >> $HGRCPATH << EOF
  > [fsmonitor]
  > warn_update_file_count = 2
  > warn_update_file_count_rust = 2
  > EOF

We should see a warning about no fsmonitor on supported platforms

#if linuxormacos no-fsmonitor
  $ hg clone a nofsmonitor
  updating to bookmark @ on branch stable
  (warning: large working directory being used without fsmonitor enabled; enable fsmonitor to improve performance; see "hg help -e fsmonitor") (no-rust !)
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#else
  $ hg clone a nofsmonitor
  updating to bookmark @ on branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif

We should not see warning about fsmonitor when it is enabled

#if fsmonitor
  $ hg clone a fsmonitor-enabled
  updating to bookmark @ on branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif

We can disable the fsmonitor warning

  $ hg --config fsmonitor.warn_when_unused=false clone a fsmonitor-disable-warning
  updating to bookmark @ on branch stable
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Loaded fsmonitor but disabled in config should still print warning

#if linuxormacos fsmonitor
  $ hg --config fsmonitor.mode=off clone a fsmonitor-mode-off
  updating to bookmark @ on branch stable
  (warning: large working directory being used without fsmonitor enabled; enable fsmonitor to improve performance; see "hg help -e fsmonitor") (fsmonitor !)
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif

Warning not printed if working directory isn't empty

  $ hg -q clone a fsmonitor-update
  (warning: large working directory being used without fsmonitor enabled; enable fsmonitor to improve performance; see "hg help -e fsmonitor") (?)
  $ cd fsmonitor-update
  $ hg up acb14030fe0a
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  (leaving bookmark @)
  $ hg up cf0fe1914066
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

`hg update` from null revision also prints

  $ hg up null
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved

#if linuxormacos no-fsmonitor
  $ hg up cf0fe1914066
  (warning: large working directory being used without fsmonitor enabled; enable fsmonitor to improve performance; see "hg help -e fsmonitor") (no-rust !)
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
#else
  $ hg up cf0fe1914066
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif

  $ cd ..

