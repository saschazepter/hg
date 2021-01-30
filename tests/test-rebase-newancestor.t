  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > drawdag=$TESTDIR/drawdag.py
  > [alias]
  > tglog = log -G --template "{rev}: {node|short} '{desc}' {branches}\n"
  > EOF

  $ hg init repo
  $ cd repo

  $ echo A > a
  $ echo >> a
  $ hg ci -Am A
  adding a

  $ echo B > a
  $ echo >> a
  $ hg ci -m B

  $ echo C > a
  $ echo >> a
  $ hg ci -m C

  $ hg up -q -C 0

  $ echo D >> a
  $ hg ci -Am AD
  created new head

  $ hg tglog
  @  3: 3878212183bd 'AD'
  |
  | o  2: 30ae917c0e4f 'C'
  | |
  | o  1: 0f4f7cb4f549 'B'
  |/
  o  0: 1e635d440a73 'A'
  
  $ hg rebase -s 1 -d 3
  rebasing 1:0f4f7cb4f549 "B"
  merging a
  rebasing 2:30ae917c0e4f "C"
  merging a
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/0f4f7cb4f549-82b3b163-rebase.hg

  $ hg tglog
  o  3: 25773bc4b4b0 'C'
  |
  o  2: c09015405f75 'B'
  |
  @  1: 3878212183bd 'AD'
  |
  o  0: 1e635d440a73 'A'
  

  $ cd ..


Test rebasing of merges with ancestors of the rebase destination - a situation
that often happens when trying to recover from repeated merging with a mainline
branch.

The test case creates a dev branch that contains a couple of merges from the
default branch. When rebasing to the default branch, these merges would be
merges with ancestors on the same branch. The merges _could_ contain some
interesting conflict resolutions or additional changes in the merge commit, but
that is mixed up with the actual merge stuff and there is in general no way to
separate them.

  $ hg init ancestor-merge
  $ cd ancestor-merge

  $ touch f-default
  $ hg ci -Aqm 'default: create f-default'

  $ hg branch -q dev
  $ hg ci -qm 'dev: create branch'

  $ echo stuff > f-dev
  $ hg ci -Aqm 'dev: f-dev stuff'

  $ hg up -q default
  $ echo stuff > f-default
  $ hg ci -m 'default: f-default stuff'

  $ hg up -q dev
  $ hg merge -q default
  $ hg ci -m 'dev: merge default'

  $ hg up -q default
  $ hg rm f-default
  $ hg ci -m 'default: remove f-default'

  $ hg up -q dev
  $ hg merge -q default
  $ hg ci -m 'dev: merge default'

  $ hg up -q default
  $ echo stuff > f-other
  $ hg ci -Aqm 'default: f-other stuff'

  $ hg tglog
  @  7: e08089805d82 'default: f-other stuff'
  |
  | o  6: 010ced67e558 'dev: merge default' dev
  |/|
  o |  5: 462860db70a1 'default: remove f-default'
  | |
  | o  4: 4b019212aaf6 'dev: merge default' dev
  |/|
  o |  3: f157ecfd2b6b 'default: f-default stuff'
  | |
  | o  2: ec2c14fb2984 'dev: f-dev stuff' dev
  | |
  | o  1: 1d1a643d390e 'dev: create branch' dev
  |/
  o  0: e90e8eb90b6f 'default: create f-default'
  
  $ hg clone -qU . ../ancestor-merge-2

Full rebase all the way back from branching point:

  $ hg rebase -r 'only(dev,default)' -d default --config ui.interactive=True << EOF
  > c
  > EOF
  rebasing 1:1d1a643d390e "dev: create branch"
  note: not rebasing 1:1d1a643d390e "dev: create branch", its destination already has all its changes
  rebasing 2:ec2c14fb2984 "dev: f-dev stuff"
  rebasing 4:4b019212aaf6 "dev: merge default"
  note: not rebasing 4:4b019212aaf6 "dev: merge default", its destination already has all its changes
  rebasing 6:010ced67e558 "dev: merge default"
  note: not rebasing 6:010ced67e558 "dev: merge default", its destination already has all its changes
  saved backup bundle to $TESTTMP/ancestor-merge/.hg/strip-backup/1d1a643d390e-4a6f6d17-rebase.hg
  $ hg tglog
  o  4: 3e075b1c0a40 'dev: f-dev stuff'
  |
  @  3: e08089805d82 'default: f-other stuff'
  |
  o  2: 462860db70a1 'default: remove f-default'
  |
  o  1: f157ecfd2b6b 'default: f-default stuff'
  |
  o  0: e90e8eb90b6f 'default: create f-default'
  
Grafty cherry picking rebasing:

  $ cd ../ancestor-merge-2

  $ hg phase -fdr0:
  $ hg rebase -r 'children(only(dev,default))' -d default --config ui.interactive=True << EOF
  > c
  > EOF
  rebasing 2:ec2c14fb2984 "dev: f-dev stuff"
  rebasing 4:4b019212aaf6 "dev: merge default"
  abort: rebasing 4:4b019212aaf6 will include unwanted changes from 1:1d1a643d390e
  [10]
  $ cd ..


Test order of parents of rebased merged with un-rebased changes as p1.

  $ hg init parentorder
  $ cd parentorder
  $ touch f
  $ hg ci -Aqm common
  $ touch change
  $ hg ci -Aqm change
  $ touch target
  $ hg ci -Aqm target
  $ hg up -qr 0
  $ touch outside
  $ hg ci -Aqm outside
  $ hg merge -qr 1
  $ hg ci -m 'merge p1 3=outside p2 1=ancestor'
  $ hg par
  changeset:   4:6990226659be
  tag:         tip
  parent:      3:f59da8fc0fcf
  parent:      1:dd40c13f7a6f
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     merge p1 3=outside p2 1=ancestor
  
  $ hg up -qr 1
  $ hg merge -qr 3
  $ hg ci -qm 'merge p1 1=ancestor p2 3=outside'
  $ hg par
  changeset:   5:a57575f79074
  tag:         tip
  parent:      1:dd40c13f7a6f
  parent:      3:f59da8fc0fcf
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     merge p1 1=ancestor p2 3=outside
  
  $ hg tglog
  @    5: a57575f79074 'merge p1 1=ancestor p2 3=outside'
  |\
  +---o  4: 6990226659be 'merge p1 3=outside p2 1=ancestor'
  | |/
  | o  3: f59da8fc0fcf 'outside'
  | |
  +---o  2: a60552eb93fb 'target'
  | |
  o |  1: dd40c13f7a6f 'change'
  |/
  o  0: 02f0f58d5300 'common'
  
  $ hg rebase -r 4 -d 2
  rebasing 4:6990226659be "merge p1 3=outside p2 1=ancestor"
  saved backup bundle to $TESTTMP/parentorder/.hg/strip-backup/6990226659be-4d67a0d3-rebase.hg
  $ hg tip
  changeset:   5:cca50676b1c5
  tag:         tip
  parent:      2:a60552eb93fb
  parent:      3:f59da8fc0fcf
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     merge p1 3=outside p2 1=ancestor
  
  $ hg rebase -r 4 -d 2
  rebasing 4:a57575f79074 "merge p1 1=ancestor p2 3=outside"
  saved backup bundle to $TESTTMP/parentorder/.hg/strip-backup/a57575f79074-385426e5-rebase.hg
  $ hg tip
  changeset:   5:f9daf77ffe76
  tag:         tip
  parent:      2:a60552eb93fb
  parent:      3:f59da8fc0fcf
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     merge p1 1=ancestor p2 3=outside
  
  $ hg tglog
  @    5: f9daf77ffe76 'merge p1 1=ancestor p2 3=outside'
  |\
  +---o  4: cca50676b1c5 'merge p1 3=outside p2 1=ancestor'
  | |/
  | o  3: f59da8fc0fcf 'outside'
  | |
  o |  2: a60552eb93fb 'target'
  | |
  o |  1: dd40c13f7a6f 'change'
  |/
  o  0: 02f0f58d5300 'common'
  
rebase of merge of ancestors

  $ hg up -qr 2
  $ hg merge -qr 3
  $ echo 'other change while merging future "rebase ancestors"' > other
  $ hg ci -Aqm 'merge rebase ancestors'
  $ hg rebase -d 5 -v
  rebasing 6:4c5f12f25ebe tip "merge rebase ancestors"
  resolving manifests
  removing other
  resolving manifests
  getting other
  committing files:
  other
  committing manifest
  committing changelog
  rebase merging completed
  1 changesets found
  uncompressed size of bundle content:
       199 (changelog)
       216 (manifests)
       182  other
  saved backup bundle to $TESTTMP/parentorder/.hg/strip-backup/4c5f12f25ebe-f46990e5-rebase.hg
  1 changesets found
  uncompressed size of bundle content:
       254 (changelog)
       167 (manifests)
       182  other
  adding branch
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  rebase completed
  $ hg tglog
  @  6: 113755df812b 'merge rebase ancestors'
  |
  o    5: f9daf77ffe76 'merge p1 1=ancestor p2 3=outside'
  |\
  +---o  4: cca50676b1c5 'merge p1 3=outside p2 1=ancestor'
  | |/
  | o  3: f59da8fc0fcf 'outside'
  | |
  o |  2: a60552eb93fb 'target'
  | |
  o |  1: dd40c13f7a6f 'change'
  |/
  o  0: 02f0f58d5300 'common'
  
Due to the limitation of 3-way merge algorithm (1 merge base), rebasing a merge
may include unwanted content:

  $ hg init $TESTTMP/dual-merge-base1
  $ cd $TESTTMP/dual-merge-base1
  $ hg debugdrawdag <<'EOS'
  >   F
  >  /|
  > D E
  > | |
  > B C
  > |/
  > A Z
  > |/
  > R
  > EOS
  $ hg rebase -r D+E+F -d Z
  rebasing 5:5f2c926dfecf D "D"
  rebasing 6:b296604d9846 E "E"
  rebasing 7:caa9781e507d F tip "F"
  abort: rebasing 7:caa9781e507d will include unwanted changes from 4:d6003a550c2c or 3:c1e6b162678d
  [10]

The warning does not get printed if there is no unwanted change detected:

  $ hg init $TESTTMP/dual-merge-base2
  $ cd $TESTTMP/dual-merge-base2
  $ hg debugdrawdag <<'EOS'
  >   D
  >  /|
  > B C
  > |/
  > A Z
  > |/
  > R
  > EOS
  $ hg rebase -r B+C+D -d Z
  rebasing 3:c1e6b162678d B "B"
  rebasing 4:d6003a550c2c C "C"
  rebasing 5:c8f78076273e D tip "D"
  saved backup bundle to $TESTTMP/dual-merge-base2/.hg/strip-backup/d6003a550c2c-6f1424b6-rebase.hg
  $ hg manifest -r 'desc(D)'
  B
  C
  R
  Z

The merge base could be different from old p1 (changed parent becomes new p1):

  $ hg init $TESTTMP/chosen-merge-base1
  $ cd $TESTTMP/chosen-merge-base1
  $ hg debugdrawdag <<'EOS'
  >   F
  >  /|
  > D E
  > | |
  > B C Z
  > EOS
  $ hg rebase -r D+F -d Z
  rebasing 3:004dc1679908 D "D"
  rebasing 5:4be4cbf6f206 F tip "F"
  saved backup bundle to $TESTTMP/chosen-merge-base1/.hg/strip-backup/004dc1679908-06a66a3c-rebase.hg
  $ hg manifest -r 'desc(F)'
  C
  D
  E
  Z
  $ hg log -r `hg log -r 'desc(F)' -T '{p1node}'` -T '{desc}\n'
  D

  $ hg init $TESTTMP/chosen-merge-base2
  $ cd $TESTTMP/chosen-merge-base2
  $ hg debugdrawdag <<'EOS'
  >   F
  >  /|
  > D E
  > | |
  > B C Z
  > EOS
  $ hg rebase -r E+F -d Z
  rebasing 4:974e4943c210 E "E"
  rebasing 5:4be4cbf6f206 F tip "F"
  saved backup bundle to $TESTTMP/chosen-merge-base2/.hg/strip-backup/974e4943c210-b2874da5-rebase.hg
  $ hg manifest -r 'desc(F)'
  B
  D
  E
  Z
  $ hg log -r `hg log -r 'desc(F)' -T '{p1node}'` -T '{desc}\n'
  E
