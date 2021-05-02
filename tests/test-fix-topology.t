A script that implements uppercasing all letters in a file.

  $ UPPERCASEPY="$TESTTMP/uppercase.py"
  $ cat > $UPPERCASEPY <<EOF
  > import sys
  > from mercurial.utils.procutil import setbinary
  > setbinary(sys.stdin)
  > setbinary(sys.stdout)
  > stdin = getattr(sys.stdin, 'buffer', sys.stdin)
  > stdout = getattr(sys.stdout, 'buffer', sys.stdout)
  > stdout.write(stdin.read().upper())
  > EOF
  $ TESTLINES="foo\nbar\nbaz\n"
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY
  FOO
  BAR
  BAZ

Tests for the fix extension's behavior around non-trivial history topologies.
Looks for correct incremental fixing and reproduction of parent/child
relationships. We indicate fixed file content by uppercasing it.

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > fix =
  > strip =
  > debugdrawdag=$TESTDIR/drawdag.py
  > [fix]
  > uppercase-whole-file:command="$PYTHON" $UPPERCASEPY
  > uppercase-whole-file:pattern=set:**
  > EOF

This tests the only behavior that should really be affected by obsolescence, so
we'll test it with evolution off and on. This only changes the revision
numbers, if all is well.

#testcases obsstore-off obsstore-on
#if obsstore-on
  $ cat >> $HGRCPATH <<EOF
  > [experimental]
  > evolution.createmarkers=True
  > evolution.allowunstable=True
  > EOF
#endif

Setting up the test topology. Scroll down to see the graph produced. We make it
clear which files were modified in each revision. It's enough to test at the
file granularity, because that demonstrates which baserevs were diffed against.
The computation of changed lines is orthogonal and tested separately.

  $ hg init repo
  $ cd repo

  $ printf "aaaa\n" > a
  $ hg commit -Am "change A"
  adding a
  $ printf "bbbb\n" > b
  $ hg commit -Am "change B"
  adding b
  $ printf "cccc\n" > c
  $ hg commit -Am "change C"
  adding c
  $ hg checkout 0
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ printf "dddd\n" > d
  $ hg commit -Am "change D"
  adding d
  created new head
  $ hg merge -r 2
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ printf "eeee\n" > e
  $ hg commit -Am "change E"
  adding e
  $ hg checkout 0
  0 files updated, 0 files merged, 4 files removed, 0 files unresolved
  $ printf "ffff\n" > f
  $ hg commit -Am "change F"
  adding f
  created new head
  $ hg checkout 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ printf "gggg\n" > g
  $ hg commit -Am "change G"
  adding g
  created new head
  $ hg merge -r 5
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ printf "hhhh\n" > h
  $ hg commit -Am "change H (child of b53d63e816fb and 0e49f92ee6e9)"
  adding h
  $ hg merge -r 4
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ printf "iiii\n" > i
  $ hg commit -Am "change I"
  adding i
  $ hg checkout 2
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved
  $ printf "jjjj\n" > j
  $ hg commit -Am "change J (child of 7f371349286e)"
  adding j
  created new head
  $ hg checkout 7
  3 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ printf "kkkk\n" > k
  $ hg add
  adding k

  $ hg log --graph --template '{rev}:{node|short} {desc}\n'
  o  9:884041ccc490 change J (child of 7f371349286e)
  |
  | o    8:b7c772105fd2 change I
  | |\
  | | @    7:4e7b9312dad2 change H (child of b53d63e816fb and 0e49f92ee6e9)
  | | |\
  | | | o  6:0e49f92ee6e9 change G
  | | | |
  | | o |  5:b53d63e816fb change F
  | | |/
  | o |  4:ddad58af5e51 change E
  |/| |
  | o |  3:c015ebfd2bfe change D
  | |/
  o |  2:7f371349286e change C
  | |
  o |  1:388fdd33fea0 change B
  |/
  o  0:a55a84d97a24 change A
  

Fix all but the root revision and its four children.

  $ hg fix -r '2|4|7|8|9' --working-dir
  saved backup bundle to * (glob) (obsstore-off !)

The five revisions remain, but the other revisions were fixed and replaced. All
parent pointers have been accurately set to reproduce the previous topology
(though it is rendered in a slightly different order now).

#if obsstore-on
  $ hg log --graph --template '{rev}:{node|short} {desc}\n'
  o  14:d8d0e7974598 change J (child of 89de0da1d5da)
  |
  | o    13:4fc0b354461e change I
  | |\
  | | @    12:1c45f3923443 change H (child of b53d63e816fb and 0e49f92ee6e9)
  | | |\
  | o | |  11:d75754455722 change E
  |/| | |
  o | | |  10:89de0da1d5da change C
  | | | |
  | | | o  6:0e49f92ee6e9 change G
  | | | |
  | | o |  5:b53d63e816fb change F
  | | |/
  | o /  3:c015ebfd2bfe change D
  | |/
  o /  1:388fdd33fea0 change B
  |/
  o  0:a55a84d97a24 change A
  
  $ C=10
  $ E=11
  $ H=12
  $ I=13
  $ J=14
#else
  $ hg log --graph --template '{rev}:{node|short} {desc}\n'
  o  9:d8d0e7974598 change J (child of 89de0da1d5da)
  |
  | o    8:4fc0b354461e change I
  | |\
  | | @    7:1c45f3923443 change H (child of b53d63e816fb and 0e49f92ee6e9)
  | | |\
  | o | |  6:d75754455722 change E
  |/| | |
  o | | |  5:89de0da1d5da change C
  | | | |
  | | | o  4:0e49f92ee6e9 change G
  | | | |
  | | o |  3:b53d63e816fb change F
  | | |/
  | o /  2:c015ebfd2bfe change D
  | |/
  o /  1:388fdd33fea0 change B
  |/
  o  0:a55a84d97a24 change A
  
  $ C=5
  $ E=6
  $ H=7
  $ I=8
  $ J=9
#endif

Change C is a root of the set being fixed, so all we fix is what has changed
since its parent. That parent, change B, is its baserev.

  $ hg cat -r $C 'set:**'
  aaaa
  bbbb
  CCCC

Change E is a merge with only one parent being fixed. Its baserevs are the
unfixed parent plus the baserevs of the other parent. This evaluates to changes
B and D. We now have to decide what it means to incrementally fix a merge
commit. We choose to fix anything that has changed versus any baserev. Only the
undisturbed content of the common ancestor, change A, is unfixed.

  $ hg cat -r $E 'set:**'
  aaaa
  BBBB
  CCCC
  DDDD
  EEEE

Change H is a merge with neither parent being fixed. This is essentially
equivalent to the previous case because there is still only one baserev for
each parent of the merge.

  $ hg cat -r $H 'set:**'
  aaaa
  FFFF
  GGGG
  HHHH

Change I is a merge that has four baserevs; two from each parent. We handle
multiple baserevs in the same way regardless of how many came from each parent.
So, fixing change H will fix any files that were not exactly the same in each
baserev.

  $ hg cat -r $I 'set:**'
  aaaa
  BBBB
  CCCC
  DDDD
  EEEE
  FFFF
  GGGG
  HHHH
  IIII

Change J is a simple case with one baserev, but its baserev is not its parent,
change C. Its baserev is its grandparent, change B.

  $ hg cat -r $J 'set:**'
  aaaa
  bbbb
  CCCC
  JJJJ

The working copy was dirty, so it is treated much like a revision. The baserevs
for the working copy are inherited from its parent, change H, because it is
also being fixed.

  $ cat *
  aaaa
  FFFF
  GGGG
  HHHH
  KKKK

Change A was never a baserev because none of its children were to be fixed.

  $ cd ..


Test the --source option. We only do this with obsstore on to avoid duplicating
test code. We rely on the other tests to prove that obsolescence is not an
important factor here.

#if obsstore-on
  $ hg init source-arg
  $ cd source-arg
  $ printf "aaaa\n" > a
  $ hg commit -Am "change A"
  adding a
  $ printf "bbbb\n" > b
  $ hg commit -Am "change B"
  adding b
  $ printf "cccc\n" > c
  $ hg commit -Am "change C"
  adding c
  $ hg checkout 0
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ printf "dddd\n" > d
  $ hg commit -Am "change D"
  adding d
  created new head
  $ hg log --graph --template '{rev} {desc}\n'
  @  3 change D
  |
  | o  2 change C
  | |
  | o  1 change B
  |/
  o  0 change A
  

Test passing 'wdir()' to --source
  $ printf "xxxx\n" > x
  $ hg add x
  $ hg fix -s 'wdir()'
  $ cat *
  aaaa
  dddd
  XXXX

Test passing '.' to --source
  $ printf "xxxx\n" > x
  $ hg fix -s .
  $ hg log --graph --template '{rev} {desc}\n'
  @  4 change D
  |
  | o  2 change C
  | |
  | o  1 change B
  |/
  o  0 change A
  
  $ cat *
  aaaa
  DDDD
  XXXX
  $ hg strip -qf 4
  $ hg co -q 3

Test passing other branch to --source
  $ printf "xxxx\n" > x
  $ hg add x
  $ hg fix -s 2
  $ hg log --graph --template '{rev} {desc}\n'
  o  4 change C
  |
  | @  3 change D
  | |
  o |  1 change B
  |/
  o  0 change A
  
  $ hg cat -r 4 b c
  bbbb
  CCCC
  $ cat *
  aaaa
  dddd
  xxxx
  $ hg strip -qf 4

Test passing multiple revisions to --source
  $ hg fix -s '2 + .'
  $ hg log --graph --template '{rev} {desc}\n'
  @  5 change D
  |
  | o  4 change C
  | |
  | o  1 change B
  |/
  o  0 change A
  
  $ hg cat -r 4 b c
  bbbb
  CCCC
  $ cat *
  aaaa
  DDDD
  XXXX

  $ cd ..

  $ hg init exclude-obsolete
  $ cd exclude-obsolete
  $ hg debugdrawdag <<'EOS'
  > E C # prune: C
  > | |
  > D B # prune: B, D
  > |/
  > A
  > EOS
  1 new orphan changesets
  $ hg log --graph --template '{rev} {desc}\n'
  *  4 E
  |
  | x  3 C
  | |
  x |  2 D
  | |
  | x  1 B
  |/
  o  0 A
  
  $ hg fix -s A
  $ hg fix -s B
  abort: no changesets specified
  (use --source or --working-dir)
  [255]
  $ hg fix -s D
  $ hg fix -s E
  $ cd ..

#endif

The --all flag should fix anything that wouldn't cause a problem if you fixed
it, including the working copy. Obsolete revisions are not fixed because that
could cause divergence. Public revisions would cause an abort because they are
immutable. We can fix orphans because their successors are still just orphans
of the original obsolete parent. When obsolesence is off, we're just fixing and
replacing anything that isn't public.

  $ hg init fixall
  $ cd fixall
  $ hg fix --all --working-dir
  abort: cannot specify both --working-dir and --all
  [10]

#if obsstore-on
  $ printf "one\n" > foo.whole
  $ hg commit -Aqm "first"
  $ hg phase --public
  $ hg tag --local root
  $ printf "two\n" > foo.whole
  $ hg commit -m "second"
  $ printf "three\n" > foo.whole
  $ hg commit -m "third" --secret
  $ hg tag --local secret
  $ hg checkout root
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "four\n" > foo.whole
  $ hg commit -m "fourth"
  created new head
  $ printf "five\n" > foo.whole
  $ hg commit -m "fifth"
  $ hg tag --local replaced
  $ printf "six\n" > foo.whole
  $ hg commit -m "sixth"
  $ hg checkout replaced
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "seven\n" > foo.whole
  $ hg commit --amend
  1 new orphan changesets
  $ hg checkout secret
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "uncommitted\n" > foo.whole

  $ hg log --graph --template '{rev} {desc} {phase}\n'
  o  6 fifth draft
  |
  | *  5 sixth draft
  | |
  | x  4 fifth draft
  |/
  o  3 fourth draft
  |
  | @  2 third secret
  | |
  | o  1 second draft
  |/
  o  0 first public
  

  $ hg fix --all

  $ hg log --graph --template '{rev} {desc}\n' -r 'sort(all(), topo)' --hidden
  o  11 fifth
  |
  o  9 fourth
  |
  | @  8 third
  | |
  | o  7 second
  |/
  | *  10 sixth
  | |
  | | x  5 sixth
  | |/
  | x  4 fifth
  | |
  | | x  6 fifth
  | |/
  | x  3 fourth
  |/
  | x  2 third
  | |
  | x  1 second
  |/
  o  0 first
  

  $ hg cat -r 7 foo.whole
  TWO
  $ hg cat -r 8 foo.whole
  THREE
  $ hg cat -r 9 foo.whole
  FOUR
  $ hg cat -r 10 foo.whole
  SIX
  $ hg cat -r 11 foo.whole
  SEVEN
  $ cat foo.whole
  UNCOMMITTED
#else
  $ printf "one\n" > foo.whole
  $ hg commit -Aqm "first"
  $ hg phase --public
  $ hg tag --local root
  $ printf "two\n" > foo.whole
  $ hg commit -m "second"
  $ printf "three\n" > foo.whole
  $ hg commit -m "third" --secret
  $ hg tag --local secret
  $ hg checkout root
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "four\n" > foo.whole
  $ hg commit -m "fourth"
  created new head
  $ printf "uncommitted\n" > foo.whole

  $ hg log --graph --template '{rev} {desc} {phase}\n'
  @  3 fourth draft
  |
  | o  2 third secret
  | |
  | o  1 second draft
  |/
  o  0 first public
  

  $ hg fix --all
  saved backup bundle to * (glob)

  $ hg log --graph --template '{rev} {desc} {phase}\n'
  @  3 fourth draft
  |
  | o  2 third secret
  | |
  | o  1 second draft
  |/
  o  0 first public
  
  $ hg cat -r 0 foo.whole
  one
  $ hg cat -r 1 foo.whole
  TWO
  $ hg cat -r 2 foo.whole
  THREE
  $ hg cat -r 3 foo.whole
  FOUR
  $ cat foo.whole
  UNCOMMITTED
#endif

  $ cd ..

