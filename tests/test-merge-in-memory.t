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

  $ hg script::merge --message merge_f3_b2 'desc(foo_3)' 'desc(bar_2)' --template '{node}\n{p1}\n{p2}\n{desc}\n'
  462148309d33601192d2bd24dd4d2469d8df8c02
  3:49ec3c64341f
  5:a349f34727bb
  merge_f3_b2
