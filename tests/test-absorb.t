  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > absorb=
  > EOF

  $ sedi() { # workaround check-code
  > pattern="$1"
  > shift
  > for i in "$@"; do
  >     sed "$pattern" "$i" > "$i".tmp
  >     mv "$i".tmp "$i"
  > done
  > }

  $ hg init repo1
  $ cd repo1

Do not crash with empty repo:

  $ hg absorb
  abort: no mutable changeset to change
  [10]

Make some commits:

  $ for i in 1 2 3 4 5; do
  >   echo $i >> a
  >   hg commit -A a -m "commit $i" -q
  > done

  $ hg annotate a
  0: 1
  1: 2
  2: 3
  3: 4
  4: 5

Change a few lines:

  $ cat > a <<EOF
  > 1a
  > 2b
  > 3
  > 4d
  > 5e
  > EOF

Preview absorb changes:

  $ hg absorb --print-changes --dry-run
  showing changes for a
          @@ -0,2 +0,2 @@
  4ec16f8 -1
  5c5f952 -2
  4ec16f8 +1a
  5c5f952 +2b
          @@ -3,2 +3,2 @@
  ad8b8b7 -4
  4f55fa6 -5
  ad8b8b7 +4d
  4f55fa6 +5e
  
  4 changesets affected
  4f55fa6 commit 5
  ad8b8b7 commit 4
  5c5f952 commit 2
  4ec16f8 commit 1

Run absorb:

  $ hg absorb --apply-changes
  saved backup bundle to * (glob)
  2 of 2 chunk(s) applied
  $ hg annotate a
  0: 1a
  1: 2b
  2: 3
  3: 4d
  4: 5e

Delete a few lines and related commits will be removed if they will be empty:

  $ cat > a <<EOF
  > 2b
  > 4d
  > EOF
  $ echo y | hg absorb --config ui.interactive=1
  showing changes for a
          @@ -0,1 +0,0 @@
  f548282 -1a
          @@ -2,1 +1,0 @@
  ff5d556 -3
          @@ -4,1 +2,0 @@
  84e5416 -5e
  
  3 changesets affected
  84e5416 commit 5
  ff5d556 commit 3
  f548282 commit 1
  apply changes (y/N)?  y
  saved backup bundle to * (glob)
  3 of 3 chunk(s) applied
  $ hg annotate a
  1: 2b
  2: 4d
  $ hg log -T '{rev} {desc}\n' -Gp
  @  2 commit 4
  |  diff -r 1cae118c7ed8 -r 58a62bade1c6 a
  |  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -1,1 +1,2 @@
  |   2b
  |  +4d
  |
  o  1 commit 2
  |  diff -r 84add69aeac0 -r 1cae118c7ed8 a
  |  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -0,0 +1,1 @@
  |  +2b
  |
  o  0 commit 1
  

Non 1:1 map changes will be ignored:

  $ echo 1 > a
  $ hg absorb --apply-changes
  nothing applied
  [1]

The prompt is not given if there are no changes to be applied, even if there
are some changes that won't be applied:

  $ hg absorb
  showing changes for a
          @@ -0,2 +0,1 @@
          -2b
          -4d
          +1
  
  0 changesets affected
  nothing applied
  [1]

Insertaions:

  $ cat > a << EOF
  > insert before 2b
  > 2b
  > 4d
  > insert aftert 4d
  > EOF
  $ hg absorb -q --apply-changes
  $ hg status
  $ hg annotate a
  1: insert before 2b
  1: 2b
  2: 4d
  2: insert aftert 4d

Bookmarks are moved:

  $ hg bookmark -r 1 b1
  $ hg bookmark -r 2 b2
  $ hg bookmark ba
  $ hg bookmarks
     b1                        1:b35060a57a50
     b2                        2:946e4bc87915
   * ba                        2:946e4bc87915
  $ sedi 's/insert/INSERT/' a
  $ hg absorb -q --apply-changes
  $ hg status
  $ hg bookmarks
     b1                        1:a4183e9b3d31
     b2                        2:c9b20c925790
   * ba                        2:c9b20c925790

Non-modified files are ignored:

  $ touch b
  $ hg commit -A b -m b
  $ touch c
  $ hg add c
  $ hg rm b
  $ hg absorb --apply-changes
  nothing applied
  [1]
  $ sedi 's/INSERT/Insert/' a
  $ hg absorb --apply-changes
  saved backup bundle to * (glob)
  2 of 2 chunk(s) applied
  $ hg status
  A c
  R b

Public commits will not be changed:

  $ hg phase -p 1
  $ sedi 's/Insert/insert/' a
  $ hg absorb -pn
  showing changes for a
          @@ -0,1 +0,1 @@
          -Insert before 2b
          +insert before 2b
          @@ -3,1 +3,1 @@
  85b4e0e -Insert aftert 4d
  85b4e0e +insert aftert 4d
  
  1 changesets affected
  85b4e0e commit 4
  $ hg absorb --apply-changes
  saved backup bundle to * (glob)
  1 of 2 chunk(s) applied
  $ hg diff -U 0
  diff -r 1c8eadede62a a
  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	* (glob)
  @@ -1,1 +1,1 @@
  -Insert before 2b
  +insert before 2b
  $ hg annotate a
  1: Insert before 2b
  1: 2b
  2: 4d
  2: insert aftert 4d

  $ hg co -qC 1
  $ sedi 's/Insert/insert/' a
  $ hg absorb --apply-changes
  abort: no mutable changeset to change
  [10]

Make working copy clean:

  $ hg co -qC ba
  $ rm c
  $ hg status

Merge commit will not be changed:

  $ echo 1 > m1
  $ hg commit -A m1 -m m1
  $ hg bookmark -q -i m1
  $ hg update -q '.^'
  $ echo 2 > m2
  $ hg commit -q -A m2 -m m2
  $ hg merge -q m1
  $ hg commit -m merge
  $ hg bookmark -d m1
  $ hg log -G -T '{rev} {desc} {phase}\n'
  @    6 merge draft
  |\
  | o  5 m2 draft
  | |
  o |  4 m1 draft
  |/
  o  3 b draft
  |
  o  2 commit 4 draft
  |
  o  1 commit 2 public
  |
  o  0 commit 1 public
  
  $ echo 2 >> m1
  $ echo 2 >> m2
  $ hg absorb --apply-changes
  abort: cannot absorb into a merge
  [10]
  $ hg revert -q -C m1 m2

Use a new repo:

  $ cd ..
  $ hg init repo2
  $ cd repo2

Make some commits to multiple files:

  $ for f in a b; do
  >   for i in 1 2; do
  >     echo $f line $i >> $f
  >     hg commit -A $f -m "commit $f $i" -q
  >   done
  > done

Use pattern to select files to be fixed up:

  $ sedi 's/line/Line/' a b
  $ hg status
  M a
  M b
  $ hg absorb --apply-changes a
  saved backup bundle to * (glob)
  1 of 1 chunk(s) applied
  $ hg status
  M b
  $ hg absorb --apply-changes --exclude b
  nothing applied
  [1]
  $ hg absorb --apply-changes b
  saved backup bundle to * (glob)
  1 of 1 chunk(s) applied
  $ hg status
  $ cat a b
  a Line 1
  a Line 2
  b Line 1
  b Line 2

Test config option absorb.max-stack-size:

  $ sedi 's/Line/line/' a b
  $ hg log -T '{rev}:{node} {desc}\n'
  3:712d16a8f445834e36145408eabc1d29df05ec09 commit b 2
  2:74cfa6294160149d60adbf7582b99ce37a4597ec commit b 1
  1:28f10dcf96158f84985358a2e5d5b3505ca69c22 commit a 2
  0:f9a81da8dc53380ed91902e5b82c1b36255a4bd0 commit a 1
  $ hg --config absorb.max-stack-size=1 absorb -pn
  absorb: only the recent 1 changesets will be analysed
  showing changes for a
          @@ -0,2 +0,2 @@
          -a Line 1
          -a Line 2
          +a line 1
          +a line 2
  showing changes for b
          @@ -0,2 +0,2 @@
          -b Line 1
  712d16a -b Line 2
          +b line 1
  712d16a +b line 2
  
  1 changesets affected
  712d16a commit b 2

Test obsolete markers creation:

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution=createmarkers
  > [absorb]
  > add-noise=1
  > EOF

  $ hg --config absorb.max-stack-size=3 absorb -a
  absorb: only the recent 3 changesets will be analysed
  2 of 2 chunk(s) applied
  $ hg log -T '{rev}:{node|short} {desc} {get(extras, "absorb_source")}\n'
  6:3dfde4199b46 commit b 2 712d16a8f445834e36145408eabc1d29df05ec09
  5:99cfab7da5ff commit b 1 74cfa6294160149d60adbf7582b99ce37a4597ec
  4:fec2b3bd9e08 commit a 2 28f10dcf96158f84985358a2e5d5b3505ca69c22
  0:f9a81da8dc53 commit a 1 
  $ hg absorb --apply-changes
  1 of 1 chunk(s) applied
  $ hg log -T '{rev}:{node|short} {desc} {get(extras, "absorb_source")}\n'
  10:e1c8c1e030a4 commit b 2 3dfde4199b4610ea6e3c6fa9f5bdad8939d69524
  9:816c30955758 commit b 1 99cfab7da5ffdaf3b9fc6643b14333e194d87f46
  8:5867d584106b commit a 2 fec2b3bd9e0834b7cb6a564348a0058171aed811
  7:8c76602baf10 commit a 1 f9a81da8dc53380ed91902e5b82c1b36255a4bd0

Executable files:

  $ cat >> $HGRCPATH << EOF
  > [diff]
  > git=True
  > EOF
  $ cd ..
  $ hg init repo3
  $ cd repo3

#if execbit
  $ echo > foo.py
  $ chmod +x foo.py
  $ hg add foo.py
  $ hg commit -mfoo
#else
  $ hg import -q --bypass - <<EOF
  > # HG changeset patch
  > foo
  > 
  > diff --git a/foo.py b/foo.py
  > new file mode 100755
  > --- /dev/null
  > +++ b/foo.py
  > @@ -0,0 +1,1 @@
  > +
  > EOF
  $ hg up -q
#endif

  $ echo bla > foo.py
  $ hg absorb --dry-run --print-changes
  showing changes for foo.py
          @@ -0,1 +0,1 @@
  99b4ae7 -
  99b4ae7 +bla
  
  1 changesets affected
  99b4ae7 foo
  $ hg absorb --dry-run --interactive --print-changes
  diff -r 99b4ae712f84 foo.py
  1 hunks, 1 lines changed
  examine changes to 'foo.py'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,1 +1,1 @@
  -
  +bla
  record this change to 'foo.py'?
  (enter ? for help) [Ynesfdaq?] y
  
  showing changes for foo.py
          @@ -0,1 +0,1 @@
  99b4ae7 -
  99b4ae7 +bla
  
  1 changesets affected
  99b4ae7 foo
  $ hg absorb --apply-changes
  1 of 1 chunk(s) applied
  $ hg diff -c .
  diff --git a/foo.py b/foo.py
  new file mode 100755
  --- /dev/null
  +++ b/foo.py
  @@ -0,0 +1,1 @@
  +bla
  $ hg diff

Remove lines may delete changesets:

  $ cd ..
  $ hg init repo4
  $ cd repo4
  $ cat > a <<EOF
  > 1
  > 2
  > EOF
  $ hg commit -m a12 -A a
  $ cat > b <<EOF
  > 1
  > 2
  > EOF
  $ hg commit -m b12 -A b
  $ echo 3 >> b
  $ hg commit -m b3
  $ echo 4 >> b
  $ hg commit -m b4
  $ echo 1 > b
  $ echo 3 >> a
  $ hg absorb -pn
  showing changes for a
          @@ -2,0 +2,1 @@
  bfafb49 +3
  showing changes for b
          @@ -1,3 +1,0 @@
  1154859 -2
  30970db -3
  a393a58 -4
  
  4 changesets affected
  a393a58 b4
  30970db b3
  1154859 b12
  bfafb49 a12
  $ hg absorb -av | grep became
  0:bfafb49242db: 1 file(s) changed, became 4:1a2de97fc652
  1:115485984805: 2 file(s) changed, became 5:0c930dfab74c
  2:30970dbf7b40: became empty and was dropped
  3:a393a58b9a85: became empty and was dropped
  $ hg log -T '{rev} {desc}\n' -Gp
  @  5 b12
  |  diff --git a/b b/b
  |  new file mode 100644
  |  --- /dev/null
  |  +++ b/b
  |  @@ -0,0 +1,1 @@
  |  +1
  |
  o  4 a12
     diff --git a/a b/a
     new file mode 100644
     --- /dev/null
     +++ b/a
     @@ -0,0 +1,3 @@
     +1
     +2
     +3
  

Setting config rewrite.empty-successor=keep causes empty changesets to get committed:

  $ cd ..
  $ hg init repo4a
  $ cd repo4a
  $ cat > a <<EOF
  > 1
  > 2
  > EOF
  $ hg commit -m a12 -A a
  $ cat > b <<EOF
  > 1
  > 2
  > EOF
  $ hg commit -m b12 -A b
  $ echo 3 >> b
  $ hg commit -m b3
  $ echo 4 >> b
  $ hg commit -m b4
  $ hg commit -m empty --config ui.allowemptycommit=True
  $ echo 1 > b
  $ echo 3 >> a
  $ hg absorb -pn
  showing changes for a
          @@ -2,0 +2,1 @@
  bfafb49 +3
  showing changes for b
          @@ -1,3 +1,0 @@
  1154859 -2
  30970db -3
  a393a58 -4
  
  4 changesets affected
  a393a58 b4
  30970db b3
  1154859 b12
  bfafb49 a12
  $ hg absorb -av --config rewrite.empty-successor=keep | grep became
  0:bfafb49242db: 1 file(s) changed, became 5:1a2de97fc652
  1:115485984805: 2 file(s) changed, became 6:0c930dfab74c
  2:30970dbf7b40: 2 file(s) changed, became empty as 7:df6574ae635c
  3:a393a58b9a85: 2 file(s) changed, became empty as 8:ad4bd3462c9e
  4:1bb0e8cff87a: 2 file(s) changed, became 9:2dbed75af996
  $ hg log -T '{rev} {desc}\n' -Gp
  @  9 empty
  |
  o  8 b4
  |
  o  7 b3
  |
  o  6 b12
  |  diff --git a/b b/b
  |  new file mode 100644
  |  --- /dev/null
  |  +++ b/b
  |  @@ -0,0 +1,1 @@
  |  +1
  |
  o  5 a12
     diff --git a/a b/a
     new file mode 100644
     --- /dev/null
     +++ b/a
     @@ -0,0 +1,3 @@
     +1
     +2
     +3
  

Use revert to make the current change and its parent disappear.
This should move us to the non-obsolete ancestor.

  $ cd ..
  $ hg init repo5
  $ cd repo5
  $ cat > a <<EOF
  > 1
  > 2
  > EOF
  $ hg commit -m a12 -A a
  $ hg id
  bfafb49242db tip
  $ echo 3 >> a
  $ hg commit -m a123 a
  $ echo 4 >> a
  $ hg commit -m a1234 a
  $ hg id
  82dbe7fd19f0 tip
  $ hg revert -r 0 a
  $ hg absorb -pn
  showing changes for a
          @@ -2,2 +2,0 @@
  f1c23dd -3
  82dbe7f -4
  
  2 changesets affected
  82dbe7f a1234
  f1c23dd a123
  $ hg absorb --apply-changes --verbose
  1:f1c23dd5d08d: became empty and was dropped
  2:82dbe7fd19f0: became empty and was dropped
  a: 1 of 1 chunk(s) applied
  $ hg id
  bfafb49242db tip

  $ cd ..
  $ hg init repo6
  $ cd repo6
  $ echo a1 > a
  $ touch b
  $ hg commit -m a -A a b
  $ hg branch foo -q
  $ echo b > b
  $ hg commit -m 'foo (child of 0cde1ae39321)'  # will become empty
  $ hg branch bar -q
  $ hg commit -m 'bar (child of e969dc86aefc)'  # is already empty
  $ echo a2 > a
  $ printf '' > b
  $ hg absorb --apply-changes --verbose | grep became
  0:0cde1ae39321: 1 file(s) changed, became 3:fc7fcdd90fdb
  1:e969dc86aefc: 2 file(s) changed, became 4:8fc6b2cb43a5
  2:0298954ced32: 2 file(s) changed, became 5:ca8386dc4e2c
  $ hg log -T '{rev}:{node|short} (branch: {branch}) {desc}\n' -G --stat
  @  5:ca8386dc4e2c (branch: bar) bar (child of 8fc6b2cb43a5)
  |
  o  4:8fc6b2cb43a5 (branch: foo) foo (child of fc7fcdd90fdb)
  |
  o  3:fc7fcdd90fdb (branch: default) a
      a |  1 +
      b |  0
      2 files changed, 1 insertions(+), 0 deletions(-)
  

  $ cd ..
  $ hg init repo7
  $ cd repo7
  $ echo a1 > a
  $ touch b
  $ hg commit -m a -A a b
  $ echo b > b
  $ hg commit -m foo --close-branch  # will become empty
  $ echo c > c
  $ hg commit -m reopen -A c -q
  $ hg commit -m bar --close-branch  # is already empty
  $ echo a2 > a
  $ printf '' > b
  $ hg absorb --apply-changes --verbose | grep became
  0:0cde1ae39321: 1 file(s) changed, became 4:fc7fcdd90fdb
  1:651b953d5764: 2 file(s) changed, became 5:0c9de988ecdc
  2:76017bba73f6: 2 file(s) changed, became 6:d53ac896eb25
  3:c7c1d67efc1d: 2 file(s) changed, became 7:66520267fe96
  $ hg up null -q  # to make visible closed heads
  $ hg log -T '{rev} {desc}\n' -G --stat
  _  7 bar
  |
  o  6 reopen
  |   c |  1 +
  |   1 files changed, 1 insertions(+), 0 deletions(-)
  |
  _  5 foo
  |
  o  4 a
      a |  1 +
      b |  0
      2 files changed, 1 insertions(+), 0 deletions(-)
  

  $ cd ..
  $ hg init repo8
  $ cd repo8
  $ echo a1 > a
  $ hg commit -m a -A a
  $ hg commit -m empty --config ui.allowemptycommit=True
  $ echo a2 > a
  $ hg absorb --apply-changes --verbose | grep became
  0:ecf99a8d6699: 1 file(s) changed, became 2:7e3ccf8e2fa5
  1:97f72456ae0d: 1 file(s) changed, became 3:2df488325d6f
  $ hg log -T '{rev} {desc}\n' -G --stat
  @  3 empty
  |
  o  2 a
      a |  1 +
      1 files changed, 1 insertions(+), 0 deletions(-)
  
