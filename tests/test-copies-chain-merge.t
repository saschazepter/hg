#testcases filelog compatibility changeset sidedata

=====================================================
Test Copy tracing for chain of copies involving merge
=====================================================

This test files covers copies/rename case for a chains of commit where merges
are involved. It cheks we do not have unwanted update of behavior and that the
different options to retrieve copies behave correctly.


Setup
=====

use git diff to see rename

  $ cat << EOF >> $HGRCPATH
  > [diff]
  > git=yes
  > [ui]
  > logtemplate={rev} {desc}\n
  > EOF

#if compatibility
  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > copies.read-from = compatibility
  > EOF
#endif

#if changeset
  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > copies.read-from = changeset-only
  > copies.write-to = changeset-only
  > EOF
#endif

#if sidedata
  $ cat >> $HGRCPATH << EOF
  > [format]
  > exp-use-side-data = yes
  > exp-use-copies-side-data-changeset = yes
  > EOF
#endif


  $ hg init repo-chain
  $ cd repo-chain

Add some linear rename initialy

  $ echo a > a
  $ echo b > b
  $ echo h > h
  $ hg ci -Am 'i-0 initial commit: a b h'
  adding a
  adding b
  adding h
  $ hg mv a c
  $ hg ci -Am 'i-1: a -move-> c'
  $ hg mv c d
  $ hg ci -Am 'i-2: c -move-> d'
  $ hg log -G
  @  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

And having another branch with renames on the other side

  $ hg mv d e
  $ hg ci -Am 'a-1: d -move-> e'
  $ hg mv e f
  $ hg ci -Am 'a-2: e -move-> f'
  $ hg log -G --rev '::.'
  @  4 a-2: e -move-> f
  |
  o  3 a-1: d -move-> e
  |
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

Have a branching with nothing on one side

  $ hg up 'desc("i-2")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo foo > b
  $ hg ci -m 'b-1: b update'
  created new head
  $ hg log -G --rev '::.'
  @  5 b-1: b update
  |
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

Create a branch that delete a file previous renamed

  $ hg up 'desc("i-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg rm d
  $ hg ci -m 'c-1 delete d'
  created new head
  $ hg log -G --rev '::.'
  @  6 c-1 delete d
  |
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

Create a branch that delete a file previous renamed and recreate it

  $ hg up 'desc("i-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg rm d
  $ hg ci -m 'd-1 delete d'
  created new head
  $ echo bar > d
  $ hg add d
  $ hg ci -m 'd-2 re-add d'
  $ hg log -G --rev '::.'
  @  8 d-2 re-add d
  |
  o  7 d-1 delete d
  |
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

Having another branch renaming a different file to the same filename as another

  $ hg up 'desc("i-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg mv b g
  $ hg ci -m 'e-1 b -move-> g'
  created new head
  $ hg mv g f
  $ hg ci -m 'e-2 g -move-> f'
  $ hg log -G --rev '::.'
  @  10 e-2 g -move-> f
  |
  o  9 e-1 b -move-> g
  |
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

merging with unrelated change does not interfere with the renames
---------------------------------------------------------------

- rename on one side
- unrelated change on the other side

  $ hg up 'desc("b-1")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("a-2")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mBAm-0 simple merge - one way'
  $ hg up 'desc("a-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mABm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mABm")+desc("mBAm"))'
  @    12 mABm-0 simple merge - the other way
  |\
  +---o  11 mBAm-0 simple merge - one way
  | |/
  | o  5 b-1: b update
  | |
  o |  4 a-2: e -move-> f
  | |
  o |  3 a-1: d -move-> e
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mABm")'
  A f
    d
  R d
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBAm")'
  A f
    d
  R d
  $ hg status --copies --rev 'desc("a-2")' --rev 'desc("mABm")'
  M b
  $ hg status --copies --rev 'desc("a-2")' --rev 'desc("mBAm")'
  M b
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mABm")'
  M b
  A f
    d
  R d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mBAm")'
  M b
  A f
    d
  R d
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mABm")'
  M b
  A f
    a
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBAm")'
  M b
  A f
    a
  R a

merging with the side having a delete
-------------------------------------

case summary:
- one with change to an unrelated file
- one deleting the change
and recreate an unrelated file after the merge

  $ hg up 'desc("b-1")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("c-1")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mBCm-0 simple merge - one way'
  $ echo bar > d
  $ hg add d
  $ hg ci -m 'mBCm-1 re-add d'
  $ hg up 'desc("c-1")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mCBm-0 simple merge - the other way'
  created new head
  $ echo bar > d
  $ hg add d
  $ hg ci -m 'mCBm-1 re-add d'
  $ hg log -G --rev '::(desc("mCBm")+desc("mBCm"))'
  @  16 mCBm-1 re-add d
  |
  o    15 mCBm-0 simple merge - the other way
  |\
  | | o  14 mBCm-1 re-add d
  | | |
  +---o  13 mBCm-0 simple merge - one way
  | |/
  | o  6 c-1 delete d
  | |
  o |  5 b-1: b update
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
- comparing from the merge

  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBCm-0")'
  R d
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mCBm-0")'
  R d
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mBCm-0")'
  M b
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mCBm-0")'
  M b
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mBCm-0")'
  M b
  R d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mCBm-0")'
  M b
  R d
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBCm-0")'
  M b
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mCBm-0")'
  M b
  R a

- comparing with the merge children re-adding the file

  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBCm-1")'
  M d
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mCBm-1")'
  M d
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mBCm-1")'
  M b
  A d
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mCBm-1")'
  M b
  A d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mBCm-1")'
  M b
  M d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mCBm-1")'
  M b
  M d
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBCm-1")'
  M b
  A d
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mCBm-1")'
  M b
  A d
  R a

Comparing with a merge re-adding the file afterward
---------------------------------------------------

Merge:
- one with change to an unrelated file
- one deleting and recreating the change

  $ hg up 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("d-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mBDm-0 simple merge - one way'
  $ hg up 'desc("d-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mDBm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mDBm")+desc("mBDm"))'
  @    18 mDBm-0 simple merge - the other way
  |\
  +---o  17 mBDm-0 simple merge - one way
  | |/
  | o  8 d-2 re-add d
  | |
  | o  7 d-1 delete d
  | |
  o |  5 b-1: b update
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBDm-0")'
  M d
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mDBm-0")'
  M d
  $ hg status --copies --rev 'desc("d-2")' --rev 'desc("mBDm-0")'
  M b
  $ hg status --copies --rev 'desc("d-2")' --rev 'desc("mDBm-0")'
  M b
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mBDm-0")'
  M b
  M d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mDBm-0")'
  M b
  M d

The bugs makes recorded copy is different depending of where we started the merge from since

  $ hg manifest --debug --rev 'desc("mBDm-0")' | grep '644   d'
  b004912a8510032a0350a74daa2803dadfb00e12 644   d
  $ hg manifest --debug --rev 'desc("mDBm-0")' | grep '644   d'
  b004912a8510032a0350a74daa2803dadfb00e12 644   d

  $ hg manifest --debug --rev 'desc("d-2")' | grep '644   d'
  b004912a8510032a0350a74daa2803dadfb00e12 644   d
  $ hg manifest --debug --rev 'desc("b-1")' | grep '644   d'
  169be882533bc917905d46c0c951aa9a1e288dcf 644   d (no-changeset !)
  b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3 644   d (changeset !)
  $ hg debugindex d
     rev linkrev nodeid       p1           p2
       0       2 169be882533b 000000000000 000000000000 (no-changeset !)
       0       2 b789fdd96dc2 000000000000 000000000000 (changeset !)
       1       8 b004912a8510 000000000000 000000000000

Log output should not include a merge commit as it did not happen

#if no-changeset
  $ hg log -Gfr 'desc("mBDm-0")' d
  o  8 d-2 re-add d
  |
  ~
#else
  $ hg log -Gfr 'desc("mBDm-0")' d
  o  8 d-2 re-add d
  |
  ~
#endif

#if no-changeset
  $ hg log -Gfr 'desc("mDBm-0")' d
  o  8 d-2 re-add d
  |
  ~
#else
  $ hg log -Gfr 'desc("mDBm-0")' d
  o  8 d-2 re-add d
  |
  ~
#endif

  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBDm-0")'
  M b
  A d
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mDBm-0")'
  M b
  A d
  R a


Comparing with a merge with colliding rename
--------------------------------------------

- the "e-" branch renaming b to f (through 'g')
- the "a-" branch renaming d to f (through e)

  $ hg up 'desc("a-2")'
  2 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("e-2")' --tool :union
  merging f
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mAEm-0 simple merge - one way'
  $ hg up 'desc("e-2")'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("a-2")' --tool :union
  merging f
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mEAm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mAEm")+desc("mEAm"))'
  @    20 mEAm-0 simple merge - the other way
  |\
  +---o  19 mAEm-0 simple merge - one way
  | |/
  | o  10 e-2 g -move-> f
  | |
  | o  9 e-1 b -move-> g
  | |
  o |  4 a-2: e -move-> f
  | |
  o |  3 a-1: d -move-> e
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
#if no-changeset
  $ hg manifest --debug --rev 'desc("mAEm-0")' | grep '644   f'
  c39c6083dad048d5138618a46f123e2f397f4f18 644   f
  $ hg manifest --debug --rev 'desc("mEAm-0")' | grep '644   f'
  a9a8bc3860c9d8fa5f2f7e6ea8d40498322737fd 644   f
  $ hg manifest --debug --rev 'desc("a-2")' | grep '644   f'
  263ea25e220aaeb7b9bac551c702037849aa75e8 644   f
  $ hg manifest --debug --rev 'desc("e-2")' | grep '644   f'
  71b9b7e73d973572ade6dd765477fcee6890e8b1 644   f
  $ hg debugindex f
     rev linkrev nodeid       p1           p2
       0       4 263ea25e220a 000000000000 000000000000
       1      10 71b9b7e73d97 000000000000 000000000000
       2      19 c39c6083dad0 263ea25e220a 71b9b7e73d97
       3      20 a9a8bc3860c9 71b9b7e73d97 263ea25e220a
#else
  $ hg manifest --debug --rev 'desc("mAEm-0")' | grep '644   f'
  498e8799f49f9da1ca06bb2d6d4accf165c5b572 644   f
  $ hg manifest --debug --rev 'desc("mEAm-0")' | grep '644   f'
  c5b506a7118667a38a9c9348a1f63b679e382f57 644   f
  $ hg manifest --debug --rev 'desc("a-2")' | grep '644   f'
  b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3 644   f
  $ hg manifest --debug --rev 'desc("e-2")' | grep '644   f'
  1e88685f5ddec574a34c70af492f95b6debc8741 644   f
  $ hg debugindex f
     rev linkrev nodeid       p1           p2
       0       4 b789fdd96dc2 000000000000 000000000000
       1      10 1e88685f5dde 000000000000 000000000000
       2      19 498e8799f49f b789fdd96dc2 1e88685f5dde
       3      20 c5b506a71186 1e88685f5dde b789fdd96dc2
#endif

# Here the filelog based implementation is not looking at the rename
# information (because the file exist on both side). However the changelog
# based on works fine. We have different output.

  $ hg status --copies --rev 'desc("a-2")' --rev 'desc("mAEm-0")'
  M f
    b (no-filelog !)
  R b
  $ hg status --copies --rev 'desc("a-2")' --rev 'desc("mEAm-0")'
  M f
    b (no-filelog !)
  R b
  $ hg status --copies --rev 'desc("e-2")' --rev 'desc("mAEm-0")'
  M f
    d (no-filelog !)
  R d
  $ hg status --copies --rev 'desc("e-2")' --rev 'desc("mEAm-0")'
  M f
    d (no-filelog !)
  R d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("a-2")'
  A f
    d
  R d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("e-2")'
  A f
    b
  R b

# From here, we run status against revision where both source file exists.
#
# The filelog based implementation picks an arbitrary side based on revision
# numbers. So the same side "wins" whatever the parents order is. This is
# sub-optimal because depending on revision numbers means the result can be
# different from one repository to the next.
#
# The changeset based algorithm use the parent order to break tie on conflicting
# information and will have a different order depending on who is p1 and p2.
# That order is stable accross repositories. (data from p1 prevails)

  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mAEm-0")'
  A f
    d
  R b
  R d
  $ hg status --copies --rev 'desc("i-2")' --rev 'desc("mEAm-0")'
  A f
    d (filelog !)
    b (no-filelog !)
  R b
  R d
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mAEm-0")'
  A f
    a
  R a
  R b
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mEAm-0")'
  A f
    a (filelog !)
    b (no-filelog !)
  R a
  R b


Note:
| In this case, one of the merge wrongly record a merge while there is none.
| This lead to bad copy tracing information to be dug up.


Merge:
- one with change to an unrelated file (b)
- one overwriting a file (d) with a rename (from h to i to d)

  $ hg up 'desc("i-2")'
  2 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg mv h i
  $ hg commit -m "f-1: rename h -> i"
  created new head
  $ hg mv --force i d
  $ hg commit -m "f-2: rename i -> d"
  $ hg debugindex d
     rev linkrev nodeid       p1           p2
       0       2 169be882533b 000000000000 000000000000 (no-changeset !)
       0       2 b789fdd96dc2 000000000000 000000000000 (changeset !)
       1       8 b004912a8510 000000000000 000000000000
       2      22 4a067cf8965d 000000000000 000000000000 (no-changeset !)
       2      22 fe6f8b4f507f 000000000000 000000000000 (changeset !)
  $ hg up 'desc("b-1")'
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("f-2")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mBFm-0 simple merge - one way'
  $ hg up 'desc("f-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mFBm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mBFm")+desc("mFBm"))'
  @    24 mFBm-0 simple merge - the other way
  |\
  +---o  23 mBFm-0 simple merge - one way
  | |/
  | o  22 f-2: rename i -> d
  | |
  | o  21 f-1: rename h -> i
  | |
  o |  5 b-1: b update
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBFm-0")'
  M b
  A d
    h
  R a
  R h
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mFBm-0")'
  M b
  A d
    h
  R a
  R h
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBFm-0")'
  M d
    h (no-filelog !)
  R h
  $ hg status --copies --rev 'desc("f-2")' --rev 'desc("mBFm-0")'
  M b
  $ hg status --copies --rev 'desc("f-1")' --rev 'desc("mBFm-0")'
  M b
  M d
    i (no-filelog !)
  R i
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mFBm-0")'
  M d
    h (no-filelog !)
  R h
  $ hg status --copies --rev 'desc("f-2")' --rev 'desc("mFBm-0")'
  M b
  $ hg status --copies --rev 'desc("f-1")' --rev 'desc("mFBm-0")'
  M b
  M d
    i (no-filelog !)
  R i

#if no-changeset
  $ hg log -Gfr 'desc("mBFm-0")' d
  o  22 f-2: rename i -> d
  |
  o  21 f-1: rename h -> i
  :
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mBFm-0")' d
  o  22 f-2: rename i -> d
  |
  ~
#endif

#if no-changeset
  $ hg log -Gfr 'desc("mFBm-0")' d
  o  22 f-2: rename i -> d
  |
  o  21 f-1: rename h -> i
  :
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mFBm-0")' d
  o  22 f-2: rename i -> d
  |
  ~
#endif


Merge:
- one with change to a file
- one deleting and recreating the file

Unlike in the 'BD/DB' cases, an actual merge happened here. So we should
consider history and rename on both branch of the merge.

  $ hg up 'desc("i-2")'
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo "some update" >> d
  $ hg commit -m "g-1: update d"
  created new head
  $ hg up 'desc("d-2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("g-1")' --tool :union
  merging d
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mDGm-0 simple merge - one way'
  $ hg up 'desc("g-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("d-2")' --tool :union
  merging d
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mGDm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mDGm")+desc("mGDm"))'
  @    27 mGDm-0 simple merge - the other way
  |\
  +---o  26 mDGm-0 simple merge - one way
  | |/
  | o  25 g-1: update d
  | |
  o |  8 d-2 re-add d
  | |
  o |  7 d-1 delete d
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
One side of the merge have a long history with rename. The other side of the
merge point to a new file with a smaller history. Each side is "valid".

(and again the filelog based algorithm only explore one, with a pick based on
revision numbers)

  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mDGm-0")'
  A d
    a (filelog !)
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mGDm-0")'
  A d
    a
  R a
  $ hg status --copies --rev 'desc("d-2")' --rev 'desc("mDGm-0")'
  M d
  $ hg status --copies --rev 'desc("d-2")' --rev 'desc("mGDm-0")'
  M d
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mDGm-0")'
  M d
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mGDm-0")'
  M d

#if no-changeset
  $ hg log -Gfr 'desc("mDGm-0")' d
  o    26 mDGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  8 d-2 re-add d
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mDGm-0")' d
  o    26 mDGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  8 d-2 re-add d
  |/
  o  2 i-2: c -move-> d
  |
  ~
#endif


#if no-changeset
  $ hg log -Gfr 'desc("mDGm-0")' d
  o    26 mDGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  8 d-2 re-add d
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mDGm-0")' d
  o    26 mDGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  8 d-2 re-add d
  |/
  o  2 i-2: c -move-> d
  |
  ~
#endif


Merge:
- one with change to a file (d)
- one overwriting that file with a rename (from h to i, to d)

This case is similar to BF/FB, but an actual merge happens, so both side of the
history are relevant.

Note:
| In this case, the merge get conflicting information since on one side we have
| "a -> c -> d". and one the other one we have "h -> i -> d".
|
| The current code arbitrarily pick one side

  $ hg up 'desc("f-2")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("g-1")' --tool :union
  merging d
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mFGm-0 simple merge - one way'
  created new head
  $ hg up 'desc("g-1")'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("f-2")' --tool :union
  merging d
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'mGFm-0 simple merge - the other way'
  created new head
  $ hg log -G --rev '::(desc("mGFm")+desc("mFGm"))'
  @    29 mGFm-0 simple merge - the other way
  |\
  +---o  28 mFGm-0 simple merge - one way
  | |/
  | o  25 g-1: update d
  | |
  o |  22 f-2: rename i -> d
  | |
  o |  21 f-1: rename h -> i
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mFGm-0")'
  A d
    h
  R a
  R h
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mGFm-0")'
  A d
    a (no-filelog !)
    h (filelog !)
  R a
  R h
  $ hg status --copies --rev 'desc("f-2")' --rev 'desc("mFGm-0")'
  M d
  $ hg status --copies --rev 'desc("f-2")' --rev 'desc("mGFm-0")'
  M d
  $ hg status --copies --rev 'desc("f-1")' --rev 'desc("mFGm-0")'
  M d
    i (no-filelog !)
  R i
  $ hg status --copies --rev 'desc("f-1")' --rev 'desc("mGFm-0")'
  M d
    i (no-filelog !)
  R i
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mFGm-0")'
  M d
    h (no-filelog !)
  R h
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mGFm-0")'
  M d
    h (no-filelog !)
  R h

#if no-changeset
  $ hg log -Gfr 'desc("mFGm-0")' d
  o    28 mFGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  22 f-2: rename i -> d
  | |
  o |  21 f-1: rename h -> i
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mFGm-0")' d
  o    28 mFGm-0 simple merge - one way
  |\
  | o  25 g-1: update d
  | |
  o |  22 f-2: rename i -> d
  |/
  o  2 i-2: c -move-> d
  |
  ~
#endif

#if no-changeset
  $ hg log -Gfr 'desc("mGFm-0")' d
  @    29 mGFm-0 simple merge - the other way
  |\
  | o  25 g-1: update d
  | |
  o |  22 f-2: rename i -> d
  | |
  o |  21 f-1: rename h -> i
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  
#else
  $ hg log -Gfr 'desc("mGFm-0")' d
  @    29 mGFm-0 simple merge - the other way
  |\
  | o  25 g-1: update d
  | |
  o |  22 f-2: rename i -> d
  |/
  o  2 i-2: c -move-> d
  |
  ~
#endif


Comparing with merging with a deletion (and keeping the file)
-------------------------------------------------------------

Merge:
- one removing a file (d)
- one updating that file
- the merge keep the modified version of the file (canceling the delete)

In this case, the file keep on living after the merge. So we should not drop its
copy tracing chain.

  $ hg up 'desc("c-1")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("g-1")'
  file 'd' was deleted in local [working copy] but was modified in other [merge rev].
  You can use (c)hanged version, leave (d)eleted, or leave (u)nresolved.
  What do you want to do? u
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges or 'hg merge --abort' to abandon
  [1]
  $ hg resolve -t :other d
  (no more unresolved files)
  $ hg ci -m "mCGm-0"
  created new head

  $ hg up 'desc("g-1")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("c-1")'
  file 'd' was deleted in other [merge rev] but was modified in local [working copy].
  You can use (c)hanged version, (d)elete, or leave (u)nresolved.
  What do you want to do? u
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges or 'hg merge --abort' to abandon
  [1]
  $ hg resolve -t :local d
  (no more unresolved files)
  $ hg ci -m "mGCm-0"
  created new head

  $ hg log -G --rev '::(desc("mCGm")+desc("mGCm"))'
  @    31 mGCm-0
  |\
  +---o  30 mCGm-0
  | |/
  | o  25 g-1: update d
  | |
  o |  6 c-1 delete d
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

'a' is the copy source of 'd'

  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mCGm-0")'
  A d
    a (no-compatibility no-changeset !)
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mGCm-0")'
  A d
    a (no-compatibility no-changeset !)
  R a
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mCGm-0")'
  A d
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mGCm-0")'
  A d
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mCGm-0")'
  $ hg status --copies --rev 'desc("g-1")' --rev 'desc("mGCm-0")'


Comparing with merge restoring an untouched deleted file
--------------------------------------------------------

Merge:
- one removing a file (d)
- one leaving the file untouched
- the merge actively restore the file to the same content.

In this case, the file keep on living after the merge. So we should not drop its
copy tracing chain.

  $ hg up 'desc("c-1")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("b-1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg revert --rev 'desc("b-1")' d
  $ hg ci -m "mCB-revert-m-0"
  created new head

  $ hg up 'desc("b-1")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("c-1")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg revert --rev 'desc("b-1")' d
  $ hg ci -m "mBC-revert-m-0"
  created new head

  $ hg log -G --rev '::(desc("mCB-revert-m")+desc("mBC-revert-m"))'
  @    33 mBC-revert-m-0
  |\
  +---o  32 mCB-revert-m-0
  | |/
  | o  6 c-1 delete d
  | |
  o |  5 b-1: b update
  |/
  o  2 i-2: c -move-> d
  |
  o  1 i-1: a -move-> c
  |
  o  0 i-0 initial commit: a b h
  

'a' is the the copy source of 'd'

  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mCB-revert-m-0")'
  M b
  A d
    a (no-compatibility no-changeset !)
  R a
  $ hg status --copies --rev 'desc("i-0")' --rev 'desc("mBC-revert-m-0")'
  M b
  A d
    a (no-compatibility no-changeset !)
  R a
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mCB-revert-m-0")'
  M b
  A d
  $ hg status --copies --rev 'desc("c-1")' --rev 'desc("mBC-revert-m-0")'
  M b
  A d
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mCB-revert-m-0")'
  $ hg status --copies --rev 'desc("b-1")' --rev 'desc("mBC-revert-m-0")'


Test that sidedata computations during upgrades ares correct
============================================================

We upgrade a repository that is not using sidedata (the filelog case) and
 check that the same side data have been generated as if they were computed at
 commit time.


#if filelog
  $ cat >> $HGRCPATH << EOF
  > [format]
  > exp-use-side-data = yes
  > exp-use-copies-side-data-changeset = yes
  > EOF
  $ hg debugformat -v
  format-variant     repo config default
  fncache:            yes    yes     yes
  dotencode:          yes    yes     yes
  generaldelta:       yes    yes     yes
  sparserevlog:       yes    yes     yes
  sidedata:            no    yes      no
  persistent-nodemap:  no     no      no
  copies-sdc:          no    yes      no
  plain-cl-delta:     yes    yes     yes
  compression:        * (glob)
  compression-level:  default default default
  $ hg debugupgraderepo --run --quiet
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     added: exp-copies-sidedata-changeset, exp-sidedata-flag
  
#endif


#if no-compatibility no-changeset

  $ for rev in `hg log --rev 'all()' -T '{rev}\n'`; do
  >     echo "##### revision $rev #####"
  >     hg debugsidedata -c -v -- $rev
  >     hg debugchangedfiles $rev
  > done
  ##### revision 0 #####
  1 sidedata entries
   entry-0014 size 34
    '\x00\x00\x00\x03\x04\x00\x00\x00\x01\x00\x00\x00\x00\x04\x00\x00\x00\x02\x00\x00\x00\x00\x04\x00\x00\x00\x03\x00\x00\x00\x00abh'
  added      : a, ;
  added      : b, ;
  added      : h, ;
  ##### revision 1 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00ac'
  removed    : a, ;
  added    p1: c, a;
  ##### revision 2 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00cd'
  removed    : c, ;
  added    p1: d, c;
  ##### revision 3 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00de'
  removed    : d, ;
  added    p1: e, d;
  ##### revision 4 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00ef'
  removed    : e, ;
  added    p1: f, e;
  ##### revision 5 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x14\x00\x00\x00\x01\x00\x00\x00\x00b'
  touched    : b, ;
  ##### revision 6 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x0c\x00\x00\x00\x01\x00\x00\x00\x00d'
  removed    : d, ;
  ##### revision 7 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x0c\x00\x00\x00\x01\x00\x00\x00\x00d'
  removed    : d, ;
  ##### revision 8 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x04\x00\x00\x00\x01\x00\x00\x00\x00d'
  added      : d, ;
  ##### revision 9 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00bg'
  removed    : b, ;
  added    p1: g, b;
  ##### revision 10 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x06\x00\x00\x00\x01\x00\x00\x00\x01\x0c\x00\x00\x00\x02\x00\x00\x00\x00fg'
  added    p1: f, g;
  removed    : g, ;
  ##### revision 11 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 12 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 13 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 14 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x04\x00\x00\x00\x01\x00\x00\x00\x00d'
  added      : d, ;
  ##### revision 15 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 16 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x04\x00\x00\x00\x01\x00\x00\x00\x00d'
  added      : d, ;
  ##### revision 17 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 18 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 19 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00f'
  merged     : f, ;
  ##### revision 20 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00f'
  merged     : f, ;
  ##### revision 21 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x0c\x00\x00\x00\x01\x00\x00\x00\x00\x06\x00\x00\x00\x02\x00\x00\x00\x00hi'
  removed    : h, ;
  added    p1: i, h;
  ##### revision 22 #####
  1 sidedata entries
   entry-0014 size 24
    '\x00\x00\x00\x02\x16\x00\x00\x00\x01\x00\x00\x00\x01\x0c\x00\x00\x00\x02\x00\x00\x00\x00di'
  touched  p1: d, i;
  removed    : i, ;
  ##### revision 23 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 24 #####
  1 sidedata entries
   entry-0014 size 4
    '\x00\x00\x00\x00'
  ##### revision 25 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x14\x00\x00\x00\x01\x00\x00\x00\x00d'
  touched    : d, ;
  ##### revision 26 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00d'
  merged     : d, ;
  ##### revision 27 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00d'
  merged     : d, ;
  ##### revision 28 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00d'
  merged     : d, ;
  ##### revision 29 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x08\x00\x00\x00\x01\x00\x00\x00\x00d'
  merged     : d, ;
  ##### revision 30 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x10\x00\x00\x00\x01\x00\x00\x00\x00d'
  salvaged   : d, ;
  ##### revision 31 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x10\x00\x00\x00\x01\x00\x00\x00\x00d'
  salvaged   : d, ;
  ##### revision 32 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x10\x00\x00\x00\x01\x00\x00\x00\x00d'
  salvaged   : d, ;
  ##### revision 33 #####
  1 sidedata entries
   entry-0014 size 14
    '\x00\x00\x00\x01\x10\x00\x00\x00\x01\x00\x00\x00\x00d'
  salvaged   : d, ;

#endif
