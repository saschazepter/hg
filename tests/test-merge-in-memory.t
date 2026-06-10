=============================
test in-memory merge commands
=============================


Basic repository setup
======================

  $ . $TESTDIR/testlib/common.sh
  $ hg init repo
  $ cd repo
  $ mkcommit root
  $ mkcommit foo_1
  $ mkcommit foo_2
  $ mkcommit foo_3
  $ hg up 'desc(root)'
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved

have some commit on a different branch to verify it is properly inherited.

  $ hg branch bar
  marked working directory as branch bar
  (branches are permanent and global, did you want a bookmark?)
  $ mkcommit bar_1
  $ mkcommit bar_2

  $ echo "bar_one" >> bar_1
  $ hg commit -m "bar_u1u"
  $ hg up 'desc(foo_3)'
  3 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo "bar_one" > bar_1
  $ hg add bar_1
  $ hg commit -m "bar_one"
  $ hg mv bar_1 bar_one
  $ hg commit -m "mv_bar_m1m"

  $ hg up null
  0 files updated, 0 files merged, 5 files removed, 0 files unresolved
  $ hg log -G -T '{desc}\n'
  o  mv_bar_m1m
  |
  o  bar_one
  |
  | o  bar_u1u
  | |
  | o  bar_2
  | |
  | o  bar_1
  | |
  o |  foo_3
  | |
  o |  foo_2
  | |
  o |  foo_1
  |/
  o  root
  

Test simple succesful merge
===========================

  $ hg script::merge 'desc(foo_1)' 'desc(bar_1)' --dry-run
  $ hg log -G --rev 'max(all())'
  o  changeset:   8:fe78063b6eca
  |  tag:         tip
  ~  user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     mv_bar_m1m
  

  $ hg script::merge --message merge_f1_b1 'desc(foo_1)' 'desc(bar_1)'
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   9:cabd17bbe5e3
  |\   tag:         tip
  | |  parent:      1:91486e5cbecd
  | |  parent:      4:a688525a34e6
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_f1_b1
  | |
  | o  changeset:   4:a688525a34e6
  | |  branch:      bar
  | ~  parent:      0:1e4be0697311
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     bar_1
  |
  o  changeset:   1:91486e5cbecd
  |  user:        test
  ~  date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     foo_1
  

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 10 changesets with 9 changes to 7 files


Test simple conflicting merge
=============================

  $ hg script::merge 'desc(bar_1)' 'desc(bar_one)' --dry-run
  merging bar_1
  [2]
  $ hg log -G --rev 'max(all())'
  o    changeset:   9:cabd17bbe5e3
  |\   tag:         tip
  ~ ~  parent:      1:91486e5cbecd
       parent:      4:a688525a34e6
       user:        test
       date:        Thu Jan 01 00:00:00 1970 +0000
       summary:     merge_f1_b1
  

  $ hg script::merge --message merge_b1_b1l 'desc(bar_1)' 'desc(bar_one)'
  merging bar_1
  abort: cannot merge in memory: merge conflicts
  (in-memory merge does not support merge conflicts)
  [255]
  $ hg log -G --rev 'max(all())'
  o    changeset:   9:cabd17bbe5e3
  |\   tag:         tip
  ~ ~  parent:      1:91486e5cbecd
       parent:      4:a688525a34e6
       user:        test
       date:        Thu Jan 01 00:00:00 1970 +0000
       summary:     merge_f1_b1
  

providing a working tool should make the commit work.

  $ hg script::merge --message merge_b1_b1l 'desc(bar_1)' 'desc(bar_one)' --tool :union
  merging bar_1
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   10:7bedac8ea1ba
  |\   branch:      bar
  | |  tag:         tip
  | |  parent:      4:a688525a34e6
  | |  parent:      7:4a5749e317d0
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_b1_b1l
  | |
  | o  changeset:   7:4a5749e317d0
  | |  parent:      3:49ec3c64341f
  | ~  user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     bar_one
  |
  o  changeset:   4:a688525a34e6
  |  branch:      bar
  ~  parent:      0:1e4be0697311
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     bar_1
  


  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 11 changesets with 10 changes to 7 files

  $ hg cat --rev 'desc("merge_b1_b1l")' bar_1
  bar_1
  bar_one
  $ hg debugindex bar_1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 63cf2de169d1 000000000000 000000000000
       1       6 313fc53bd0dd 63cf2de169d1 000000000000
       2       7 66a9cc4d33e0 000000000000 000000000000
       3      10 fa2219023f74 63cf2de169d1 66a9cc4d33e0

Merge with identical file content
=================================

This should still do merge revision at in the filelog

  $ hg script::merge --message merge_b1b1l_b1u 'desc(merge_b1_b1l)' 'desc(bar_u1u)'
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   11:0fe4b767506e
  |\   branch:      bar
  | |  tag:         tip
  | |  parent:      10:7bedac8ea1ba
  | |  parent:      6:9c3e30f8d860
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_b1b1l_b1u
  | |
  | o    changeset:   10:7bedac8ea1ba
  | |\   branch:      bar
  | ~ ~  parent:      4:a688525a34e6
  |      parent:      7:4a5749e317d0
  |      user:        test
  |      date:        Thu Jan 01 00:00:00 1970 +0000
  |      summary:     merge_b1_b1l
  |
  o  changeset:   6:9c3e30f8d860
  |  branch:      bar
  ~  user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     bar_u1u
  

  $ hg cat --rev 'desc("merge_b1b1l_b1u")' bar_1
  bar_1
  bar_one
  $ hg debugindex bar_1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 63cf2de169d1 000000000000 000000000000
       1       6 313fc53bd0dd 63cf2de169d1 000000000000
       2       7 66a9cc4d33e0 000000000000 000000000000
       3      10 fa2219023f74 63cf2de169d1 66a9cc4d33e0
       4      11 d9ea39ad2f1a fa2219023f74 313fc53bd0dd

Merge with reverted file content
================================

This should still create merge revision in the target filelog

  $ hg script::merge --message merge_local_b1_b1l 'desc(bar_1)' 'desc(bar_one)' --tool :local
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   12:adadc057505f
  |\   branch:      bar
  | |  tag:         tip
  | |  parent:      4:a688525a34e6
  | |  parent:      7:4a5749e317d0
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_local_b1_b1l
  | |
  | o  changeset:   7:4a5749e317d0
  | |  parent:      3:49ec3c64341f
  | ~  user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     bar_one
  |
  o  changeset:   4:a688525a34e6
  |  branch:      bar
  ~  parent:      0:1e4be0697311
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     bar_1
  

  $ hg script::merge --message merge_other_b1_b1l 'desc(bar_1)' 'desc(bar_one)' --tool :other
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   13:283c26eb6d48
  |\   branch:      bar
  | |  tag:         tip
  | |  parent:      4:a688525a34e6
  | |  parent:      7:4a5749e317d0
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_other_b1_b1l
  | |
  | o  changeset:   7:4a5749e317d0
  | |  parent:      3:49ec3c64341f
  | ~  user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     bar_one
  |
  o  changeset:   4:a688525a34e6
  |  branch:      bar
  ~  parent:      0:1e4be0697311
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     bar_1
  

  $ hg cat --rev 'desc("merge_local_b1_b1l")' bar_1
  bar_1
  $ hg cat --rev 'desc("merge_other_b1_b1l")' bar_1
  bar_one
  $ hg debugindex bar_1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 63cf2de169d1 000000000000 000000000000
       1       6 313fc53bd0dd 63cf2de169d1 000000000000
       2       7 66a9cc4d33e0 000000000000 000000000000
       3      10 fa2219023f74 63cf2de169d1 66a9cc4d33e0
       4      11 d9ea39ad2f1a fa2219023f74 313fc53bd0dd
       5      12 446a05cc2c1a 63cf2de169d1 66a9cc4d33e0
       6      13 f0fcc0b7ba2d 63cf2de169d1 66a9cc4d33e0

Merge with file rename
================================

  $ hg script::merge --message merge_mv_b1_left 'desc(merge_b1_b1l)' 'desc(mv_bar_m1m)'
  merging bar_1 and bar_one to bar_one
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   14:201755c7ee90
  |\   branch:      bar
  | |  tag:         tip
  | |  parent:      10:7bedac8ea1ba
  | |  parent:      8:fe78063b6eca
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_mv_b1_left
  | |
  | o    changeset:   10:7bedac8ea1ba
  | |\   branch:      bar
  | ~ ~  parent:      4:a688525a34e6
  |      parent:      7:4a5749e317d0
  |      user:        test
  |      date:        Thu Jan 01 00:00:00 1970 +0000
  |      summary:     merge_b1_b1l
  |
  o  changeset:   8:fe78063b6eca
  |  user:        test
  ~  date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     mv_bar_m1m
  

  $ hg script::merge --message merge_mv_b1_right 'desc(mv_bar_m1m)' 'desc(merge_b1_b1l)'
  merging bar_one and bar_1 to bar_one
  $ hg log -G --rev 'max(all())#g[-1:0]'
  o    changeset:   15:09883219dc82
  |\   tag:         tip
  | |  parent:      8:fe78063b6eca
  | |  parent:      10:7bedac8ea1ba
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge_mv_b1_right
  | |
  | o    changeset:   10:7bedac8ea1ba
  | |\   branch:      bar
  | ~ ~  parent:      4:a688525a34e6
  |      parent:      7:4a5749e317d0
  |      user:        test
  |      date:        Thu Jan 01 00:00:00 1970 +0000
  |      summary:     merge_b1_b1l
  |
  o  changeset:   8:fe78063b6eca
  |  user:        test
  ~  date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     mv_bar_m1m
  

  $ hg status --from 'desc(mv_bar_m1m)' --to 'desc(merge_mv_b1_left)'
  M bar_one
  $ hg status --from 'desc(merge_b1_b1l)' --to 'desc(merge_mv_b1_left)'
  A bar_one
  R bar_1
  $ hg status --from 'desc(mv_bar_m1m)' --to 'desc(merge_mv_b1_right)'
  M bar_one
  $ hg status --from 'desc(merge_b1_b1l)' --to 'desc(merge_mv_b1_right)'
  A bar_one
  R bar_1
  $ hg diff --change 'desc(merge_mv_b1_left)' --config diff.merge=yes
  $ hg diff --change 'desc(merge_mv_b1_right)' --config diff.merge=yes
  $ hg cat --rev 'desc("merge_mv_b1_left")' bar_one
  bar_1
  bar_one
  $ hg cat --rev 'desc("merge_mv_b1_right")' bar_one
  bar_1
  bar_one
  $ hg debugindex bar_1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 63cf2de169d1 000000000000 000000000000
       1       6 313fc53bd0dd 63cf2de169d1 000000000000
       2       7 66a9cc4d33e0 000000000000 000000000000
       3      10 fa2219023f74 63cf2de169d1 66a9cc4d33e0
       4      11 d9ea39ad2f1a fa2219023f74 313fc53bd0dd
       5      12 446a05cc2c1a 63cf2de169d1 66a9cc4d33e0
       6      13 f0fcc0b7ba2d 63cf2de169d1 66a9cc4d33e0
  $ hg debugindex bar_one
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       8 79dc8b0bb824 000000000000 000000000000
       1      14 e06923736492 79dc8b0bb824 000000000000


Test when there is nothing to merge
===================================

  $ hg script::merge 'desc(bar_1)' 'desc(bar_1)' --dry-run
  abort: merging with a working directory ancestor has no effect
  [255]
  $ hg script::merge --message merge_same_b1_b1 'desc(bar_1)' 'desc(bar_1)'
  abort: merging with a working directory ancestor has no effect
  [255]
  $ hg script::merge 'desc(bar_1)' 'desc(bar_2)' --dry-run
  abort: nothing to merge
  (use 'hg update' or check 'hg heads')
  [255]
  $ hg script::merge --message merge_same_b1_b2 'desc(bar_1)' 'desc(bar_2)'
  abort: nothing to merge
  (use 'hg update' or check 'hg heads')
  [255]

Test template usage
===================

  $ hg script::merge --message merge_f3_b2 'desc(foo_3)' 'desc(bar_2)' \
  >    --template '{node}\n{p1}\n{p2}\n{desc}\n'
  462148309d33601192d2bd24dd4d2469d8df8c02
  3:49ec3c64341f
  5:a349f34727bb
  merge_f3_b2

Using --template silence the other messages

  $ hg script::merge --message merge_with_status_message 'desc(mv_bar_m1m)' 'desc(merge_b1_b1l)'
  merging bar_one and bar_1 to bar_one

  $ hg script::merge --message merge_without_status_message 'desc(mv_bar_m1m)' 'desc(merge_b1_b1l)' \
  >    --template '{node}\n{p1}\n{p2}\n{desc}\n'
  0b46603e0a2dfbbd2af625f615edfa04b1859065
  8:fe78063b6eca
  10:7bedac8ea1ba
  merge_without_status_message

  $ cd ..

Test history of file reversion
==============================

create a branching repo, one branch with the initial file content, and one
branch with the file reverted to that initial content

The merge should always use the reverted file-nodeid

  $ hg init repo-merge-revert
  $ cd repo-merge-revert
  $ mkcommit initial
  $ mkcommit file
  $ echo babar >> file
  $ hg commit -m update
  $ hg revert --rev 'desc("file")' file
  $ hg commit -m 'revert'
  $ hg update 'desc("file")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ mkcommit unrelated
  created new head
  $ hg up null
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved

  $ hg log -Gv
  o  changeset:   4:a4e0ee299fbc
  |  tag:         tip
  |  parent:      1:ff6fa6fae305
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       unrelated
  |  description:
  |  unrelated
  |
  |
  | o  changeset:   3:3174de5a8de5
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  files:       file
  | |  description:
  | |  revert
  | |
  | |
  | o  changeset:   2:99b9cb3f593c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    files:       file
  |    description:
  |    update
  |
  |
  o  changeset:   1:ff6fa6fae305
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       file
  |  description:
  |  file
  |
  |
  o  changeset:   0:630839011471
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     files:       initial
     description:
     initial
  
  

  $ hg debugindex file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       1 9c9a2d952e40 000000000000 000000000000
       1       2 b336e38e6a17 9c9a2d952e40 000000000000
       2       3 47b5662761cf b336e38e6a17 000000000000

Merge in both direction, both result should use the "reverted" nodeid. Not the
original content.

  $ hg script::merge --message rev_is_p1 'desc("revert")' 'desc("unrelated")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 5
  $ hg manifest --debug --rev 'desc("rev_is_p1")' | grep file
  47b5662761cf7ffabf67a7a9c911976505d05e56 644   file

  $ hg script::merge --message rev_is_p2 'desc("unrelated")' 'desc("revert")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 6
  $ hg manifest --debug --rev 'desc("rev_is_p2")' | grep file
  47b5662761cf7ffabf67a7a9c911976505d05e56 644   file

no new file revision should have been created

  $ hg debugindex file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       1 9c9a2d952e40 000000000000 000000000000
       1       2 b336e38e6a17 9c9a2d952e40 000000000000
       2       3 47b5662761cf b336e38e6a17 000000000000


Test history of file restored and remerged
==========================================

create The following scenario for the revision of a file X

.   2   (The merge we are testing here)
.  / \
. 0   |
. |\  |
. 0 ø 2
. | |/
. | 2 (same content as 0)
. | |
. | 1
. |/
. 0
. |
. …

We want the merge to use revision number 2 otherwise, we would a commit with
revision 0 as a child of a commit with revision 2.

XXX This is currently broken for both in-memory merge, in-working-copy merge.
XXX The in-memory merge version is slightly less broken. Even if thAe behavior is
XXX currently bad. It seems important to explicilty test this case.



  $ hg init repo-merge-salvaged
  $ cd repo-merge-salvaged
  $ echo babar >> file
  $ hg add file
  $ hg commit -m root
  $ echo Babar >> file
  $ hg commit -m update_1
  $ hg revert --rev 'desc("root")' file
  $ hg commit -m update_2
  $ mkcommit unrelated_2
  $ hg up 'desc("update_2")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg rm file
  $ hg commit -m delete_2
  created new head
  $ hg up 'desc("root")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ mkcommit unrelated_0
  created new head
  $ hg merge 'desc("delete_2")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg revert --rev 'desc("root")' file
  $ hg commit -m "merge_0_deleted"
  $ hg up null
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved

  $ hg log -Gv
  o    changeset:   6:387f782fc4cb
  |\   tag:         tip
  | |  parent:      5:e49b723ecf12
  | |  parent:      4:f067ce192039
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  description:
  | |  merge_0_deleted
  | |
  | |
  | o  changeset:   5:e49b723ecf12
  | |  parent:      0:87177078645e
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  files:       unrelated_0
  | |  description:
  | |  unrelated_0
  | |
  | |
  o |  changeset:   4:f067ce192039
  | |  parent:      2:6eeb7d264f46
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  files:       file
  | |  description:
  | |  delete_2
  | |
  | |
  +---o  changeset:   3:44f867aec9c9
  | |    user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    files:       unrelated_2
  | |    description:
  | |    unrelated_2
  | |
  | |
  o |  changeset:   2:6eeb7d264f46
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  files:       file
  | |  description:
  | |  update_2
  | |
  | |
  o |  changeset:   1:81f1361a4a4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    files:       file
  |    description:
  |    update_1
  |
  |
  o  changeset:   0:87177078645e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     files:       file
     description:
     root
  
  

  $ hg debugindex file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 360afd990eef 000000000000 000000000000
       1       1 694c100a2d5d 360afd990eef 000000000000
       2       2 0ac6f5e10d22 694c100a2d5d 000000000000

Merge in both direction, both result should use the "reverted" nodeid. Not the
original content.

  $ hg script::merge --message merge_red 'desc("merge_0_deleted")' 'desc("unrelated_2")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 7
  $ hg manifest --debug --rev 'desc("merge_red")' | grep file
  360afd990eeff79e4a7f9f3ded5ecd7bc2fd3b59 644   file (known-bad-output !)
  0ac6f5e10d22db9061d21c68f5eb88e75ac0fea0 644   file (missing-correct-output !)

  $ hg script::merge --message merge_blue 'desc("unrelated_2")' 'desc("merge_0_deleted")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 8
  $ hg manifest --debug --rev 'desc("merge_blue")' | grep file
  0ac6f5e10d22db9061d21c68f5eb88e75ac0fea0 644   file

double check with the non-in-memory version

  $ hg up 'desc("merge_0_deleted")'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge 'desc("unrelated_2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit --message "merge_wc_red"
  created new head
  $ hg manifest --debug --rev 'desc("merge_wc_red")' | grep file
  360afd990eeff79e4a7f9f3ded5ecd7bc2fd3b59 644   file (known-bad-output !)
  0ac6f5e10d22db9061d21c68f5eb88e75ac0fea0 644   file (missing-correct-output !)

  $ hg up 'desc("unrelated_2")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("merge_0_deleted")'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit --message "merge_wc_blue"
  created new head
  $ hg manifest --debug --rev 'desc("merge_wc_blue")' | grep file
  360afd990eeff79e4a7f9f3ded5ecd7bc2fd3b59 644   file (known-bad-output !)
  0ac6f5e10d22db9061d21c68f5eb88e75ac0fea0 644   file (missing-correct-output !)

no new file revision should have been created

  $ hg debugindex file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 360afd990eef 000000000000 000000000000
       1       1 694c100a2d5d 360afd990eef 000000000000
       2       2 0ac6f5e10d22 694c100a2d5d 000000000000

  $ cd ..


Test merging in memory with a working copy
==========================================

Test merging in memory with a working copy not on the null revision

  $ hg init repo-merge-with-wc
  $ cd repo-merge-with-wc
  $ mkcommit root
  $ mkcommit c_red
  $ hg up --quiet 'desc("root")'
  $ mkcommit c_blue
  created new head
  $ hg up --quiet 'desc("root")'
  $ mkcommit c_green
  created new head

  $ hg log -G
  @  changeset:   3:0e9f2a6e913e
  |  tag:         tip
  |  parent:      0:1e4be0697311
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     c_green
  |
  | o  changeset:   2:5286421d3f76
  |/   parent:      0:1e4be0697311
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     c_blue
  |
  | o  changeset:   1:100e9b013162
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     c_red
  |
  o  changeset:   0:1e4be0697311
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  


Two revision unrelated to the wc parent

  $ hg script::merge --message merge_red_blue 'desc("c_red")' 'desc("c_blue")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 4

wc as p2

  $ hg script::merge --message merge_red_green 'desc("c_red")' 'desc("c_green")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 5

wc as p2

  $ hg script::merge --message merge_green_blue 'desc("c_green")' 'desc("c_blue")' \
  >     -T 'merge-rev: {rev}\n'
  merge-rev: 6
