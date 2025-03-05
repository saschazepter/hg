=============================================================
Testing comparing changeset regardless of change from parents
=============================================================

Setup
=====

Add a bunch of changes some related to each other some not.

  $ hg init test-repo
  $ cd test-repo
  $ cat << EOF > file-a.txt
  > one
  > two
  > three
  > four
  > five
  > six
  > seven
  > eight
  > nine
  > ten
  > EOF
  $ hg add file-a.txt
  $ hg commit -m 'commit_root'

  $ sed s/two/deux/ file-a.txt > a
  $ mv a file-a.txt
  $ hg commit -m 'commit_A1_change'

  $ sed s/five/cinq/ file-a.txt > a
  $ mv a file-a.txt
  $ hg commit -m 'commit_A2_change'

  $ cat << EOF > file-b.txt
  > egg
  > salade
  > orange
  > EOF
  $ hg add file-b.txt
  $ hg commit -m 'commit_A3_change'

  $ cat << EOF > file-b.txt
  > butter
  > egg
  > salade
  > orange
  > EOF
  $ hg commit -m 'commit_A4_change'

  $ hg up 'desc("commit_root")'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ sed s/two/deux/ file-a.txt > a
  $ mv a file-a.txt
  $ sed s/ten/dix/ file-a.txt > a
  $ mv a file-a.txt
  $ hg commit -m 'commit_B1_change'
  created new head

  $ sed s/five/funf/ file-a.txt > a
  $ mv a file-a.txt
  $ sed s/eight/acht/ file-a.txt > a
  $ mv a file-a.txt
  $ hg commit -m 'commit_B2_change'

  $ cat << EOF > file-b.txt
  > milk
  > egg
  > salade
  > apple
  > EOF
  $ hg add file-b.txt
  $ hg commit -m 'commit_B3_change'

  $ cat << EOF > file-b.txt
  > butter
  > milk
  > egg
  > salade
  > apple
  > EOF
  $ hg commit -m 'commit_B4_change'

  $ hg log -G --patch
  @  changeset:   8:0d6b02d59faf
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     commit_B4_change
  |
  |  diff -r 59c9679fd24c -r 0d6b02d59faf file-b.txt
  |  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -1,3 +1,4 @@
  |  +butter
  |   milk
  |   egg
  |   salade
  |
  o  changeset:   7:59c9679fd24c
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     commit_B3_change
  |
  |  diff -r 1e73118ddc3a -r 59c9679fd24c file-b.txt
  |  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -0,0 +1,4 @@
  |  +milk
  |  +egg
  |  +salade
  |  +apple
  |
  o  changeset:   6:1e73118ddc3a
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     commit_B2_change
  |
  |  diff -r 30a40f18d81e -r 1e73118ddc3a file-a.txt
  |  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -2,9 +2,9 @@
  |   deux
  |   three
  |   four
  |  -five
  |  +funf
  |   six
  |   seven
  |  -eight
  |  +acht
  |   nine
  |   dix
  |
  o  changeset:   5:30a40f18d81e
  |  parent:      0:9c17110ca844
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     commit_B1_change
  |
  |  diff -r 9c17110ca844 -r 30a40f18d81e file-a.txt
  |  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |  @@ -1,5 +1,5 @@
  |   one
  |  -two
  |  +deux
  |   three
  |   four
  |   five
  |  @@ -7,4 +7,4 @@
  |   seven
  |   eight
  |   nine
  |  -ten
  |  +dix
  |
  | o  changeset:   4:e6f5655bdf2e
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     commit_A4_change
  | |
  | |  diff -r 074ad64f5cd7 -r e6f5655bdf2e file-b.txt
  | |  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  | |  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  | |  @@ -1,3 +1,4 @@
  | |  +butter
  | |   egg
  | |   salade
  | |   orange
  | |
  | o  changeset:   3:074ad64f5cd7
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     commit_A3_change
  | |
  | |  diff -r 37c330f02452 -r 074ad64f5cd7 file-b.txt
  | |  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  | |  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  | |  @@ -0,0 +1,3 @@
  | |  +egg
  | |  +salade
  | |  +orange
  | |
  | o  changeset:   2:37c330f02452
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     commit_A2_change
  | |
  | |  diff -r 7bcbc987bcfe -r 37c330f02452 file-a.txt
  | |  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  | |  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  | |  @@ -2,7 +2,7 @@
  | |   deux
  | |   three
  | |   four
  | |  -five
  | |  +cinq
  | |   six
  | |   seven
  | |   eight
  | |
  | o  changeset:   1:7bcbc987bcfe
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     commit_A1_change
  |
  |    diff -r 9c17110ca844 -r 7bcbc987bcfe file-a.txt
  |    --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |    +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  |    @@ -1,5 +1,5 @@
  |     one
  |    -two
  |    +deux
  |     three
  |     four
  |     five
  |
  o  changeset:   0:9c17110ca844
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     commit_root
  
     diff -r 000000000000 -r 9c17110ca844 file-a.txt
     --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
     +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
     @@ -0,0 +1,10 @@
     +one
     +two
     +three
     +four
     +five
     +six
     +seven
     +eight
     +nine
     +ten
  

Then compare the resulting revisions:
====================================

A1 and B1 has the same parent, so the same output is expected.


  $ hg diff --from 'desc("commit_A1_change")' --to 'desc("commit_B1_change")'
  diff -r 7bcbc987bcfe -r 30a40f18d81e file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -7,4 +7,4 @@
   seven
   eight
   nine
  -ten
  +dix
  $ hg diff --from 'desc("commit_A1_change")' --to 'desc("commit_B1_change")' --ignore-changes-from-ancestors
  diff -r 7bcbc987bcfe -r 30a40f18d81e file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -7,4 +7,4 @@
   seven
   eight
   nine
  -ten
  +dix

Skipping B1 change mean the final "ten" change is no longer part of the diff

  $ hg diff --from 'desc("commit_A1_change")' --to 'desc("commit_B2_change")'
  diff -r 7bcbc987bcfe -r 1e73118ddc3a file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -five
  +funf
   six
   seven
  -eight
  +acht
   nine
  -ten
  +dix
  $ hg diff --from 'desc("commit_A1_change")' --to 'desc("commit_B2_change")' --ignore-changes-from-ancestors
  diff -r 1e73118ddc3a file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -five
  +funf
   six
   seven
  -eight
  +acht
   nine
   dix

Skipping A1 changes means the "two" changes introduced by "B1" (but also
present in A2 parent, A1) is back on the table.

  $ hg diff --from 'desc("commit_A2_change")' --to 'desc("commit_B1_change")'
  diff -r 37c330f02452 -r 30a40f18d81e file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -cinq
  +five
   six
   seven
   eight
   nine
  -ten
  +dix
  $ hg diff --from 'desc("commit_A2_change")' --to 'desc("commit_B1_change")' --ignore-changes-from-ancestors
  diff -r 30a40f18d81e file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,10 +1,10 @@
   one
  -two
  +deux
   three
   four
  -cinq
  +five
   six
   seven
   eight
   nine
  -ten
  +dix

All changes from A1 and B1 are no longer in the picture as we compare A2 and B2

  $ hg diff --from 'desc("commit_A2_change")' --to 'desc("commit_B2_change")'
  diff -r 37c330f02452 -r 1e73118ddc3a file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -cinq
  +funf
   six
   seven
  -eight
  +acht
   nine
  -ten
  +dix
  $ hg diff --from 'desc("commit_A2_change")' --to 'desc("commit_B2_change")' --ignore-changes-from-ancestors
  diff -r 1e73118ddc3a file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -cinq
  +funf
   six
   seven
  -eight
  +acht
   nine
   dix

Similar patches
---------------

comparing A3 and B3 patches is much more terse. focusing on the change to the
two similar patches, ignoring the rests of the changes (like comparing apples
and oranges)

  $ hg diff --from 'desc("commit_A3_change")' --to 'desc("commit_B3_change")'
  diff -r 074ad64f5cd7 -r 59c9679fd24c file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -cinq
  +funf
   six
   seven
  -eight
  +acht
   nine
  -ten
  +dix
  diff -r 074ad64f5cd7 -r 59c9679fd24c file-b.txt
  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,3 +1,4 @@
  +milk
   egg
   salade
  -orange
  +apple
  $ hg diff --from 'desc("commit_A3_change")' --to 'desc("commit_B3_change")' --ignore-changes-from-ancestors
  diff -r 59c9679fd24c file-b.txt
  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,3 +1,4 @@
  +milk
   egg
   salade
  -orange
  +apple


Conflict handling
-----------------

Conflict should not be a big deal and its resolution should be presented to the user.

  $ hg diff --from 'desc("commit_A4_change")' --to 'desc("commit_B4_change")'
  diff -r e6f5655bdf2e -r 0d6b02d59faf file-a.txt
  --- a/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-a.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -2,9 +2,9 @@
   deux
   three
   four
  -cinq
  +funf
   six
   seven
  -eight
  +acht
   nine
  -ten
  +dix
  diff -r e6f5655bdf2e -r 0d6b02d59faf file-b.txt
  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,4 +1,5 @@
   butter
  +milk
   egg
   salade
  -orange
  +apple
  $ hg diff --from 'desc("commit_A4_change")' --to 'desc("commit_B4_change")' --ignore-changes-from-ancestors
  diff -r 0d6b02d59faf file-b.txt
  --- a/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/file-b.txt	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,9 +1,5 @@
  -<<<<<<< from:           e6f5655bdf2e - test: commit_A4_change
   butter
  -||||||| parent-of-from: 074ad64f5cd7 - test: commit_A3_change
  -=======
   milk
  ->>>>>>> parent-of-to:   59c9679fd24c - test: commit_B3_change
   egg
   salade
   apple
