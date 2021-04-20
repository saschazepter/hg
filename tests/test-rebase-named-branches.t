  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > 
  > [phases]
  > publish=False
  > 
  > [alias]
  > tglog = log -G --template "{rev}: {node|short} '{desc}' {branches}\n"
  > EOF

  $ hg init a
  $ cd a
  $ hg unbundle "$TESTDIR/bundles/rebase.hg"
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 7 changes to 7 files (+2 heads)
  new changesets cd010b8cd998:02de42196ebe (8 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up tip
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ..

  $ hg clone -q -u . a a1

  $ cd a1

  $ hg update 3
  3 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg branch dev-one
  marked working directory as branch dev-one
  (branches are permanent and global, did you want a bookmark?)
  $ hg ci -m 'dev-one named branch'

  $ hg update 7
  2 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg branch dev-two
  marked working directory as branch dev-two

  $ echo x > x

  $ hg add x

  $ hg ci -m 'dev-two named branch'

  $ hg tglog
  @  9: cb039b7cae8e 'dev-two named branch' dev-two
  |
  | o  8: 643fc9128048 'dev-one named branch' dev-one
  | |
  o |  7: 02de42196ebe 'H'
  | |
  +---o  6: eea13746799a 'G'
  | | |
  o | |  5: 24b6387c8c8c 'F'
  | | |
  +---o  4: 9520eea781bc 'E'
  | |
  | o  3: 32af7686d403 'D'
  | |
  | o  2: 5fddd98957c8 'C'
  | |
  | o  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  

Branch name containing a dash (issue3181)

  $ hg rebase -b dev-two -d dev-one --keepbranches
  rebasing 5:24b6387c8c8c "F"
  rebasing 6:eea13746799a "G"
  rebasing 7:02de42196ebe "H"
  rebasing 9:cb039b7cae8e tip "dev-two named branch"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/24b6387c8c8c-24cb8001-rebase.hg

  $ hg tglog
  @  9: 9e70cd31750f 'dev-two named branch' dev-two
  |
  o  8: 31d0e4ba75e6 'H'
  |
  | o  7: 4b988a958030 'G'
  |/|
  o |  6: 24de4aff8e28 'F'
  | |
  o |  5: 643fc9128048 'dev-one named branch' dev-one
  | |
  | o  4: 9520eea781bc 'E'
  | |
  o |  3: 32af7686d403 'D'
  | |
  o |  2: 5fddd98957c8 'C'
  | |
  o |  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  
  $ hg rebase -s dev-one -d 0 --keepbranches
  rebasing 5:643fc9128048 "dev-one named branch"
  rebasing 6:24de4aff8e28 "F"
  rebasing 7:4b988a958030 "G"
  rebasing 8:31d0e4ba75e6 "H"
  rebasing 9:9e70cd31750f tip "dev-two named branch"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/643fc9128048-c4ee9ef5-rebase.hg

  $ hg tglog
  @  9: 59c2e59309fe 'dev-two named branch' dev-two
  |
  o  8: 904590360559 'H'
  |
  | o  7: 1a1e6f72ec38 'G'
  |/|
  o |  6: 42aa3cf0fa7a 'F'
  | |
  o |  5: bc8139ee757c 'dev-one named branch' dev-one
  | |
  | o  4: 9520eea781bc 'E'
  |/
  | o  3: 32af7686d403 'D'
  | |
  | o  2: 5fddd98957c8 'C'
  | |
  | o  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  
  $ hg update 3
  3 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg branch -f dev-one
  marked working directory as branch dev-one
  $ hg ci -m 'dev-one named branch'
  created new head

  $ hg tglog
  @  10: 643fc9128048 'dev-one named branch' dev-one
  |
  | o  9: 59c2e59309fe 'dev-two named branch' dev-two
  | |
  | o  8: 904590360559 'H'
  | |
  | | o  7: 1a1e6f72ec38 'G'
  | |/|
  | o |  6: 42aa3cf0fa7a 'F'
  | | |
  | o |  5: bc8139ee757c 'dev-one named branch' dev-one
  | | |
  | | o  4: 9520eea781bc 'E'
  | |/
  o |  3: 32af7686d403 'D'
  | |
  o |  2: 5fddd98957c8 'C'
  | |
  o |  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  
  $ hg rebase -b 'max(branch("dev-two"))' -d dev-one --keepbranches
  rebasing 5:bc8139ee757c "dev-one named branch"
  note: not rebasing 5:bc8139ee757c "dev-one named branch", its destination already has all its changes
  rebasing 6:42aa3cf0fa7a "F"
  rebasing 7:1a1e6f72ec38 "G"
  rebasing 8:904590360559 "H"
  rebasing 9:59c2e59309fe "dev-two named branch"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/bc8139ee757c-f11c1080-rebase.hg

  $ hg tglog
  o  9: 71325f8bc082 'dev-two named branch' dev-two
  |
  o  8: 12b2bc666e20 'H'
  |
  | o  7: 549f007a9f5f 'G'
  |/|
  o |  6: 679f28760620 'F'
  | |
  @ |  5: 643fc9128048 'dev-one named branch' dev-one
  | |
  | o  4: 9520eea781bc 'E'
  | |
  o |  3: 32af7686d403 'D'
  | |
  o |  2: 5fddd98957c8 'C'
  | |
  o |  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  
  $ hg rebase -s 'max(branch("dev-one"))' -d 0 --keepbranches
  rebasing 5:643fc9128048 "dev-one named branch"
  rebasing 6:679f28760620 "F"
  rebasing 7:549f007a9f5f "G"
  rebasing 8:12b2bc666e20 "H"
  rebasing 9:71325f8bc082 tip "dev-two named branch"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/643fc9128048-6cdd1a52-rebase.hg

  $ hg tglog
  o  9: 3944801ae4ea 'dev-two named branch' dev-two
  |
  o  8: 8e279d293175 'H'
  |
  | o  7: aeefee77ab01 'G'
  |/|
  o |  6: e908b85f3729 'F'
  | |
  @ |  5: bc8139ee757c 'dev-one named branch' dev-one
  | |
  | o  4: 9520eea781bc 'E'
  |/
  | o  3: 32af7686d403 'D'
  | |
  | o  2: 5fddd98957c8 'C'
  | |
  | o  1: 42ccdea3bb16 'B'
  |/
  o  0: cd010b8cd998 'A'
  
  $ hg up -r 0 > /dev/null

Rebasing descendant onto ancestor across different named branches

  $ hg rebase -s 1 -d 9 --keepbranches
  rebasing 1:42ccdea3bb16 "B"
  rebasing 2:5fddd98957c8 "C"
  rebasing 3:32af7686d403 "D"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/42ccdea3bb16-3cb021d3-rebase.hg

  $ hg tglog
  o  9: e9f862ce8bad 'D'
  |
  o  8: a0d543090fa4 'C'
  |
  o  7: 3bdb949809d9 'B'
  |
  o  6: 3944801ae4ea 'dev-two named branch' dev-two
  |
  o  5: 8e279d293175 'H'
  |
  | o  4: aeefee77ab01 'G'
  |/|
  o |  3: e908b85f3729 'F'
  | |
  o |  2: bc8139ee757c 'dev-one named branch' dev-one
  | |
  | o  1: 9520eea781bc 'E'
  |/
  @  0: cd010b8cd998 'A'
  
  $ hg rebase -s 5 -d 6
  abort: source and destination form a cycle
  [10]

  $ hg rebase -s 6 -d 5
  rebasing 6:3944801ae4ea "dev-two named branch"
  rebasing 7:3bdb949809d9 "B"
  rebasing 8:a0d543090fa4 "C"
  rebasing 9:e9f862ce8bad tip "D"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/3944801ae4ea-fb46ed74-rebase.hg

  $ hg tglog
  o  9: e522577ccdbd 'D'
  |
  o  8: 810110211f50 'C'
  |
  o  7: 160b0930ccc6 'B'
  |
  o  6: c57724c84928 'dev-two named branch'
  |
  o  5: 8e279d293175 'H'
  |
  | o  4: aeefee77ab01 'G'
  |/|
  o |  3: e908b85f3729 'F'
  | |
  o |  2: bc8139ee757c 'dev-one named branch' dev-one
  | |
  | o  1: 9520eea781bc 'E'
  |/
  @  0: cd010b8cd998 'A'
  

Reopen branch by rebase

  $ hg up -qr3
  $ hg branch -q b
  $ hg ci -m 'create b'
  $ hg ci -m 'close b' --close
  $ hg rebase -b 8 -d b
  reopening closed branch head 2b586e70108d
  rebasing 5:8e279d293175 "H"
  rebasing 6:c57724c84928 "dev-two named branch"
  rebasing 7:160b0930ccc6 "B"
  rebasing 8:810110211f50 "C"
  rebasing 9:e522577ccdbd "D"
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/8e279d293175-b023e27c-rebase.hg

  $ hg log -G -Tcompact
  o  11[tip]   be1dea60f2a6   2011-04-30 15:24 +0200   nicdumz
  |    D
  |
  o  10   ac34ce92632a   2011-04-30 15:24 +0200   nicdumz
  |    C
  |
  o  9   7bd665b6ce12   2011-04-30 15:24 +0200   nicdumz
  |    B
  |
  o  8   58e7c36e77f7   1970-01-01 00:00 +0000   test
  |    dev-two named branch
  |
  o  7   8e5a320651f3   2011-04-30 15:24 +0200   nicdumz
  |    H
  |
  @  6   2b586e70108d   1970-01-01 00:00 +0000   test
  |    close b
  |
  o  5:3   3f9d5df8a707   1970-01-01 00:00 +0000   test
  |    create b
  |
  | o  4:3,1   aeefee77ab01   2011-04-30 15:24 +0200   nicdumz
  |/|    G
  | |
  o |  3   e908b85f3729   2011-04-30 15:24 +0200   nicdumz
  | |    F
  | |
  o |  2:0   bc8139ee757c   1970-01-01 00:00 +0000   test
  | |    dev-one named branch
  | |
  | o  1   9520eea781bc   2011-04-30 15:24 +0200   nicdumz
  |/     E
  |
  o  0   cd010b8cd998   2011-04-30 15:24 +0200   nicdumz
       A
  
  $ echo A-mod > A
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

--dry-run doesn't affect a dirty working directory that is unrelated to the
source or destination.

  $ hg rebase -s tip -d 4 --dry-run
  starting dry-run rebase; repository will not be changed
  rebasing 11:be1dea60f2a6 tip "D"
  dry-run rebase completed successfully; run without -n/--dry-run to perform this rebase
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

Bailing out on --confirm doesn't affect a dirty working directory that is
unrelated to the source or destination.

  $ echo A-mod > A
  $ echo n | hg rebase -s tip -d 4 --confirm --config ui.interactive=True
  starting in-memory rebase
  rebasing 11:be1dea60f2a6 tip "D"
  rebase completed successfully
  apply changes (yn)? n
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

  $ echo A-mod > A
  $ hg rebase -s tip -d 4 --confirm
  starting in-memory rebase
  rebasing 11:be1dea60f2a6 tip "D"
  rebase completed successfully
  apply changes (yn)? y
  saved backup bundle to $TESTTMP/a1/.hg/strip-backup/be1dea60f2a6-ca6d2dac-rebase.hg
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

Attempting to rebase the parent of a dirty working directory will abort, without
mangling the working directory...

  $ hg rebase -s 5 -d 4 --dry-run
  starting dry-run rebase; repository will not be changed
  abort: uncommitted changes
  [20]
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

... ditto for --confirm

  $ echo n | hg rebase -s 5 -d 4 --confirm --config ui.interactive=True
  starting in-memory rebase
  abort: uncommitted changes
  [20]
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod
  $ hg rebase -s 5 -d 4 --confirm
  starting in-memory rebase
  abort: uncommitted changes
  [20]
  $ hg diff
  diff -r 2b586e70108d A
  --- a/A	Thu Jan 01 00:00:00 1970 +0000
  +++ b/A	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,1 @@
  -A
  +A-mod

  $ cd ..

Rebase to other head on branch

Set up a case:

  $ hg init case1
  $ cd case1
  $ touch f
  $ hg ci -qAm0
  $ hg branch -q b
  $ echo >> f
  $ hg ci -qAm 'b1'
  $ hg up -qr -2
  $ hg branch -qf b
  $ hg ci -qm 'b2'
  $ hg up -qr -3
  $ hg branch -q c
  $ hg ci -m 'c1'

  $ hg tglog
  @  3: c062e3ecd6c6 'c1' c
  |
  | o  2: 792845bb77ee 'b2' b
  |/
  | o  1: 40039acb7ca5 'b1' b
  |/
  o  0: d681519c3ea7 '0'
  
  $ hg clone -q . ../case2

rebase 'b2' to another lower branch head

  $ hg up -qr 2
  $ hg rebase
  rebasing 2:792845bb77ee "b2"
  note: not rebasing 2:792845bb77ee "b2", its destination already has all its changes
  saved backup bundle to $TESTTMP/case1/.hg/strip-backup/792845bb77ee-627120ee-rebase.hg
  $ hg tglog
  o  2: c062e3ecd6c6 'c1' c
  |
  | @  1: 40039acb7ca5 'b1' b
  |/
  o  0: d681519c3ea7 '0'
  

rebase 'b1' on top of the tip of the branch ('b2') - ignoring the tip branch ('c1')

  $ cd ../case2
  $ hg up -qr 1
  $ hg rebase
  rebasing 1:40039acb7ca5 "b1"
  saved backup bundle to $TESTTMP/case2/.hg/strip-backup/40039acb7ca5-342b72d1-rebase.hg
  $ hg tglog
  @  3: 76abc1c6f8c7 'b1' b
  |
  | o  2: c062e3ecd6c6 'c1' c
  | |
  o |  1: 792845bb77ee 'b2' b
  |/
  o  0: d681519c3ea7 '0'
  

rebase 'c1' to the branch head 'c2' that is closed

  $ hg branch -qf c
  $ hg ci -qm 'c2 closed' --close
  $ hg up -qr 2
  $ hg tglog
  _  4: 8427af5d86f2 'c2 closed' c
  |
  o  3: 76abc1c6f8c7 'b1' b
  |
  | @  2: c062e3ecd6c6 'c1' c
  | |
  o |  1: 792845bb77ee 'b2' b
  |/
  o  0: d681519c3ea7 '0'
  
  $ hg rebase
  abort: branch 'c' has one head - please rebase to an explicit rev
  (run 'hg heads' to see all heads, specify destination with -d)
  [255]
  $ hg tglog
  _  4: 8427af5d86f2 'c2 closed' c
  |
  o  3: 76abc1c6f8c7 'b1' b
  |
  | @  2: c062e3ecd6c6 'c1' c
  | |
  o |  1: 792845bb77ee 'b2' b
  |/
  o  0: d681519c3ea7 '0'
  

  $ hg up -cr 1
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg branch x
  marked working directory as branch x
  $ hg rebase -r 3:: -d .
  rebasing 3:76abc1c6f8c7 "b1"
  rebasing 4:8427af5d86f2 tip "c2 closed"
  note: not rebasing 4:8427af5d86f2 tip "c2 closed", its destination already has all its changes
  saved backup bundle to $TESTTMP/case2/.hg/strip-backup/76abc1c6f8c7-cd698d13-rebase.hg
  $ hg tglog
  o  3: 117b0ed08075 'b1' x
  |
  | o  2: c062e3ecd6c6 'c1' c
  | |
  @ |  1: 792845bb77ee 'b2' b
  |/
  o  0: d681519c3ea7 '0'
  

  $ cd ..
