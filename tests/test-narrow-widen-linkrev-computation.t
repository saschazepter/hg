==============================================================================================
Test the computation of linkrev that is needed when sending file content after their changeset
==============================================================================================

Setup
=====

tree/flat make the hash unstable had are anoying, reinstall that later.
.. #testcases tree flat
  $ . "$TESTDIR/narrow-library.sh"

.. #if tree
..   $ cat << EOF >> $HGRCPATH
..   > [experimental]
..   > treemanifest = 1
..   > EOF
.. #endif

  $ hg init server
  $ cd server

We build a non linear history with some filenome that exist in parallel.

  $ echo foo > readme.txt
  $ hg add readme.txt
  $ hg ci -m 'root'
  $ mkdir dir_x
  $ echo foo > dir_x/f1
  $ echo fo0 > dir_x/f2
  $ echo f0o > dir_x/f3
  $ mkdir dir_y
  $ echo bar > dir_y/f1
  $ echo 8ar > dir_y/f2
  $ echo ba9 > dir_y/f3
  $ hg add dir_x dir_y
  adding dir_x/f1
  adding dir_x/f2
  adding dir_x/f3
  adding dir_y/f1
  adding dir_y/f2
  adding dir_y/f3
  $ hg ci -m 'rev_a_'

  $ hg update 'desc("rev_a_")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo foo-01 > dir_x/f1
  $ hg ci -m 'rev_b_0_'

  $ hg update 'desc("rev_b_0_")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo foo-02 > dir_x/f1
  $ hg ci -m 'rev_b_1_'

  $ hg update 'desc("rev_a_")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ mkdir dir_z
  $ echo bar-01 > dir_y/f1
  $ echo 8ar-01 > dir_y/f2
  $ echo babar > dir_z/f1
  $ hg add dir_z
  adding dir_z/f1
  $ hg ci -m 'rev_c_0_'
  created new head

  $ hg update 'desc("rev_c_0_")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo celeste > dir_z/f2
  $ echo zephir > dir_z/f1
  $ hg add dir_z
  adding dir_z/f2
  $ hg ci -m 'rev_c_1_'

  $ hg update 'desc("rev_b_1_")'
  3 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo fo0-01 > dir_x/f2
  $ mkdir dir_z
  $ ls dir_z
  $ echo babar > dir_z/f1
  $ echo celeste > dir_z/f2
  $ echo foo > dir_z/f3
  $ hg add dir_z
  adding dir_z/f1
  adding dir_z/f2
  adding dir_z/f3
  $ hg ci -m 'rev_b_2_'

  $ hg update 'desc("rev_b_2_")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo f0o-01 > dir_x/f3
  $ echo zephir > dir_z/f1
  $ echo arthur > dir_z/f2
  $ hg ci -m 'rev_b_3_'

  $ hg update 'desc("rev_c_1_")'
  6 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo bar-02 > dir_y/f1
  $ echo ba9-01 > dir_y/f3
  $ echo bar > dir_z/f4
  $ hg add dir_z/
  adding dir_z/f4
  $ echo arthur > dir_z/f2
  $ hg ci -m 'rev_c_2_'

  $ hg update 'desc("rev_b_3_")'
  7 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg merge 'desc("rev_c_2_")'
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ echo flore > dir_z/f1
  $ echo foo-04 > dir_x/f1
  $ echo foo-01 > dir_z/f3
  $ hg ci -m 'rev_d_0_'
  $ echo alexandre > dir_z/f1
  $ echo bar-01 > dir_z/f4
  $ echo bar-04 > dir_y/f1
  $ hg ci -m 'rev_d_1_'
  $ hg status
  $ hg status -A
  C dir_x/f1
  C dir_x/f2
  C dir_x/f3
  C dir_y/f1
  C dir_y/f2
  C dir_y/f3
  C dir_z/f1
  C dir_z/f2
  C dir_z/f3
  C dir_z/f4
  C readme.txt
  $ hg up null
  0 files updated, 0 files merged, 11 files removed, 0 files unresolved

Resulting graph

  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  10:71e6a9c7a6a2: rev_d_1_
  |    dir_y/f1 dir_z/f1 dir_z/f4
  o    9:b0a0cbe5ce57: rev_d_0_
  |\     dir_x/f1 dir_z/f1 dir_z/f3
  | o  8:d04e01dcc82d: rev_c_2_
  | |    dir_y/f1 dir_y/f3 dir_z/f2 dir_z/f4
  o |  7:fc05b303b551: rev_b_3_
  | |    dir_x/f3 dir_z/f1 dir_z/f2
  o |  6:17fd34adb43b: rev_b_2_
  | |    dir_x/f2 dir_z/f1 dir_z/f2 dir_z/f3
  | o  5:fa05dbe8eed1: rev_c_1_
  | |    dir_z/f1 dir_z/f2
  | o  4:59b4258b00dc: rev_c_0_
  | |    dir_y/f1 dir_y/f2 dir_z/f1
  o |  3:328f8ced5276: rev_b_1_
  | |    dir_x/f1
  o |  2:0ccce83dd29b: rev_b_0_
  |/     dir_x/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

Useful save useful nodes :

  $ hg log -T '{node}' > ../rev_c_2_ --rev 'desc("rev_c_2_")'
  $ hg log -T '{node}' > ../rev_b_3_ --rev 'desc("rev_b_3_")'

Reference output

Since we have the same file conent on each side, we should get a limited number
of file revision (and the associated linkrev).

This these shared file-revision and the associated linkrev computation is
fueling the complexity test in this file.

  $ cat > ../linkrev-check.sh << EOF
  > echo '# expected linkrev for dir_z/f1'
  > hg log -T '0 {rev}\n' --rev 'min(desc(rev_b_2_) or desc(rev_c_0_))'
  > hg log -T '1 {rev}\n' --rev 'min(desc(rev_b_3_) or desc(rev_c_1_))'
  > hg log -T '2 {rev}\n' --rev 'min(desc(rev_d_0_))'
  > hg log -T '3 {rev}\n' --rev 'min(desc(rev_d_1_))'
  > hg debugindex dir_z/f1
  > #   rev linkrev       nodeid    p1-nodeid    p2-nodeid
  > #     0       4 360afd990eef 000000000000 000000000000
  > #     1       5 7054ee088631 360afd990eef 000000000000
  > #     2       9 6bb290463f21 7054ee088631 000000000000
  > #     3      10 91fec784ff86 6bb290463f21 000000000000
  > echo '# expected linkrev for dir_z/f2'
  > hg log -T '0 {rev}\n' --rev 'min(desc(rev_c_1_) or desc(rev_b_2_))'
  > hg log -T '1 {rev}\n' --rev 'min(desc(rev_c_2_) or desc(rev_b_3_))'
  > hg debugindex dir_z/f2
  > #    rev linkrev       nodeid    p1-nodeid    p2-nodeid
  > #      0       5 093bb0f8a0fb 000000000000 000000000000
  > #      1       7 0f47e254cb19 093bb0f8a0fb 000000000000
  > if hg files --rev tip | grep dir_z/f3 > /dev/null; then
  >     echo '# expected linkrev for dir_z/f3'
  >     hg log -T '0 {rev}\n' --rev 'desc(rev_b_2_)'
  >     hg log -T '1 {rev}\n' --rev 'desc(rev_d_0_)'
  >     hg debugindex dir_z/f3
  >     #    rev linkrev       nodeid    p1-nodeid    p2-nodeid
  >     #      0       6 2ed2a3912a0b 000000000000 000000000000
  >     #      1       9 7c6d649320ae 2ed2a3912a0b 000000000000
  > fi
  > if hg files --rev tip | grep dir_z/f4 > /dev/null; then
  >     echo '# expected linkrev for dir_z/f4'
  >     hg log -T '0 {rev}\n' --rev 'desc(rev_c_2_)'
  >     hg log -T '1 {rev}\n' --rev 'desc(rev_d_1_)'
  >     hg debugindex dir_z/f4
  >     #   rev linkrev       nodeid    p1-nodeid    p2-nodeid
  >     #     0       8 b004912a8510 000000000000 000000000000
  >     #     1      10 9f85b3b95e70 b004912a8510 000000000000
  > fi
  > echo '# verify the repository'
  > hg verify
  > EOF
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 4
  1 5
  2 9
  3 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 360afd990eef 000000000000 000000000000
       1       5 7054ee088631 360afd990eef 000000000000
       2       9 6bb290463f21 7054ee088631 000000000000
       3      10 91fec784ff86 6bb290463f21 000000000000
  # expected linkrev for dir_z/f2
  0 5
  1 7
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       5 093bb0f8a0fb 000000000000 000000000000
       1       7 0f47e254cb19 093bb0f8a0fb 000000000000
  # expected linkrev for dir_z/f3
  0 6
  1 9
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       6 2ed2a3912a0b 000000000000 000000000000
       1       9 7c6d649320ae 2ed2a3912a0b 000000000000
  # expected linkrev for dir_z/f4
  0 8
  1 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       8 b004912a8510 000000000000 000000000000
       1      10 9f85b3b95e70 b004912a8510 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 11 changesets with 27 changes to 11 files

  $ cd ..

Test linkrev computation for various widening scenario
======================================================

Having cloning all revisions initially
--------------------------------------

  $ hg clone --narrow ssh://user@dummy/server --include dir_x --include dir_y client_xy_rev_all  --noupdate
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 11 changesets with 16 changes to 6 files
  new changesets 4978c5c7386b:71e6a9c7a6a2
  $ cd client_xy_rev_all
  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  10:71e6a9c7a6a2: rev_d_1_
  |    dir_y/f1 dir_z/f1 dir_z/f4
  o    9:b0a0cbe5ce57: rev_d_0_
  |\     dir_x/f1 dir_z/f1 dir_z/f3
  | o  8:d04e01dcc82d: rev_c_2_
  | |    dir_y/f1 dir_y/f3 dir_z/f2 dir_z/f4
  o |  7:fc05b303b551: rev_b_3_
  | |    dir_x/f3 dir_z/f1 dir_z/f2
  o |  6:17fd34adb43b: rev_b_2_
  | |    dir_x/f2 dir_z/f1 dir_z/f2 dir_z/f3
  | o  5:fa05dbe8eed1: rev_c_1_
  | |    dir_z/f1 dir_z/f2
  | o  4:59b4258b00dc: rev_c_0_
  | |    dir_y/f1 dir_y/f2 dir_z/f1
  o |  3:328f8ced5276: rev_b_1_
  | |    dir_x/f1
  o |  2:0ccce83dd29b: rev_b_0_
  |/     dir_x/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

  $ hg tracked --addinclude dir_z
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 10 changes to 4 files
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 4
  1 5
  2 9
  3 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 360afd990eef 000000000000 000000000000
       1       5 7054ee088631 360afd990eef 000000000000
       2       9 6bb290463f21 7054ee088631 000000000000
       3      10 91fec784ff86 6bb290463f21 000000000000
  # expected linkrev for dir_z/f2
  0 5
  1 7
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       5 093bb0f8a0fb 000000000000 000000000000
       1       7 0f47e254cb19 093bb0f8a0fb 000000000000
  # expected linkrev for dir_z/f3
  0 6
  1 9
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       6 2ed2a3912a0b 000000000000 000000000000
       1       9 7c6d649320ae 2ed2a3912a0b 000000000000
  # expected linkrev for dir_z/f4
  0 8
  1 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       8 b004912a8510 000000000000 000000000000
       1      10 9f85b3b95e70 b004912a8510 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 11 changesets with 26 changes to 10 files
  $ cd ..


Having cloning all only branch b
--------------------------------

  $ hg clone --narrow ssh://user@dummy/server --rev `cat ./rev_b_3_` --include dir_x --include dir_y client_xy_rev_from_b_only  --noupdate
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 10 changes to 6 files
  new changesets 4978c5c7386b:fc05b303b551
  $ cd client_xy_rev_from_b_only
  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  5:fc05b303b551: rev_b_3_
  |    dir_x/f3 dir_z/f1 dir_z/f2
  o  4:17fd34adb43b: rev_b_2_
  |    dir_x/f2 dir_z/f1 dir_z/f2 dir_z/f3
  o  3:328f8ced5276: rev_b_1_
  |    dir_x/f1
  o  2:0ccce83dd29b: rev_b_0_
  |    dir_x/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

  $ hg tracked --addinclude dir_z
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 5 changes to 3 files
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 4
  1 5
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 360afd990eef 000000000000 000000000000
       1       5 7054ee088631 360afd990eef 000000000000
  # expected linkrev for dir_z/f2
  0 4
  1 5
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 093bb0f8a0fb 000000000000 000000000000
       1       5 0f47e254cb19 093bb0f8a0fb 000000000000
  # expected linkrev for dir_z/f3
  0 4
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 2ed2a3912a0b 000000000000 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 6 changesets with 15 changes to 9 files
  $ cd ..


Having cloning all only branch c
--------------------------------

  $ hg clone --narrow ssh://user@dummy/server --rev `cat ./rev_c_2_` --include dir_x --include dir_y client_xy_rev_from_c_only --noupdate
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 10 changes to 6 files
  new changesets 4978c5c7386b:d04e01dcc82d
  $ cd client_xy_rev_from_c_only
  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  4:d04e01dcc82d: rev_c_2_
  |    dir_y/f1 dir_y/f3 dir_z/f2 dir_z/f4
  o  3:fa05dbe8eed1: rev_c_1_
  |    dir_z/f1 dir_z/f2
  o  2:59b4258b00dc: rev_c_0_
  |    dir_y/f1 dir_y/f2 dir_z/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

  $ hg tracked --addinclude dir_z
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 5 changes to 3 files
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 2
  1 3
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       2 360afd990eef 000000000000 000000000000
       1       3 7054ee088631 360afd990eef 000000000000
  # expected linkrev for dir_z/f2
  0 3
  1 4
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       3 093bb0f8a0fb 000000000000 000000000000
       1       4 0f47e254cb19 093bb0f8a0fb 000000000000
  # expected linkrev for dir_z/f4
  0 4
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 b004912a8510 000000000000 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 5 changesets with 15 changes to 9 files
  $ cd ..

Having cloning all first branch b
---------------------------------

  $ hg clone --narrow ssh://user@dummy/server --rev `cat ./rev_b_3_` --include dir_x --include dir_y client_xy_rev_from_b_first  --noupdate
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 10 changes to 6 files
  new changesets 4978c5c7386b:fc05b303b551
  $ cd client_xy_rev_from_b_first
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 6 changes to 4 files
  new changesets 59b4258b00dc:71e6a9c7a6a2
  (run 'hg update' to get a working copy)
  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  10:71e6a9c7a6a2: rev_d_1_
  |    dir_y/f1 dir_z/f1 dir_z/f4
  o    9:b0a0cbe5ce57: rev_d_0_
  |\     dir_x/f1 dir_z/f1 dir_z/f3
  | o  8:d04e01dcc82d: rev_c_2_
  | |    dir_y/f1 dir_y/f3 dir_z/f2 dir_z/f4
  | o  7:fa05dbe8eed1: rev_c_1_
  | |    dir_z/f1 dir_z/f2
  | o  6:59b4258b00dc: rev_c_0_
  | |    dir_y/f1 dir_y/f2 dir_z/f1
  o |  5:fc05b303b551: rev_b_3_
  | |    dir_x/f3 dir_z/f1 dir_z/f2
  o |  4:17fd34adb43b: rev_b_2_
  | |    dir_x/f2 dir_z/f1 dir_z/f2 dir_z/f3
  o |  3:328f8ced5276: rev_b_1_
  | |    dir_x/f1
  o |  2:0ccce83dd29b: rev_b_0_
  |/     dir_x/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

  $ hg tracked --addinclude dir_z
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 10 changes to 4 files
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 4
  1 5
  2 9
  3 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       6 360afd990eef 000000000000 000000000000 (known-bad-output !)
       0       4 360afd990eef 000000000000 000000000000 (missing-correct-output !)
       1       7 7054ee088631 360afd990eef 000000000000 (known-bad-output !)
       1       5 7054ee088631 360afd990eef 000000000000 (missing-correct-output !)
       2       9 6bb290463f21 7054ee088631 000000000000
       3      10 91fec784ff86 6bb290463f21 000000000000
  # expected linkrev for dir_z/f2
  0 4
  1 5
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       7 093bb0f8a0fb 000000000000 000000000000 (known-bad-output !)
       0       4 093bb0f8a0fb 000000000000 000000000000 (missing-correct-output !)
       1       5 0f47e254cb19 093bb0f8a0fb 000000000000
  # expected linkrev for dir_z/f3
  0 4
  1 9
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 2ed2a3912a0b 000000000000 000000000000
       1       9 7c6d649320ae 2ed2a3912a0b 000000000000
  # expected linkrev for dir_z/f4
  0 8
  1 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       8 b004912a8510 000000000000 000000000000
       1      10 9f85b3b95e70 b004912a8510 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 11 changesets with 26 changes to 10 files
  $ cd ..


Having cloning all first branch c
---------------------------------

  $ hg clone --narrow ssh://user@dummy/server --rev `cat ./rev_c_2_` --include dir_x --include dir_y client_xy_rev_from_c_first --noupdate
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 10 changes to 6 files
  new changesets 4978c5c7386b:d04e01dcc82d
  $ cd client_xy_rev_from_c_first
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 6 changes to 4 files
  new changesets 0ccce83dd29b:71e6a9c7a6a2
  (run 'hg update' to get a working copy)
  $ hg log -GT "{rev}:{node|short}: {desc}\n  {files}\n"
  o  10:71e6a9c7a6a2: rev_d_1_
  |    dir_y/f1 dir_z/f1 dir_z/f4
  o    9:b0a0cbe5ce57: rev_d_0_
  |\     dir_x/f1 dir_z/f1 dir_z/f3
  | o  8:fc05b303b551: rev_b_3_
  | |    dir_x/f3 dir_z/f1 dir_z/f2
  | o  7:17fd34adb43b: rev_b_2_
  | |    dir_x/f2 dir_z/f1 dir_z/f2 dir_z/f3
  | o  6:328f8ced5276: rev_b_1_
  | |    dir_x/f1
  | o  5:0ccce83dd29b: rev_b_0_
  | |    dir_x/f1
  o |  4:d04e01dcc82d: rev_c_2_
  | |    dir_y/f1 dir_y/f3 dir_z/f2 dir_z/f4
  o |  3:fa05dbe8eed1: rev_c_1_
  | |    dir_z/f1 dir_z/f2
  o |  2:59b4258b00dc: rev_c_0_
  |/     dir_y/f1 dir_y/f2 dir_z/f1
  o  1:63f468a0fdac: rev_a_
  |    dir_x/f1 dir_x/f2 dir_x/f3 dir_y/f1 dir_y/f2 dir_y/f3
  o  0:4978c5c7386b: root
       readme.txt

  $ hg tracked --addinclude dir_z
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 10 changes to 4 files
  $ sh ../linkrev-check.sh
  # expected linkrev for dir_z/f1
  0 2
  1 3
  2 9
  3 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       2 360afd990eef 000000000000 000000000000
       1       3 7054ee088631 360afd990eef 000000000000
       2       9 6bb290463f21 7054ee088631 000000000000
       3      10 91fec784ff86 6bb290463f21 000000000000
  # expected linkrev for dir_z/f2
  0 3
  1 4
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       3 093bb0f8a0fb 000000000000 000000000000
       1       8 0f47e254cb19 093bb0f8a0fb 000000000000 (known-bad-output !)
       1       4 0f47e254cb19 093bb0f8a0fb 000000000000 (missing-correct-output !)
  # expected linkrev for dir_z/f3
  0 7
  1 9
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       7 2ed2a3912a0b 000000000000 000000000000
       1       9 7c6d649320ae 2ed2a3912a0b 000000000000
  # expected linkrev for dir_z/f4
  0 4
  1 10
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       4 b004912a8510 000000000000 000000000000
       1      10 9f85b3b95e70 b004912a8510 000000000000
  # verify the repository
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 11 changesets with 26 changes to 10 files
  $ cd ..
