  $ cat >> $HGRCPATH <<EOF
  > [commands]
  > status.verbose=1
  > EOF

# Construct the following history tree:
#
# @  5:e1bb631146ca  b1
# |
# o  4:a4fdb3b883c4 0:b608b9236435  b1
# |
# | o  3:4b57d2520816 1:44592833ba9f
# | |
# | | o  2:063f31070f65
# | |/
# | o  1:44592833ba9f
# |/
# o  0:b608b9236435

  $ mkdir b1
  $ cd b1
  $ hg init
  $ echo foo > foo
  $ echo zero > a
  $ hg init sub
  $ echo suba > sub/suba
  $ hg --cwd sub ci -Am addsuba
  adding suba
  $ echo 'sub = sub' > .hgsub
  $ hg ci -qAm0
  $ echo one > a ; hg ci -m1
  $ echo two > a ; hg ci -m2
  $ hg up -q 1
  $ echo three > a ; hg ci -qm3
  $ hg up -q 0
  $ hg branch -q b1
  $ echo four > a ; hg ci -qm4
  $ echo five > a ; hg ci -qm5

Initial repo state:

  $ hg log -G --template '{rev}:{node|short} {parents} {branches}\n'
  @  5:ff252e8273df  b1
  |
  o  4:d047485b3896 0:60829823a42a  b1
  |
  | o  3:6efa171f091b 1:0786582aa4b1
  | |
  | | o  2:bd10386d478c
  | |/
  | o  1:0786582aa4b1
  |/
  o  0:60829823a42a
  

Make sure update doesn't assume b1 is a repository if invoked from outside:

  $ cd ..
  $ hg update b1
  abort: no repository found in '$TESTTMP' (.hg not found)
  [10]
  $ cd b1

Test helper functions:

  $ revtest () {
  >     msg=$1
  >     dirtyflag=$2   # 'clean', 'dirty' or 'dirtysub'
  >     startrev=$3
  >     targetrev=$4
  >     opt=$5
  >     hg up -qC $startrev
  >     test $dirtyflag = dirty && echo dirty > foo
  >     test $dirtyflag = dirtysub && echo dirty > sub/suba
  >     hg up $opt $targetrev
  >     hg parent --template 'parent={rev}\n'
  >     hg stat -S
  > }

  $ norevtest () {
  >     msg=$1
  >     dirtyflag=$2   # 'clean', 'dirty' or 'dirtysub'
  >     startrev=$3
  >     opt=$4
  >     hg up -qC $startrev
  >     test $dirtyflag = dirty && echo dirty > foo
  >     test $dirtyflag = dirtysub && echo dirty > sub/suba
  >     hg up $opt
  >     hg parent --template 'parent={rev}\n'
  >     hg stat -S
  > }

Test cases are documented in a table in the update function of merge.py.
Cases are run as shown in that table, row by row.

  $ norevtest 'none clean linear' clean 4
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=5

  $ norevtest 'none clean same'   clean 2
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "bd10386d478c: 2"
  1 other heads for branch "default"
  parent=2


  $ revtest 'none clean linear' clean 1 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

  $ revtest 'none clean same'   clean 2 3
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=3

  $ revtest 'none clean cross'  clean 3 4
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=4


  $ revtest 'none dirty linear' dirty 1 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest 'none dirtysub linear' dirtysub 1 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M sub/suba

  $ revtest 'none dirty same'   dirty 2 3
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  parent=2
  M foo

  $ revtest 'none dirtysub same'   dirtysub 2 3
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  parent=2
  M sub/suba

  $ revtest 'none dirty cross'  dirty 3 4
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  parent=3
  M foo

  $ norevtest 'none dirty cross'  dirty 2
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "bd10386d478c: 2"
  1 other heads for branch "default"
  parent=2
  M foo

  $ revtest 'none dirtysub cross'  dirtysub 3 4
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  parent=3
  M sub/suba

  $ revtest '--clean dirty linear'   dirty 1 2 --clean
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

  $ revtest '--check dirty linear'   dirty 1 2 --check
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest '--merge dirty linear'   dirty 1 2 --merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest '--merge dirty cross'  dirty 3 4 --merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=4
  M foo

  $ revtest '--check dirtysub linear'   dirtysub 1 2 --check
  abort: uncommitted changes in subrepository "sub"
  parent=1
  M sub/suba

  $ norevtest '--check clean same'   clean 2 -c
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "bd10386d478c: 2"
  1 other heads for branch "default"
  parent=2

  $ revtest '--check --clean dirty linear'  dirty 1 2 "--check --clean"
  abort: cannot specify both --clean and --check
  parent=1
  M foo

  $ revtest '--merge -checkc dirty linear'  dirty 1 2 "--merge --check"
  abort: cannot specify both --check and --merge
  parent=1
  M foo

  $ revtest '--merge -clean dirty linear'  dirty 1 2 "--merge --clean"
  abort: cannot specify both --clean and --merge
  parent=1
  M foo

  $ echo '[commands]' >> .hg/hgrc
  $ echo 'update.check = abort' >> .hg/hgrc

  $ revtest 'none dirty linear' dirty 1 2
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest 'none dirty linear' dirty 1 2 --check
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest '--merge none dirty linear' dirty 1 2 --check
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest '--merge none dirty linear' dirty 1 2 --merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest '--merge none dirty linear' dirty 1 2 --no-check
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest 'none dirty linear' dirty 1 2 --clean
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

  $ echo 'update.check = none' >> .hg/hgrc

  $ revtest 'none dirty cross'  dirty 3 4
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=4
  M foo

  $ revtest 'none dirty linear' dirty 1 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest 'none dirty linear' dirty 1 2 --check
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest 'none dirty linear' dirty 1 2 --no-merge
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest 'none dirty linear' dirty 1 2 --clean
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

  $ hg co -qC 3
  $ echo dirty >> a
  $ hg co --tool :merge3 4
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges
  [1]
  $ hg log -G --template '{rev}:{node|short} {parents} {branches}\n'
  o  5:ff252e8273df  b1
  |
  @  4:d047485b3896 0:60829823a42a  b1
  |
  | %  3:6efa171f091b 1:0786582aa4b1
  | |
  | | o  2:bd10386d478c
  | |/
  | o  1:0786582aa4b1
  |/
  o  0:60829823a42a
  
  $ hg st
  M a
  ? a.orig
  # Unresolved merge conflicts:
  # 
  #     a
  # 
  # To mark files as resolved:  hg resolve --mark FILE
  
  $ cat a
  <<<<<<< working copy:        6efa171f091b - test: 3
  three
  dirty
  ||||||| working copy parent: 6efa171f091b - test: 3
  three
  =======
  four
  >>>>>>> destination:         d047485b3896 b1 - test: 4
  $ rm a.orig

  $ echo 'update.check = noconflict' >> .hg/hgrc

  $ revtest 'none dirty cross'  dirty 3 4
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=4
  M foo

  $ revtest 'none dirty linear' dirty 1 2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2
  M foo

  $ revtest 'none dirty linear' dirty 1 2 -c
  abort: uncommitted changes
  parent=1
  M foo

  $ revtest 'none dirty linear' dirty 1 2 -C
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

Locally added file is allowed
  $ hg up -qC 3
  $ echo a > bar
  $ hg add bar
  $ hg up -q 4
  $ hg st
  A bar
  $ hg forget bar
  $ rm bar

Locally removed file is allowed
  $ hg up -qC 3
  $ hg rm foo
  $ hg up -q 4

File conflict is not allowed
  $ hg up -qC 3
  $ echo dirty >> a
  $ hg up -q 4
  abort: conflicting changes
  (commit or update --clean to discard changes)
  [20]
  $ hg up -m 4
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges
  [1]
  $ rm a.orig
  $ hg status
  M a
  # Unresolved merge conflicts:
  # 
  #     a
  # 
  # To mark files as resolved:  hg resolve --mark FILE
  
  $ hg resolve -l
  U a

Try to make empty commit while there are conflicts
  $ hg revert -r . a
  $ rm a.orig
  $ hg ci -m empty
  abort: unresolved merge conflicts (see 'hg help resolve')
  [20]
  $ hg resolve -m a
  (no more unresolved files)
  $ hg resolve -l
  R a
  $ hg ci -m empty
  nothing changed
  [1]
  $ hg resolve -l

Change/delete conflict is not allowed
  $ hg up -qC 3
  $ hg rm foo
  $ hg up -q 4

Uses default value of "linear" when value is misspelled
  $ echo 'update.check = linyar' >> .hg/hgrc

  $ revtest 'dirty cross'  dirty 3 4
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  parent=3
  M foo

Setup for later tests
  $ revtest 'none dirty linear' dirty 1 2 -c
  abort: uncommitted changes
  parent=1
  M foo

  $ cd ..

Test updating to null revision

  $ hg init null-repo
  $ cd null-repo
  $ echo a > a
  $ hg add a
  $ hg ci -m a
  $ hg up -qC 0
  $ echo b > b
  $ hg add b
  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg st
  A b
  $ hg up -q 0
  $ hg st
  A b
  $ hg up -qC null
  $ hg st
  ? b
  $ cd ..

Test updating with closed head
---------------------------------------------------------------------

  $ hg clone -U -q b1 closed-heads
  $ cd closed-heads

Test updating if at least one non-closed branch head exists

if on the closed branch head:
- update to "."
- "updated to a closed branch head ...." message is displayed
- "N other heads for ...." message is displayed

  $ hg update -q -C 3
  $ hg commit --close-branch -m 6
  $ norevtest "on closed branch head" clean 6
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  no open descendant heads on branch "default", updating to a closed head
  (committing will reopen the head, use 'hg heads .' to see 1 other heads)
  parent=6

if descendant non-closed branch head exists, and it is only one branch head:
- update to it, even if its revision is less than closed one
- "N other heads for ...." message isn't displayed

  $ norevtest "non-closed 2 should be chosen" clean 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=2

if all descendant branch heads are closed, but there is another branch head:
- update to the tipmost descendant head
- "updated to a closed branch head ...." message is displayed
- "N other heads for ...." message is displayed

  $ norevtest "all descendant branch heads are closed" clean 3
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  no open descendant heads on branch "default", updating to a closed head
  (committing will reopen the head, use 'hg heads .' to see 1 other heads)
  parent=6

Test updating if all branch heads are closed

if on the closed branch head:
- update to "."
- "updated to a closed branch head ...." message is displayed
- "all heads of branch ...." message is displayed

  $ hg update -q -C 2
  $ hg commit --close-branch -m 7
  $ norevtest "all heads of branch default are closed" clean 6
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  no open descendant heads on branch "default", updating to a closed head
  (committing will reopen branch "default")
  parent=6

if not on the closed branch head:
- update to the tipmost descendant (closed) head
- "updated to a closed branch head ...." message is displayed
- "all heads of branch ...." message is displayed

  $ norevtest "all heads of branch default are closed" clean 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  no open descendant heads on branch "default", updating to a closed head
  (committing will reopen branch "default")
  parent=7

  $ cd ..

Test updating if "default" branch doesn't exist and no revision is
checked out (= "default" is used as current branch)

  $ hg init no-default-branch
  $ cd no-default-branch

  $ hg branch foobar
  marked working directory as branch foobar
  (branches are permanent and global, did you want a bookmark?)
  $ echo a > a
  $ hg commit -m "#0" -A
  adding a
  $ echo 1 >> a
  $ hg commit -m "#1"
  $ hg update -q 0
  $ echo 3 >> a
  $ hg commit -m "#2"
  created new head
  $ hg commit --close-branch -m "#3"

if there is at least one non-closed branch head:
- update to the tipmost branch head

  $ norevtest "non-closed 1 should be chosen" clean null
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  parent=1

if all branch heads are closed
- update to "tip"
- "updated to a closed branch head ...." message is displayed
- "all heads for branch "XXXX" are closed" message is displayed

  $ hg update -q -C 1
  $ hg commit --close-branch -m "#4"

  $ norevtest "all branches are closed" clean null
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  no open descendant heads on branch "foobar", updating to a closed head
  (committing will reopen branch "foobar")
  parent=4

  $ cd ../b1

Test obsolescence behavior
---------------------------------------------------------------------

successors should be taken in account when checking head destination

  $ cat << EOF >> $HGRCPATH
  > [ui]
  > logtemplate={rev}:{node|short} {desc|firstline}
  > [experimental]
  > evolution.createmarkers=True
  > EOF

Test no-argument update to a successor of an obsoleted changeset

  $ hg log -G
  o  5:ff252e8273df 5
  |
  o  4:d047485b3896 4
  |
  | o  3:6efa171f091b 3
  | |
  | | o  2:bd10386d478c 2
  | |/
  | @  1:0786582aa4b1 1
  |/
  o  0:60829823a42a 0
  
  $ hg book bm -r 3
  $ hg status
  M foo

We add simple obsolescence marker between 3 and 4 (indirect successors)

  $ hg id --debug -i -r 3
  6efa171f091b00a3c35edc15d48c52a498929953
  $ hg id --debug -i -r 4
  d047485b3896813b2a624e86201983520f003206
  $ hg debugobsolete 6efa171f091b00a3c35edc15d48c52a498929953 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa d047485b3896813b2a624e86201983520f003206
  1 new obsolescence markers

Test that 5 is detected as a valid destination from 3 and also accepts moving
the bookmark (issue4015)

  $ hg up --quiet --hidden 3
  $ hg up 5
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg book bm
  moving bookmark 'bm' forward from 6efa171f091b
  $ hg bookmarks
   * bm                        5:ff252e8273df

Test that we abort before we warn about the hidden commit if the working
directory is dirty
  $ echo conflict > a
  $ hg up --hidden 3
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  [255]

Test that we still warn also when there are conflicts
  $ hg up -m --hidden 3
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges
  (leaving bookmark bm)
  updated to hidden changeset 6efa171f091b
  (hidden revision '6efa171f091b' was rewritten as: d047485b3896)
  [1]

Test that statuses are reported properly before and after merge resolution.
  $ rm a.orig
  $ hg resolve -l
  U a
  $ hg status
  M a
  M foo
  # Unresolved merge conflicts:
  # 
  #     a
  # 
  # To mark files as resolved:  hg resolve --mark FILE
  

  $ hg revert -r . a

  $ rm a.orig
  $ hg resolve -l
  U a
  $ hg status
  M foo
  # Unresolved merge conflicts:
  # 
  #     a
  # 
  # To mark files as resolved:  hg resolve --mark FILE
  
  $ hg status -Tjson
  [
   {
    "itemtype": "file",
    "path": "foo",
    "status": "M"
   },
   {
    "itemtype": "file",
    "path": "a",
    "unresolved": true
   }
  ]

  $ hg resolve -m
  (no more unresolved files)

  $ hg resolve -l
  R a
  $ hg status
  M foo
  # No unresolved merge conflicts.
  
  $ hg status -Tjson
  [
   {
    "itemtype": "file",
    "path": "foo",
    "status": "M"
   }
  ]

Test that 4 is detected as the no-argument destination from 3 and also moves
the bookmark with it
  $ hg up --quiet 0          # we should be able to update to 3 directly
  $ hg status
  M foo
  $ hg up --quiet --hidden 3 # but not implemented yet.
  updated to hidden changeset 6efa171f091b
  (hidden revision '6efa171f091b' was rewritten as: d047485b3896)
  $ hg book -f bm
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating bookmark bm
  $ hg book
   * bm                        4:d047485b3896

Test that 5 is detected as a valid destination from 1
  $ hg up --quiet 0          # we should be able to update to 3 directly
  $ hg up --quiet --hidden 3 # but not implemented yet.
  updated to hidden changeset 6efa171f091b
  (hidden revision '6efa171f091b' was rewritten as: d047485b3896)
  $ hg up 5
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that 5 is not detected as a valid destination from 2
  $ hg up --quiet 0
  $ hg up --quiet 2
  $ hg up 5
  abort: uncommitted changes
  (commit or update --clean to discard changes)
  [255]

Test that we update to the closest non-obsolete ancestor when updating from a
pruned changeset (i.e. that has no successors)
  $ hg id --debug -r 2
  bd10386d478cd5a9faf2e604114c8e6da62d3889
  $ hg up --quiet 0
  $ hg up --quiet 2
  $ hg debugobsolete bd10386d478cd5a9faf2e604114c8e6da62d3889
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -r '_destupdate()'
  1:0786582aa4b1 1 (no-eol)
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that boolean flags allow --no-flag specification to override [defaults]
  $ cat >> $HGRCPATH <<EOF
  > [defaults]
  > update = --check
  > EOF
  $ hg co 1
  abort: uncommitted changes
  [20]
  $ hg co --no-check 1
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
