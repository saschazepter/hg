============================================================
Test storing and use copy information at the changeset level
============================================================


  $ cat >> $HGRCPATH << EOF
  > [format]
  > exp-use-copies-side-data-changeset = yes
  > EOF

  $ cat >> $HGRCPATH << EOF
  > [alias]
  > showcopies = log -r . -T '{file_copies % "{source} -> {name}\n"}'
  > [extensions]
  > rebase =
  > split =
  > EOF

Check that copies are recorded correctly
----------------------------------------

  $ hg init repo
  $ cd repo
  $ hg debugformat -v format-variant revlog-v2 copies-sdc changelog-v2
  format-variant                 repo config default
  copies-sdc:                     yes    yes      no
  revlog-v2:                       no     no      no
  changelog-v2:                   yes    yes      no
  $ echo a > a
  $ hg add a
  $ hg ci -m initial
  $ hg cp a b
  $ hg cp a c
  $ hg cp a d
  $ hg ci -m 'copy a to b, c, and d'

  $ hg debug::changed-files -- .
  added    p1: b, a;
  added    p1: c, a;
  added    p1: d, a;

  $ hg showcopies
  a -> b
  a -> c
  a -> d

Check that renames are recorded correctly
-----------------------------------------

  $ hg mv b b2
  $ hg ci -m 'rename b to b2'

  $ hg debug::changed-files -- .
  removed    : b, ;
  added    p1: b2, b;

  $ hg showcopies
  b -> b2


Rename onto existing file. This should get recorded in the changeset files list
and in "changed-files field".

  $ hg cp b2 c --force
  $ hg st --copies
  M c
    b2


  $ hg debugindex c
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       1 37d9b5d994ea 000000000000 000000000000



  $ hg ci -m 'move b onto d'

  $ hg debug::changed-files -- .
  touched  p1: c, b2;

  $ hg showcopies
  b2 -> c

The content is the same, the parent are the same, but the second revision of
"c" has copy information so it get a different hash as intended.

  $ hg diff --from 1 --to 3 c
  $ hg debugindex c
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       1 37d9b5d994ea 000000000000 000000000000
       1       3 029625640347 000000000000 000000000000


Create a merge commit with copying done during merge.
-----------------------------------------------------

  $ hg co 0
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg cp a e
  $ hg cp a f
  $ hg ci -m 'copy a to e and f'
  created new head
  $ hg merge 3
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
File 'a' exists on both sides, so 'g' could be recorded as being from p1 or p2, but we currently
always record it as being from p1
  $ hg cp a g
File 'd' exists only in p2, so 'h' should be from p2
  $ hg cp d h
File 'f' exists only in p1, so 'i' should be from p1
  $ hg cp f i
  $ hg ci -m 'merge'

  $ hg debug::changed-files -- .
  added    p1: g, a;
  added    p2: h, d;
  added    p1: i, f;

  $ hg showcopies
  a -> g
  d -> h
  f -> i

More testing
============

(When this test was testing storing copy information in the changeset only,
this was used to check we could store it in both changeset and file-revision
metadata. Now this is just a second layer of testing)

  $ hg cp a j
  $ hg ci -m 'copy a to j'
  $ hg debug::changed-files -- .
  added    p1: j, a;
  $ hg debugdata j 0
  \x01 (esc)
  copy: a
  copyrev: b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3
  \x01 (esc)
  a
  $ hg showcopies
  a -> j

Existing copy information in the changeset should be preserved by the amend.

  $ hg ci --amend -m 'copy a to j, v2'
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/*-*-amend.hg (glob)
  $ hg debug::changed-files -- .
  added    p1: j, a;
  $ hg showcopies
  a -> j

  $ echo x >> j
  $ hg ci -m 'modify j'
  $ hg debug::changed-files -- .
  touched    : j, ;

More testing
------------

(used to be testing "storing only in filelog")

  $ hg cp a k
  $ hg ci -m 'copy a to k'
  $ hg debug::changed-files -- .
  added    p1: k, a;

  $ hg debugdata k 0
  \x01 (esc)
  copy: a
  copyrev: b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3
  \x01 (esc)
  a
  $ hg showcopies
  a -> k

Existing copy information is preserved by amend
  $ hg cp a l
  $ hg ci -m 'copy a to l'
  $ hg showcopies
  a -> l
  $ hg ci --amend -m 'new description'
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/*-*-amend.hg (glob)
  $ hg showcopies
  a -> l

No crash on partial amend
  $ hg st --change .
  A l
  $ echo modified >> a
  $ hg rm l
  $ hg commit --amend a
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/*-*-amend.hg (glob)

  $ cd ..

Test rebasing a commit with copy information

  $ hg init rebase-rename
  $ cd rebase-rename
  $ echo a > a
  $ hg ci -Aqm 'add a'
  $ echo a2 > a
  $ hg ci -m 'modify a'
  $ hg co -q 0
  $ hg mv a b
  $ hg ci -qm 'rename a to b'
Not only do we want this to run in-memory, it shouldn't fall back to
on-disk merge (no conflicts), so we force it to be in-memory
with no fallback.
  $ hg rebase -d 1 --config rebase.experimental.inmemory=yes --config devel.rebase.force-in-memory-merge=yes
  rebasing 2:* tip "rename a to b" (glob)
  merging a and b to b
  saved backup bundle to $TESTTMP/rebase-rename/.hg/strip-backup/*-*-rebase.hg (glob)
  $ hg st --change . --copies
  A b
    a
  R a
  $ cd ..

Test splitting a commit

  $ hg init split
  $ cd split
  $ echo a > a
  $ echo b > b
  $ hg ci -Aqm 'add a and b'
  $ echo a2 > a
  $ hg mv b c
  $ hg ci -m 'modify a, move b to c'
  $ hg --config ui.interactive=yes split <<EOF
  > y
  > y
  > n
  > y
  > EOF
  diff --git a/a b/a
  1 hunks, 1 lines changed
  examine changes to 'a'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,1 +1,1 @@
  -a
  +a2
  record this change to 'a'?
  (enter ? for help) [Ynesfdaq?] y
  
  diff --git a/b b/c
  rename from b
  rename to c
  examine changes to 'b' and 'c'?
  (enter ? for help) [Ynesfdaq?] n
  
  created new head
  diff --git a/b b/c
  rename from b
  rename to c
  examine changes to 'b' and 'c'?
  (enter ? for help) [Ynesfdaq?] y
  
  saved backup bundle to $TESTTMP/split/.hg/strip-backup/*-*-split.hg (glob)
  $ cd ..

Test committing half a rename

  $ hg init partial
  $ cd partial
  $ echo a > a
  $ hg ci -Aqm 'add a'
  $ hg mv a b
  $ hg ci -m 'remove a' a


Test upgrading/downgrading to sidedata storage
==============================================

downgrading
-----------

  $ hg debugindex -vc
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size
       0      1       0 1f0dee641bb7     -1 000000000000     -1 000000000000                   58          0     0         0                    0         58        plain                    0            42                    0                  0
       1      2       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1  4096         0                   58         61        plain                   42            42                    0                  0
  $ hg debugformat -v format-variant revlog-v2 copies-sdc changelog-v2
  format-variant                 repo config default
  copies-sdc:                     yes    yes      no
  revlog-v2:                       no     no      no
  changelog-v2:                   yes    yes      no
  $ hg debug::changed-files -- 0
  added      : a, ;
  $ hg debug::changed-files -- 1
  removed    : a, ;
  $ hg debugsidedata -m -- 0
  $ cat << EOF > .hg/hgrc
  > [format]
  > exp-use-copies-side-data-changeset = no
  > EOF
  $ hg debugupgraderepo --run --quiet --no-backup
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: exp-changelog-v2, exp-copies-sidedata-changeset
  
  processed revlogs:
    - changelog
  
  $ hg debugformat -v format-variant revlog-v2 copies-sdc changelog-v2
  format-variant                 repo config default
  copies-sdc:                      no     no      no
  revlog-v2:                       no     no      no
  changelog-v2:                    no     no      no
  $ hg debug::changed-files -- 0
  $ hg debug::changed-files -- 1
  $ hg debugsidedata -m -- 0
  $ hg debugindex -vc
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size
       0     -1       0 1f0dee641bb7     -1 000000000000     -1 000000000000                   58          0     0         2                    0         59       inline                    0             0                    0                  0
       1     -1       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1     0         2                   59         62       inline                    0             0                    0                  0 (missing-correct-output !)
       1     -1       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1  4096         2                   59         62       inline                    0             0                    0                  0 (known-bad-output !)

upgrading
---------

  $ hg debugindex -vc
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size
       0     -1       0 1f0dee641bb7     -1 000000000000     -1 000000000000                   58          0     0         2                    0         59       inline                    0             0                    0                  0
       1     -1       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1     0         2                   59         62       inline                    0             0                    0                  0 (missing-correct-output !)
       1     -1       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1  4096         2                   59         62       inline                    0             0                    0                  0 (known-bad-output !)
  $ cat << EOF > .hg/hgrc
  > [format]
  > exp-use-copies-side-data-changeset = yes
  > EOF
  $ hg debugupgraderepo --run --quiet --no-backup
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     added: exp-changelog-v2, exp-copies-sidedata-changeset
  
  processed revlogs:
    - changelog
  
  $ hg debugformat -v format-variant revlog-v2 copies-sdc changelog-v2
  format-variant                 repo config default
  copies-sdc:                     yes    yes      no
  revlog-v2:                       no     no      no
  changelog-v2:                   yes    yes      no
  $ hg debug::changed-files -- 0
  added      : a, ;
  $ hg debug::changed-files -- 1
  removed    : a, ;
  $ hg debugsidedata -m -- 0
  $ hg debugindex -vc
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size
       0      1       0 1f0dee641bb7     -1 000000000000     -1 000000000000                   58          0     0         0                    0         58        plain                    0            42                    0                  0
       1      2       1 e4b55703807d      0 1f0dee641bb7     -1 000000000000                   61          1  4096         0                   58         61        plain                   42            42                    0                  0


  $ cd ..
