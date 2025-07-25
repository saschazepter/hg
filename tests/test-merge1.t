  $ cat <<EOF > merge
  > import sys, os
  > 
  > try:
  >     import msvcrt
  >     msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
  >     msvcrt.setmode(sys.stderr.fileno(), os.O_BINARY)
  > except ImportError:
  >     pass
  > 
  > print("merging for", os.path.basename(sys.argv[1]))
  > EOF
  $ HGMERGE="\"$PYTHON\" ../merge"; export HGMERGE

  $ hg init t
  $ cd t
  $ echo This is file a1 > a
  $ hg add a
  $ hg commit -m "commit #0"
  $ echo This is file b1 > b
  $ hg add b
  $ hg commit -m "commit #1"

  $ hg update 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved

Test interrupted updates by having a non-empty dir with the same name as one
of the files in a commit we're updating to

  $ mkdir b && touch b/nonempty
  $ hg up
  abort: Unlinking directory not permitted: *$TESTTMP/t/b* (glob) (windows !)
  abort: Directory not empty: '?\$TESTTMP/t/b'? (re) (no-windows no-rust !)
  abort: conflicting unknown directory '$TESTTMP/t/b' is not empty (no-windows rust !)
  [255]
  $ hg ci
  abort: last update was interrupted
  (use 'hg update' to get a consistent checkout)
  [20]
  $ hg sum
  parent: 0:538afb845929 
   commit #0
  branch: default
  commit: 1 unknown (interrupted update)
  update: 1 new changesets (update)
  phases: 2 draft
Detect interrupted update by hg status --verbose
  $ hg status -v
  ? b/nonempty
  # The repository is in an unfinished *update* state.
  
  # To continue:    hg update .
  

  $ rm b/nonempty

  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg sum
  parent: 1:b8bb4a988f25 tip
   commit #1
  branch: default
  commit: (clean)
  update: (current)
  phases: 2 draft

Prepare a basic merge

  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo This is file c1 > c
  $ hg add c
  $ hg commit -m "commit #2"
  created new head
  $ echo This is file b1 > b
no merges expected
  $ hg merge -P 1
  changeset:   1:b8bb4a988f25
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #1
  
  $ hg merge 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg diff --nodates
  diff -r 49035e18a8e6 b
  --- /dev/null
  +++ b/b
  @@ -0,0 +1,1 @@
  +This is file b1
  $ hg status
  M b
  $ cd ..; rm -r t

  $ hg init t
  $ cd t
  $ echo This is file a1 > a
  $ hg add a
  $ hg commit -m "commit #0"
  $ echo This is file b1 > b
  $ hg add b
  $ hg commit -m "commit #1"

  $ hg update 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo This is file c1 > c
  $ hg add c
  $ hg commit -m "commit #2"
  created new head
  $ echo This is file b2 > b
merge should fail
  $ hg merge 1
  b: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]

#if symlink
symlinks to directories should be treated as regular files (issue5027)
  $ rm b
  $ ln -s 'This is file b2' b
  $ hg merge 1
  b: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]
symlinks shouldn't be followed
  $ rm b
  $ echo This is file b1 > .hg/b
  $ ln -s .hg/b b
  $ hg merge 1
  b: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]

  $ rm b
  $ echo This is file b2 > b
#endif

bad config
  $ hg merge 1 --config merge.checkunknown=x
  config error: merge.checkunknown not valid ('x' is none of 'abort', 'ignore', 'warn')
  [30]
this merge should fail
  $ hg merge 1 --config merge.checkunknown=abort
  b: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]

this merge should warn
  $ hg merge 1 --config merge.checkunknown=warn
  b: replacing untracked file
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ cat b.orig
  This is file b2
  $ hg up --clean 2
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mv b.orig b

this merge should silently ignore
  $ cat b
  This is file b2
  $ hg merge 1 --config merge.checkunknown=ignore
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

merge.checkignored
  $ hg up --clean 1
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ cat >> .hgignore << EOF
  > remoteignored
  > EOF
  $ echo This is file localignored3 > localignored
  $ echo This is file remoteignored3 > remoteignored
  $ hg add .hgignore localignored remoteignored
  $ hg commit -m "commit #3"

  $ hg up 2
  1 files updated, 0 files merged, 4 files removed, 0 files unresolved
  $ cat >> .hgignore << EOF
  > localignored
  > EOF
  $ hg add .hgignore
  $ hg commit -m "commit #4"

remote .hgignore shouldn't be used for determining whether a file is ignored
  $ echo This is file remoteignored4 > remoteignored
  $ hg merge 3 --config merge.checkignored=ignore --config merge.checkunknown=abort
  remoteignored: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]
  $ hg merge 3 --config merge.checkignored=abort --config merge.checkunknown=ignore
  merging .hgignore
  merging for .hgignore
  3 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ cat remoteignored
  This is file remoteignored3
  $ cat remoteignored.orig
  This is file remoteignored4
  $ rm remoteignored.orig

local .hgignore should be used for that
  $ hg up --clean 4
  1 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ echo This is file localignored4 > localignored
also test other conflicting files to see we output the full set of warnings
  $ echo This is file b2 > b
  $ hg merge 3 --config merge.checkignored=abort --config merge.checkunknown=abort
  b: untracked file differs
  localignored: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]
  $ hg merge 3 --config merge.checkignored=abort --config merge.checkunknown=ignore
  localignored: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]
  $ hg merge 3 --config merge.checkignored=warn --config merge.checkunknown=abort
  b: untracked file differs
  abort: untracked files in working directory differ from files in requested revision
  [20]
  $ hg merge 3 --config merge.checkignored=warn --config merge.checkunknown=warn
  b: replacing untracked file
  localignored: replacing untracked file
  merging .hgignore
  merging for .hgignore
  3 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ cat localignored
  This is file localignored3
  $ cat localignored.orig
  This is file localignored4
  $ rm localignored.orig

  $ cat b.orig
  This is file b2
  $ hg up --clean 2
  0 files updated, 0 files merged, 4 files removed, 0 files unresolved
  $ mv b.orig b

this merge of b should work
  $ cat b
  This is file b2
  $ hg merge -f 1
  merging b
  merging for b
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg diff --nodates
  diff -r 49035e18a8e6 b
  --- /dev/null
  +++ b/b
  @@ -0,0 +1,1 @@
  +This is file b2
  $ hg status
  M b
  $ cd ..; rm -r t

  $ hg init t
  $ cd t
  $ echo This is file a1 > a
  $ hg add a
  $ hg commit -m "commit #0"
  $ echo This is file b1 > b
  $ hg add b
  $ hg commit -m "commit #1"
  $ echo This is file b22 > b
  $ hg commit -m "commit #2"
  $ hg update 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo This is file c1 > c
  $ hg add c
  $ hg commit -m "commit #3"
  created new head

Contents of b should be "this is file b1"
  $ cat b
  This is file b1

  $ echo This is file b22 > b
merge fails
  $ hg merge 2
  abort: uncommitted changes
  (use 'hg status' to list changes)
  [20]
merge expected!
  $ hg merge -f 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg diff --nodates
  diff -r 85de557015a8 b
  --- a/b
  +++ b/b
  @@ -1,1 +1,1 @@
  -This is file b1
  +This is file b22
  $ hg status
  M b
  $ cd ..; rm -r t

  $ hg init t
  $ cd t
  $ echo This is file a1 > a
  $ hg add a
  $ hg commit -m "commit #0"
  $ echo This is file b1 > b
  $ hg add b
  $ hg commit -m "commit #1"
  $ echo This is file b22 > b
  $ hg commit -m "commit #2"
  $ hg update 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo This is file c1 > c
  $ hg add c
  $ hg commit -m "commit #3"
  created new head
  $ echo This is file b33 > b
merge of b should fail
  $ hg merge 2
  abort: uncommitted changes
  (use 'hg status' to list changes)
  [20]
merge of b expected
  $ hg merge -f 2
  merging b
  merging for b
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg diff --nodates
  diff -r 85de557015a8 b
  --- a/b
  +++ b/b
  @@ -1,1 +1,1 @@
  -This is file b1
  +This is file b33
  $ hg status
  M b

Test for issue2364

  $ hg up -qC .
  $ hg rm b
  $ hg ci -md
  $ hg revert -r -2 b
  $ hg up -q -- -2

Test that updated files are treated as "modified", when
'merge.update()' is aborted before 'merge.recordupdates()' (= parents
aren't changed), even if none of mode, size and timestamp of them
isn't changed on the filesystem (see also issue4583).

This test is now "best effort" as the mechanism to prevent such race are
getting better, it get more complicated to test a specific scenario that would
trigger it. If you see flakyness here, there is a race.

  $ cat > $TESTTMP/abort.py <<EOF
  > # emulate aborting before "recordupdates()". in this case, files
  > # are changed without updating dirstate
  > from mercurial import (
  >   error,
  >   extensions,
  >   merge,
  > )
  > def applyupdates(orig, *args, **kwargs):
  >     orig(*args, **kwargs)
  >     raise error.Abort(b'intentional aborting')
  > def extsetup(ui):
  >     extensions.wrapfunction(merge, "applyupdates", applyupdates)
  > EOF

(file gotten from other revision)

  $ hg update -q -C 2
  $ echo 'THIS IS FILE B5' > b
  $ hg commit -m 'commit #5'

  $ hg update -q -C 3
  $ cat b
  This is file b1
  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > abort = $TESTTMP/abort.py
  > EOF
  $ hg merge 5
  abort: intentional aborting
  [255]
  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > abort = !
  > EOF

  $ cat b
  THIS IS FILE B5
  $ hg status -A b
  M b

(file merged from other revision)

  $ hg update -q -C 3
  $ echo 'this is file b6' > b
  $ hg commit -m 'commit #6'
  created new head

  $ cat b
  this is file b6
  $ hg status

  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > abort = $TESTTMP/abort.py
  > EOF
  $ hg merge --tool internal:other 5
  abort: intentional aborting
  [255]
  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > abort = !
  > EOF

  $ cat b
  THIS IS FILE B5
  $ hg status -A b
  M b

  $ cd ..
