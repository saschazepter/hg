  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > drawdag=$TESTDIR/drawdag.py
  > 
  > [phases]
  > publish=False
  > 
  > [alias]
  > tglog = log -G --template "{rev}:{phase} '{desc}' {branches} {bookmarks}\n"
  > EOF

  $ hg init a
  $ cd a
  $ echo c1 >common
  $ hg add common
  $ hg ci -m C1

  $ echo c2 >>common
  $ hg ci -m C2

  $ echo c3 >>common
  $ hg ci -m C3

  $ hg up -q -C 1

  $ echo l1 >>extra
  $ hg add extra
  $ hg ci -m L1
  created new head

  $ sed -e 's/c2/l2/' common > common.new
  $ mv common.new common
  $ hg ci -m L2

  $ echo l3 >> extra2
  $ hg add extra2
  $ hg ci -m L3
  $ hg bookmark mybook

  $ hg phase --force --secret 4

  $ hg tglog
  @  5:secret 'L3'  mybook
  |
  o  4:secret 'L2'
  |
  o  3:draft 'L1'
  |
  | o  2:draft 'C3'
  |/
  o  1:draft 'C2'
  |
  o  0:draft 'C1'
  
Try to call --continue:

  $ hg rebase --continue
  abort: no rebase in progress
  [20]

Conflicting rebase:

  $ hg rebase -s 3 -d 2
  rebasing 3:3163e20567cc "L1"
  rebasing 4:46f0b057b5c0 "L2"
  merging common
  warning: conflicts while merging common! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]

  $ hg status --config commands.status.verbose=1
  M common
  ? common.orig
  # The repository is in an unfinished *rebase* state.
  
  # Unresolved merge conflicts:
  # 
  #     common
  # 
  # To mark files as resolved:  hg resolve --mark FILE
  
  # To continue:    hg rebase --continue
  # To abort:       hg rebase --abort
  # To stop:        hg rebase --stop
  

Try to continue without solving the conflict:

  $ hg rebase --continue
  abort: unresolved merge conflicts (see 'hg help resolve')
  [20]

Conclude rebase:

  $ echo 'resolved merge' >common
  $ hg resolve -m common
  (no more unresolved files)
  continue: hg rebase --continue
  $ hg rebase --continue
  already rebased 3:3163e20567cc "L1" as 3e046f2ecedb
  rebasing 4:46f0b057b5c0 "L2"
  rebasing 5:8029388f38dc mybook "L3"
  saved backup bundle to $TESTTMP/a/.hg/strip-backup/3163e20567cc-5ca4656e-rebase.hg

  $ hg tglog
  @  5:secret 'L3'  mybook
  |
  o  4:secret 'L2'
  |
  o  3:draft 'L1'
  |
  o  2:draft 'C3'
  |
  o  1:draft 'C2'
  |
  o  0:draft 'C1'
  
Check correctness:

  $ hg cat -r 0 common
  c1

  $ hg cat -r 1 common
  c1
  c2

  $ hg cat -r 2 common
  c1
  c2
  c3

  $ hg cat -r 3 common
  c1
  c2
  c3

  $ hg cat -r 4 common
  resolved merge

  $ hg cat -r 5 common
  resolved merge

Bookmark stays active after --continue
  $ hg bookmarks
   * mybook                    5:d67b21408fc0

  $ cd ..

Check that the right ancestors is used while rebasing a merge (issue4041)

  $ hg init issue4041
  $ cd issue4041
  $ hg unbundle "$TESTDIR/bundles/issue4041.hg"
  adding changesets
  adding manifests
  adding file changes
  added 11 changesets with 8 changes to 3 files (+1 heads)
  new changesets 24797d4f68de:2f2496ddf49d (11 drafts)
  (run 'hg heads' to see heads)
  $ hg up default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg log -G
  o    changeset:   10:2f2496ddf49d
  |\   branch:      f1
  | |  tag:         tip
  | |  parent:      7:4c9fbe56a16f
  | |  parent:      9:e31216eec445
  | |  user:        szhang
  | |  date:        Thu Sep 05 12:59:39 2013 -0400
  | |  summary:     merge
  | |
  | o  changeset:   9:e31216eec445
  | |  branch:      f1
  | |  user:        szhang
  | |  date:        Thu Sep 05 12:59:10 2013 -0400
  | |  summary:     more changes to f1
  | |
  | o    changeset:   8:8e4e2c1a07ae
  | |\   branch:      f1
  | | |  parent:      2:4bc80088dc6b
  | | |  parent:      6:400110238667
  | | |  user:        szhang
  | | |  date:        Thu Sep 05 12:57:59 2013 -0400
  | | |  summary:     bad merge
  | | |
  o | |  changeset:   7:4c9fbe56a16f
  |/ /   branch:      f1
  | |    parent:      2:4bc80088dc6b
  | |    user:        szhang
  | |    date:        Thu Sep 05 12:54:00 2013 -0400
  | |    summary:     changed f1
  | |
  | o  changeset:   6:400110238667
  | |  branch:      f2
  | |  parent:      4:12e8ec6bb010
  | |  user:        szhang
  | |  date:        Tue Sep 03 13:58:02 2013 -0400
  | |  summary:     changed f2 on f2
  | |
  | | @  changeset:   5:d79e2059b5c0
  | | |  parent:      3:8a951942e016
  | | |  user:        szhang
  | | |  date:        Tue Sep 03 13:57:39 2013 -0400
  | | |  summary:     changed f2 on default
  | | |
  | o |  changeset:   4:12e8ec6bb010
  | |/   branch:      f2
  | |    user:        szhang
  | |    date:        Tue Sep 03 13:57:18 2013 -0400
  | |    summary:     created f2 branch
  | |
  | o  changeset:   3:8a951942e016
  | |  parent:      0:24797d4f68de
  | |  user:        szhang
  | |  date:        Tue Sep 03 13:57:11 2013 -0400
  | |  summary:     added f2.txt
  | |
  o |  changeset:   2:4bc80088dc6b
  | |  branch:      f1
  | |  user:        szhang
  | |  date:        Tue Sep 03 13:56:20 2013 -0400
  | |  summary:     added f1.txt
  | |
  o |  changeset:   1:ef53c9e6b608
  |/   branch:      f1
  |    user:        szhang
  |    date:        Tue Sep 03 13:55:26 2013 -0400
  |    summary:     created f1 branch
  |
  o  changeset:   0:24797d4f68de
     user:        szhang
     date:        Tue Sep 03 13:55:08 2013 -0400
     summary:     added default.txt
  
  $ hg rebase -s9 -d2 --debug # use debug to really check merge base used
  rebase onto 4bc80088dc6b starting from e31216eec445
  rebasing on disk
  rebase status stored
  rebasing 9:e31216eec445 "more changes to f1"
   future parents are 2 and -1
   update to 2:4bc80088dc6b
  resolving manifests
   branchmerge: False, force: True, partial: False
   ancestor: d79e2059b5c0+, local: d79e2059b5c0+, remote: 4bc80088dc6b
   f2.txt: other deleted -> r
  removing f2.txt
   f1.txt: remote created -> g
  getting f1.txt
   merge against 9:e31216eec445
     detach base 8:8e4e2c1a07ae
  resolving manifests
   branchmerge: True, force: True, partial: False
   ancestor: 8e4e2c1a07ae, local: 4bc80088dc6b+, remote: e31216eec445
   f1.txt: remote is newer -> g
  getting f1.txt
  committing files:
  f1.txt
  committing manifest
  committing changelog
  updating the branch cache
  rebased as 19c888675e13
  rebase status stored
  rebasing 10:2f2496ddf49d tip "merge"
   future parents are 11 and 7
   already in destination
   merge against 10:2f2496ddf49d
     detach base 9:e31216eec445
  resolving manifests
   branchmerge: True, force: True, partial: False
   ancestor: e31216eec445, local: 19c888675e13+, remote: 2f2496ddf49d
   f1.txt: remote is newer -> g
  getting f1.txt
  committing files:
  f1.txt
  committing manifest
  committing changelog
  updating the branch cache
  rebased as c1ffa3b5274e
  rebase status stored
  rebase merging completed
  update back to initial working directory parent
  resolving manifests
   branchmerge: False, force: False, partial: False
   ancestor: c1ffa3b5274e, local: c1ffa3b5274e+, remote: d79e2059b5c0
   f1.txt: other deleted -> r
  removing f1.txt
   f2.txt: remote created -> g
  getting f2.txt
  2 changesets found
  list of changesets:
  e31216eec445e44352c5f01588856059466a24c9
  2f2496ddf49d69b5ef23ad8cf9fb2e0e4faf0ac2
  bundle2-output-bundle: "HG20", (1 params) 3 parts total
  bundle2-output-part: "changegroup" (params: 1 mandatory 1 advisory) streamed payload
  bundle2-output-part: "cache:rev-branch-cache" (advisory) streamed payload
  bundle2-output-part: "phase-heads" 24 bytes payload
  saved backup bundle to $TESTTMP/issue4041/.hg/strip-backup/e31216eec445-15f7a814-rebase.hg
  3 changesets found
  list of changesets:
  4c9fbe56a16f30c0d5dcc40ec1a97bbe3325209c
  19c888675e133ab5dff84516926a65672eaf04d9
  c1ffa3b5274e92a9388fe782854e295d2e8d0443
  bundle2-output-bundle: "HG20", 3 parts total
  bundle2-output-part: "changegroup" (params: 1 mandatory 1 advisory) streamed payload
  bundle2-output-part: "cache:rev-branch-cache" (advisory) streamed payload
  bundle2-output-part: "phase-heads" 24 bytes payload
  adding branch
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "changegroup" (params: 1 mandatory 1 advisory) supported
  adding changesets
  add changeset 4c9fbe56a16f
  add changeset 19c888675e13
  add changeset c1ffa3b5274e
  adding manifests
  adding file changes
  adding f1.txt revisions
  bundle2-input-part: total payload size 1686
  bundle2-input-part: "cache:rev-branch-cache" (advisory) supported
  bundle2-input-part: total payload size 74
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 3 parts total
  truncating cache/rbc-revs-v1 to 72
  added 2 changesets with 2 changes to 1 files
  updating the branch cache
  invalid branch cache (served): tip differs
  invalid branch cache (served.hidden): tip differs
  rebase completed

Test minimization of merge conflicts
  $ hg up -q null
  $ echo a > a
  $ hg add a
  $ hg commit -q -m 'a'
  $ echo b >> a
  $ hg commit -q -m 'ab'
  $ hg bookmark ab
  $ hg up -q '.^'
  $ echo b >> a
  $ echo c >> a
  $ hg commit -q -m 'abc'
  $ hg rebase -s 7bc217434fc1 -d ab --keep
  rebasing 13:7bc217434fc1 tip "abc"
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]
  $ hg diff
  diff -r 328e4ab1f7cc a
  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	* (glob)
  @@ -1,2 +1,6 @@
   a
   b
  +<<<<<<< dest:   328e4ab1f7cc ab - test: ab
  +=======
  +c
  +>>>>>>> source: 7bc217434fc1 - test: abc
  $ hg rebase --abort
  rebase aborted
  $ hg up -q -C 7bc217434fc1
  $ hg rebase -s . -d ab --keep -t internal:merge3
  rebasing 13:7bc217434fc1 tip "abc"
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]
  $ hg diff
  diff -r 328e4ab1f7cc a
  --- a/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/a	* (glob)
  @@ -1,2 +1,8 @@
   a
  +<<<<<<< dest:             328e4ab1f7cc ab - test: ab
   b
  +||||||| parent of source: cb9a9f314b8b - test: a
  +=======
  +b
  +c
  +>>>>>>> source:           7bc217434fc1 - test: abc

Test rebase with obsstore turned on and off (issue5606)

  $ cd $TESTTMP
  $ hg init b
  $ cd b
  $ hg debugdrawdag <<'EOS'
  > D
  > |
  > C
  > |
  > B E
  > |/
  > A
  > EOS

  $ hg update E -q
  $ echo 3 > B
  $ hg commit --amend -m E -A B -q
  $ hg rebase -r B+D -d . --config experimental.evolution=true
  rebasing 1:112478962961 B "B"
  merging B
  warning: conflicts while merging B! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]

  $ echo 4 > B
  $ hg resolve -m
  (no more unresolved files)
  continue: hg rebase --continue
  $ hg rebase --continue --config experimental.evolution=none
  rebasing 1:112478962961 B "B"
  rebasing 3:f585351a92f8 D "D"
  warning: orphaned descendants detected, not stripping 112478962961
  saved backup bundle to $TESTTMP/b/.hg/strip-backup/f585351a92f8-e536a9e4-rebase.hg

  $ rm .hg/localtags
  $ hg tglog
  o  5:draft 'D'
  |
  o  4:draft 'B'
  |
  @  3:draft 'E'
  |
  | o  2:draft 'C'
  | |
  | o  1:draft 'B'
  |/
  o  0:draft 'A'
  

Test where the conflict happens when rebasing a merge commit

  $ cd $TESTTMP
  $ hg init conflict-in-merge
  $ cd conflict-in-merge
  $ hg debugdrawdag <<'EOS'
  > F # F/conflict = foo\n
  > |\
  > D E
  > |/
  > C B # B/conflict = bar\n
  > |/
  > A
  > EOS

  $ hg co F
  5 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg rebase -d B
  rebasing 2:dc0947a82db8 C "C"
  rebasing 3:e7b3f00ed42e D "D"
  rebasing 4:03ca77807e91 E "E"
  rebasing 5:9a6b91dc2044 F tip "F"
  merging conflict
  warning: conflicts while merging conflict! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]
  $ hg tglog
  @  8:draft 'E'
  |
  | @  7:draft 'D'
  |/
  o  6:draft 'C'
  |
  | %    5:draft 'F'
  | |\
  | | o  4:draft 'E'
  | | |
  | o |  3:draft 'D'
  | |/
  | o  2:draft 'C'
  | |
  o |  1:draft 'B'
  |/
  o  0:draft 'A'
  
  $ echo baz > conflict
  $ hg resolve -m
  (no more unresolved files)
  continue: hg rebase --continue
  $ hg rebase -c
  already rebased 2:dc0947a82db8 C "C" as 0199610c343e
  already rebased 3:e7b3f00ed42e D "D" as f0dd538aaa63
  already rebased 4:03ca77807e91 E "E" as cbf25af8347d
  rebasing 5:9a6b91dc2044 F "F"
  saved backup bundle to $TESTTMP/conflict-in-merge/.hg/strip-backup/dc0947a82db8-ca7e7d5b-rebase.hg
  $ hg tglog
  @    5:draft 'F'
  |\
  | o  4:draft 'E'
  | |
  o |  3:draft 'D'
  |/
  o  2:draft 'C'
  |
  o  1:draft 'B'
  |
  o  0:draft 'A'
  
