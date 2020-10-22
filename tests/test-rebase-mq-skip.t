#testcases continuecommand continueflag
This emulates the effects of an hg pull --rebase in which the remote repo
already has one local mq patch

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > mq=
  > 
  > [phases]
  > publish=False
  > 
  > [alias]
  > tglog = log -G --template "{rev}: {node|short} '{desc}' tags: {tags}\n"
  > EOF

#if continueflag
  $ cat >> $HGRCPATH <<EOF
  > [alias]
  > continue = rebase --continue
  > EOF
#endif

  $ hg init a
  $ cd a
  $ hg qinit -c

  $ echo c1 > c1
  $ hg add c1
  $ hg ci -m C1

  $ echo r1 > r1
  $ hg add r1
  $ hg ci -m R1

  $ hg up -q 0

  $ hg qnew p0.patch -d '1 0'
  $ echo p0 > p0
  $ hg add p0
  $ hg qref -m P0

  $ hg qnew p1.patch -d '2 0'
  $ echo p1 > p1
  $ hg add p1
  $ hg qref -m P1

  $ hg export qtip > p1.patch

  $ hg up -q -C 1

  $ hg import p1.patch
  applying p1.patch

  $ rm p1.patch

  $ hg up -q -C qtip

  $ hg rebase -v
  rebasing 2:13a46ce44f60 p0.patch qbase "P0"
  resolving manifests
  removing p0
  getting r1
  resolving manifests
  getting p0
  committing files:
  p0
  committing manifest
  committing changelog
  rebasing 3:148775c71080 p1.patch qtip "P1"
  resolving manifests
  note: not rebasing 3:148775c71080 p1.patch qtip "P1", its destination already has all its changes
  rebase merging completed
  updating mq patch p0.patch to 5:9ecc820b1737
  $TESTTMP/a/.hg/patches/p0.patch
  2 changesets found
  uncompressed size of bundle content:
       348 (changelog)
       324 (manifests)
       129  p0
       129  p1
  saved backup bundle to $TESTTMP/a/.hg/strip-backup/13a46ce44f60-5da6ecfb-rebase.hg
  2 changesets found
  uncompressed size of bundle content:
       403 (changelog)
       324 (manifests)
       129  p0
       129  p1
  adding branch
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  rebase completed
  1 revisions have been skipped

  $ hg tglog
  @  3: 9ecc820b1737 'P0' tags: p0.patch qbase qtip tip
  |
  o  2: 869d8b134a27 'P1' tags: qparent
  |
  o  1: da108f2755df 'R1' tags:
  |
  o  0: cd320d50b341 'C1' tags:
  
  $ cd ..


  $ hg init b
  $ cd b
  $ hg qinit -c

  $ for i in r0 r1 r2 r3 r4 r5 r6;
  > do
  >     echo $i > $i
  >     hg ci -Am $i
  > done
  adding r0
  adding r1
  adding r2
  adding r3
  adding r4
  adding r5
  adding r6

  $ hg qimport -r 1:tip

  $ hg up -q 0

  $ for i in r1 r3 r7 r8;
  > do
  >     echo $i > $i
  >     hg ci -Am branch2-$i
  > done
  adding r1
  created new head
  adding r3
  adding r7
  adding r8

  $ echo somethingelse > r4
  $ hg ci -Am branch2-r4
  adding r4

  $ echo r6 > r6
  $ hg ci -Am branch2-r6
  adding r6

  $ hg up -q qtip

  $ HGMERGE=internal:fail hg rebase
  rebasing 1:b4bffa6e4776 qbase r1 "r1"
  note: not rebasing 1:b4bffa6e4776 qbase r1 "r1", its destination already has all its changes
  rebasing 2:c0fd129beb01 r2 "r2"
  rebasing 3:6ff5b8feed8e r3 "r3"
  note: not rebasing 3:6ff5b8feed8e r3 "r3", its destination already has all its changes
  rebasing 4:094320fec554 r4 "r4"
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]

  $ HGMERGE=internal:local hg resolve --all
  (no more unresolved files)
  continue: hg rebase --continue

  $ hg continue
  already rebased 1:b4bffa6e4776 qbase r1 "r1" as 057f55ff8f44
  already rebased 2:c0fd129beb01 r2 "r2" as 1660ab13ce9a
  already rebased 3:6ff5b8feed8e r3 "r3" as 1660ab13ce9a
  rebasing 4:094320fec554 r4 "r4"
  note: not rebasing 4:094320fec554 r4 "r4", its destination already has all its changes
  rebasing 5:681a378595ba r5 "r5"
  rebasing 6:512a1f24768b qtip r6 "r6"
  note: not rebasing 6:512a1f24768b qtip r6 "r6", its destination already has all its changes
  saved backup bundle to $TESTTMP/b/.hg/strip-backup/b4bffa6e4776-b9bfb84d-rebase.hg

  $ hg tglog
  @  8: 0b9735ce8f0a 'r5' tags: qtip r5 tip
  |
  o  7: 1660ab13ce9a 'r2' tags: qbase r2
  |
  o  6: 057f55ff8f44 'branch2-r6' tags: qparent
  |
  o  5: 1d7287f8deb1 'branch2-r4' tags:
  |
  o  4: 3c10b9db2bd5 'branch2-r8' tags:
  |
  o  3: b684023158dc 'branch2-r7' tags:
  |
  o  2: d817754b1251 'branch2-r3' tags:
  |
  o  1: 0621a206f8a4 'branch2-r1' tags:
  |
  o  0: 222799e2f90b 'r0' tags:
  

  $ cd ..
