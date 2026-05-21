Test for stable ordering capabilities
=====================================

#testcases real naive

#if naive
  $ cat << EOF >> $HGRCPATH
  > [defaults]
  > debug::stable-tail-sort=--naive
  > EOF
#endif

(This test was imported from evolve's db172e4df9dc and adapted for core)

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=enable-unstable-format-and-corrupt-my-data
  > [ui]
  > logtemplate = "{rev} {node|short} {desc} {tags}\n"
  > [alias]
  > showsort = debug::stable-tail-sort --template="{node|short}\n"
  > debugrank = log --template="{node|short} {_fast_rank}\n"
  > EOF

XXX we currently process each head independantly. It might make sense to
re-introduce a sort for a multi-headed set at some point.

  $ checktopo () {
  >     for rev in `hg script::revs "heads($1)"`; do
  >         echo "### FROM $rev ###"
  >         seen="wdir()"
  >         for node in `hg showsort "$rev"`; do
  >             echo "=== checking $node ===";
  >             hg log --rev "($seen) and ::$node";
  >             seen="${seen}+${node}";
  >         done;
  >     done;
  > }

  $ show_sort_all() {
  >     for rev in `hg script::revs 'heads(all())'`; do
  >         echo "# head $rev"
  >         hg showsort $rev "$@"
  >     done
  > }

Basic tests
===========
(no criss cross merge)

Smoke tests
-----------

Starts with a "simple case"

  $ hg init repo_A
  $ cd repo_A
  $ hg debugbuilddag '
  > ..:g   # 2 nodes, tagged "g"
  > <2.:h   # another node base one -2 -> 0, tagged "h"
  > *1/2:m # merge -1 and -2 (1, 2), tagged "m"
  > <2+2:i # 2 nodes based on -2, tag head as "i"
  > .:c    # 1 node tagged "c"
  > <m+3:a # 3 nodes base on the "m" tag
  > <2.:b  # 1 node based on -2; tagged "b"
  > <m+2:d # 2 nodes from "m" tagged "d"
  > <2.:e  # 1 node based on -2, tagged "e"
  > <m+1:f # 1 node based on "m" tagged "f"
  > <i/f   # merge "i" and "f"
  > '
  $ hg log -G
  o    15 1d8d22637c2d r15 tip
  |\
  | o  14 43227190fef8 r14 f
  | |
  | | o  13 b4594d867745 r13 e
  | | |
  | | | o  12 e46a4836065c r12 d
  | | |/
  | | o  11 bab5d5bf48bd r11
  | |/
  | | o  10 ff43616e5d0f r10 b
  | | |
  | | | o  9 dcbb326fdec2 r9 a
  | | |/
  | | o  8 d62d843c9a01 r8
  | | |
  | | o  7 e7d9710d9fc6 r7
  | |/
  +---o  6 2702dd0c91e7 r6 c
  | |
  o |  5 f0f3ef9a6cd5 r5 i
  | |
  o |  4 4c748ffd1a46 r4
  | |
  | o  3 2b6d669947cd r3 m
  |/|
  o |  2 fa942426a6fd r2 h
  | |
  | o  1 66f7d451a68b r1 g
  |/
  o  0 1ea73414a91b r0
  
  $ hg debugrank -r 'all()'
  1ea73414a91b 1
  66f7d451a68b 2
  fa942426a6fd 2
  2b6d669947cd 4
  4c748ffd1a46 3
  f0f3ef9a6cd5 4
  2702dd0c91e7 5
  e7d9710d9fc6 5
  d62d843c9a01 6
  dcbb326fdec2 7
  ff43616e5d0f 7
  bab5d5bf48bd 5
  e46a4836065c 6
  b4594d867745 6
  43227190fef8 5
  1d8d22637c2d 8
  $ show_sort_all
  # head 2702dd0c91e7504b07a0c06158e8e0446d80d217
  2702dd0c91e7
  f0f3ef9a6cd5
  4c748ffd1a46
  fa942426a6fd
  1ea73414a91b
  # head dcbb326fdec291e210021ba6a32c67ac6648b900
  dcbb326fdec2
  d62d843c9a01
  e7d9710d9fc6
  2b6d669947cd
  66f7d451a68b
  fa942426a6fd
  1ea73414a91b
  # head ff43616e5d0f1647b280ff367741e6703d5a5d0b
  ff43616e5d0f
  d62d843c9a01
  e7d9710d9fc6
  2b6d669947cd
  66f7d451a68b
  fa942426a6fd
  1ea73414a91b
  # head e46a4836065c21e77548ae8bbab2bf7f9976fe03
  e46a4836065c
  bab5d5bf48bd
  2b6d669947cd
  66f7d451a68b
  fa942426a6fd
  1ea73414a91b
  # head b4594d867745e8ac7cf2ddfacfabbebc1094120d
  b4594d867745
  bab5d5bf48bd
  2b6d669947cd
  66f7d451a68b
  fa942426a6fd
  1ea73414a91b
  # head 1d8d22637c2d2d7c118358e3b191256d566819d9
  1d8d22637c2d
  f0f3ef9a6cd5
  4c748ffd1a46
  43227190fef8
  2b6d669947cd
  66f7d451a68b
  fa942426a6fd
  1ea73414a91b

Verify the topological order
----------------------------

Check we we did not issued a node before on ancestor

output of log should be empty

  $ checktopo 'all()'
  ### FROM 2702dd0c91e7504b07a0c06158e8e0446d80d217 ###
  === checking 2702dd0c91e7 ===
  === checking f0f3ef9a6cd5 ===
  === checking 4c748ffd1a46 ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===
  ### FROM dcbb326fdec291e210021ba6a32c67ac6648b900 ###
  === checking dcbb326fdec2 ===
  === checking d62d843c9a01 ===
  === checking e7d9710d9fc6 ===
  === checking 2b6d669947cd ===
  === checking 66f7d451a68b ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===
  ### FROM ff43616e5d0f1647b280ff367741e6703d5a5d0b ###
  === checking ff43616e5d0f ===
  === checking d62d843c9a01 ===
  === checking e7d9710d9fc6 ===
  === checking 2b6d669947cd ===
  === checking 66f7d451a68b ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===
  ### FROM e46a4836065c21e77548ae8bbab2bf7f9976fe03 ###
  === checking e46a4836065c ===
  === checking bab5d5bf48bd ===
  === checking 2b6d669947cd ===
  === checking 66f7d451a68b ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===
  ### FROM b4594d867745e8ac7cf2ddfacfabbebc1094120d ###
  === checking b4594d867745 ===
  === checking bab5d5bf48bd ===
  === checking 2b6d669947cd ===
  === checking 66f7d451a68b ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===
  ### FROM 1d8d22637c2d2d7c118358e3b191256d566819d9 ###
  === checking 1d8d22637c2d ===
  === checking f0f3ef9a6cd5 ===
  === checking 4c748ffd1a46 ===
  === checking 43227190fef8 ===
  === checking 2b6d669947cd ===
  === checking 66f7d451a68b ===
  === checking fa942426a6fd ===
  === checking 1ea73414a91b ===

Check stability
===============

have repo with changesets in orders

  $ cd ..
  $ hg -R repo_A log -G > A.log
  $ hg clone repo_A repo_B --rev 5
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:f0f3ef9a6cd5
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_B pull --rev 13
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files (+1 heads)
  new changesets 66f7d451a68b:b4594d867745
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R repo_B pull --rev 14
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (+1 heads)
  new changesets 43227190fef8
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg -R repo_B pull
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 0 changes to 0 files (+3 heads)
  new changesets 2702dd0c91e7:1d8d22637c2d
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg -R repo_B log -G
  o    15 1d8d22637c2d r15 tip
  |\
  | | o  14 e46a4836065c r12
  | | |
  | | | o  13 ff43616e5d0f r10
  | | | |
  | | | | o  12 dcbb326fdec2 r9
  | | | |/
  | | | o  11 d62d843c9a01 r8
  | | | |
  | | | o  10 e7d9710d9fc6 r7
  | | | |
  +-------o  9 2702dd0c91e7 r6
  | | | |
  | o---+  8 43227190fef8 r14
  |  / /
  | +---o  7 b4594d867745 r13
  | | |
  | o |  6 bab5d5bf48bd r11
  | |/
  | o    5 2b6d669947cd r3
  | |\
  | | o  4 66f7d451a68b r1
  | | |
  @ | |  3 f0f3ef9a6cd5 r5
  | | |
  o | |  2 4c748ffd1a46 r4
  |/ /
  o /  1 fa942426a6fd r2
  |/
  o  0 1ea73414a91b r0
  
  $ hg -R repo_B debugrank -r 'all()'
  1ea73414a91b 1
  fa942426a6fd 2
  4c748ffd1a46 3
  f0f3ef9a6cd5 4
  66f7d451a68b 2
  2b6d669947cd 4
  bab5d5bf48bd 5
  b4594d867745 6
  43227190fef8 5
  2702dd0c91e7 5
  e7d9710d9fc6 5
  d62d843c9a01 6
  dcbb326fdec2 7
  ff43616e5d0f 7
  e46a4836065c 6
  1d8d22637c2d 8
  $ hg -R repo_B log -G > B.log

  $ hg clone repo_A repo_C --rev 10
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:ff43616e5d0f
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_C pull --rev 12
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files (+1 heads)
  new changesets bab5d5bf48bd:e46a4836065c
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R repo_C pull --rev 15
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files (+1 heads)
  new changesets 4c748ffd1a46:1d8d22637c2d
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg -R repo_C pull
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 0 changes to 0 files (+3 heads)
  new changesets 2702dd0c91e7:b4594d867745
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg -R repo_C log -G
  o  15 b4594d867745 r13 tip
  |
  | o  14 dcbb326fdec2 r9
  | |
  | | o  13 2702dd0c91e7 r6
  | | |
  | | | o  12 1d8d22637c2d r15
  | | |/|
  | | | o  11 43227190fef8 r14
  | | | |
  | | o |  10 f0f3ef9a6cd5 r5
  | | | |
  | | o |  9 4c748ffd1a46 r4
  | | | |
  +-------o  8 e46a4836065c r12
  | | | |
  o-----+  7 bab5d5bf48bd r11
   / / /
  +-----@  6 ff43616e5d0f r10
  | | |
  o | |  5 d62d843c9a01 r8
  | | |
  o---+  4 e7d9710d9fc6 r7
   / /
  | o  3 2b6d669947cd r3
  |/|
  o |  2 fa942426a6fd r2
  | |
  | o  1 66f7d451a68b r1
  |/
  o  0 1ea73414a91b r0
  
  $ hg -R repo_C log -G > C.log

  $ hg clone repo_A repo_D --rev 2
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:fa942426a6fd
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_D pull --rev 10
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 0 changes to 0 files
  new changesets 66f7d451a68b:ff43616e5d0f
  (run 'hg update' to get a working copy)
  $ hg -R repo_D pull --rev 15
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 0 changes to 0 files (+1 heads)
  new changesets 4c748ffd1a46:1d8d22637c2d
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R repo_D pull
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 0 changes to 0 files (+4 heads)
  new changesets 2702dd0c91e7:b4594d867745
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg -R repo_D log -G
  o  15 b4594d867745 r13 tip
  |
  | o  14 e46a4836065c r12
  |/
  o  13 bab5d5bf48bd r11
  |
  | o  12 dcbb326fdec2 r9
  | |
  | | o  11 2702dd0c91e7 r6
  | | |
  | | | o  10 1d8d22637c2d r15
  | | |/|
  +-----o  9 43227190fef8 r14
  | | |
  | | o  8 f0f3ef9a6cd5 r5
  | | |
  | | o  7 4c748ffd1a46 r4
  | | |
  | +---o  6 ff43616e5d0f r10
  | | |
  | o |  5 d62d843c9a01 r8
  | | |
  | o |  4 e7d9710d9fc6 r7
  |/ /
  o |  3 2b6d669947cd r3
  |\|
  o |  2 66f7d451a68b r1
  | |
  | @  1 fa942426a6fd r2
  |/
  o  0 1ea73414a91b r0
  
  $ hg -R repo_D log -G > D.log

check the log output are different

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.log
  55919ebc9c02f28070cf3255b1690f8c  A.log
  c6244b76a60d0707767dc71780e544f3  B.log
  4d8b08b8c50ecbdd2460a62e5852d84d  C.log
  0f327003593b50b9591bea8ee28acb81  D.log

bug stable ordering should be identical
---------------------------------------

  $ repos="A B C D "

for 'all()'

  $ for x in $repos; do
  >     echo $x
  >     show_sort_all -R repo_$x > ${x}.all.order;
  > done
  A
  abort: no repository found in '$TESTTMP' (.hg not found)
  B
  abort: no repository found in '$TESTTMP' (.hg not found)
  C
  abort: no repository found in '$TESTTMP' (.hg not found)
  D
  abort: no repository found in '$TESTTMP' (.hg not found)

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.all.order
  d41d8cd98f00b204e9800998ecf8427e  A.all.order
  d41d8cd98f00b204e9800998ecf8427e  B.all.order
  d41d8cd98f00b204e9800998ecf8427e  C.all.order
  d41d8cd98f00b204e9800998ecf8427e  D.all.order

one specific head

  $ for x in $repos; do
  >     hg -R repo_$x showsort 'b4594d867745' > ${x}.b4594d867745.order;
  > done

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.b4594d867745.order
  960a5a172e7ed58c1a14e16eba5968da  A.b4594d867745.order
  960a5a172e7ed58c1a14e16eba5968da  B.b4594d867745.order
  960a5a172e7ed58c1a14e16eba5968da  C.b4594d867745.order
  960a5a172e7ed58c1a14e16eba5968da  D.b4594d867745.order

one secific heads, that is a merge

  $ for x in $repos; do
  >     hg -R repo_$x showsort '1d8d22637c2d' > ${x}.1d8d22637c2d.order;
  > done

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.1d8d22637c2d.order
  42e400a408361036a0e3dd7d1e37bce2  A.1d8d22637c2d.order
  42e400a408361036a0e3dd7d1e37bce2  B.1d8d22637c2d.order
  42e400a408361036a0e3dd7d1e37bce2  C.1d8d22637c2d.order
  42e400a408361036a0e3dd7d1e37bce2  D.1d8d22637c2d.order

changeset that are not heads

  $ for x in $repos; do
  >     hg -R repo_$x showsort 'e7d9710d9fc6+43227190fef8' > ${x}.non-heads.order;
  > done

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  A.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  B.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  C.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  D.non-heads.order
  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.non-heads.orderhead
  *.non-heads.orderhead: Can't open: [Errno 2] $ENOENT$: '*.non-heads.orderhead'
  [1]

Check with different subset

  $ hg clone repo_A repo_E --rev "43227190fef8"
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:43227190fef8
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_E pull --rev e7d9710d9fc6
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (+1 heads)
  new changesets e7d9710d9fc6
  (run 'hg heads' to see heads, 'hg merge' to merge)

  $ hg clone repo_A repo_F --rev "1d8d22637c2d"
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:1d8d22637c2d
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_F pull --rev d62d843c9a01
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files (+1 heads)
  new changesets e7d9710d9fc6:d62d843c9a01
  (run 'hg heads' to see heads, 'hg merge' to merge)

  $ hg clone repo_A repo_G --rev "e7d9710d9fc6"
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b:e7d9710d9fc6
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo_G pull --rev 43227190fef8
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (+1 heads)
  new changesets 43227190fef8
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R repo_G pull --rev 2702dd0c91e7
  pulling from $TESTTMP/repo_A (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 0 changes to 0 files (+1 heads)
  new changesets 4c748ffd1a46:2702dd0c91e7
  (run 'hg heads .' to see heads, 'hg merge' to merge)

  $ for x in E F G; do
  >     hg -R repo_$x showsort 'e7d9710d9fc6+43227190fef8' > ${x}.non-heads.order;
  >     hg -R repo_$x showsort 'e7d9710d9fc6' > ${x}.non-head-A.orderhead;
  >     hg -R repo_$x showsort '43227190fef8' > ${x}.non-head-B.orderhead;
  > done

  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  A.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  B.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  C.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  D.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  E.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  F.non-heads.order
  fdb60cb32f2b13554087dfb9c882502f  G.non-heads.order
  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.non-head-A.orderhead
  7b9c6e2e04f76ab3be319d279639a5b9  E.non-head-A.orderhead
  7b9c6e2e04f76ab3be319d279639a5b9  F.non-head-A.orderhead
  7b9c6e2e04f76ab3be319d279639a5b9  G.non-head-A.orderhead
  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" *.non-head-B.orderhead
  fdb60cb32f2b13554087dfb9c882502f  E.non-head-B.orderhead
  fdb60cb32f2b13554087dfb9c882502f  F.non-head-B.orderhead
  fdb60cb32f2b13554087dfb9c882502f  G.non-head-B.orderhead

Multiple recursions
===================

  $ hg init recursion_A
  $ cd recursion_A
  $ hg debugbuilddag '
  > .:base
  > +3:A
  > <base.:B
  > +2/A:C
  > <A+2:D
  > <B./D:E
  > +3:F
  > <C+3/E
  > +2
  > '
  $ hg log -G
  o  20 160a7a0adbf4 r20 tip
  |
  o  19 1c645e73dbc6 r19
  |
  o    18 0496f0a6a143 r18
  |\
  | o  17 d64d500024d1 r17
  | |
  | o  16 4dbf739dd63f r16
  | |
  | o  15 9fff0871d230 r15
  | |
  | | o  14 4bbfc6078919 r14 F
  | | |
  | | o  13 013b27f11536 r13
  | | |
  +---o  12 a66b68853635 r12
  | |
  o |    11 001194dd78d5 r11 E
  |\ \
  | o |  10 6ee532b68cfa r10
  | | |
  o | |  9 529dfc5bb875 r9 D
  | | |
  o | |  8 abf57d94268b r8
  | | |
  +---o  7 5f18015f9110 r7 C
  | | |
  | | o  6 a2f58e9c1e56 r6
  | | |
  | | o  5 3a367db1fabc r5
  | |/
  | o  4 e7bd5218ca15 r4 B
  | |
  o |  3 2dc09a01254d r3 A
  | |
  o |  2 01241442b3c2 r2
  | |
  o |  1 66f7d451a68b r1
  |/
  o  0 1ea73414a91b r0 base
  
  $ hg debugrank -r 'all()'
  1ea73414a91b 1
  66f7d451a68b 2
  01241442b3c2 3
  2dc09a01254d 4
  e7bd5218ca15 2
  3a367db1fabc 3
  a2f58e9c1e56 4
  5f18015f9110 8
  abf57d94268b 5
  529dfc5bb875 6
  6ee532b68cfa 3
  001194dd78d5 9
  a66b68853635 10
  013b27f11536 11
  4bbfc6078919 12
  9fff0871d230 9
  4dbf739dd63f 10
  d64d500024d1 11
  0496f0a6a143 16
  1c645e73dbc6 17
  160a7a0adbf4 18
  $ show_sort_all
  # head 4bbfc60789192d65baf0d3008a2aa2531835f400
  4bbfc6078919
  013b27f11536
  a66b68853635
  001194dd78d5
  6ee532b68cfa
  e7bd5218ca15
  529dfc5bb875
  abf57d94268b
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  # head 160a7a0adbf41faed91eab6f8f37ae7273b0ce97
  160a7a0adbf4
  1c645e73dbc6
  0496f0a6a143
  001194dd78d5
  6ee532b68cfa
  529dfc5bb875
  abf57d94268b
  d64d500024d1
  4dbf739dd63f
  9fff0871d230
  5f18015f9110
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  a2f58e9c1e56
  3a367db1fabc
  e7bd5218ca15
  1ea73414a91b
  $ checktopo 'all()'
  ### FROM 4bbfc60789192d65baf0d3008a2aa2531835f400 ###
  === checking 4bbfc6078919 ===
  === checking 013b27f11536 ===
  === checking a66b68853635 ===
  === checking 001194dd78d5 ===
  === checking 6ee532b68cfa ===
  === checking e7bd5218ca15 ===
  === checking 529dfc5bb875 ===
  === checking abf57d94268b ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  ### FROM 160a7a0adbf41faed91eab6f8f37ae7273b0ce97 ###
  === checking 160a7a0adbf4 ===
  === checking 1c645e73dbc6 ===
  === checking 0496f0a6a143 ===
  === checking 001194dd78d5 ===
  === checking 6ee532b68cfa ===
  === checking 529dfc5bb875 ===
  === checking abf57d94268b ===
  === checking d64d500024d1 ===
  === checking 4dbf739dd63f ===
  === checking 9fff0871d230 ===
  === checking 5f18015f9110 ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking a2f58e9c1e56 ===
  === checking 3a367db1fabc ===
  === checking e7bd5218ca15 ===
  === checking 1ea73414a91b ===
  $ show_sort_all > ../multiple.source.order
  $ hg log -r tip
  20 160a7a0adbf4 r20 tip
  $ cd ..

  $ hg clone recursion_A recursion_random --rev 0
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd recursion_random
  $ for x in `"$PYTHON" "$TESTDIR/testlib/random-revs.py" 15 5`; do
  >   # using python to benefit from the random seed
  >   hg pull -r $x --quiet
  > done;
  $ hg pull --quiet
  $ show_sort_all > ../multiple.random.order
  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" ../multiple.*.order
  5a5f0c7cee5df45b75773e016c1cd7b6  ../multiple.random.order
  5a5f0c7cee5df45b75773e016c1cd7b6  ../multiple.source.order
  $ show_sort_all
  # head 4bbfc60789192d65baf0d3008a2aa2531835f400
  4bbfc6078919
  013b27f11536
  a66b68853635
  001194dd78d5
  6ee532b68cfa
  e7bd5218ca15
  529dfc5bb875
  abf57d94268b
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  # head 160a7a0adbf41faed91eab6f8f37ae7273b0ce97
  160a7a0adbf4
  1c645e73dbc6
  0496f0a6a143
  001194dd78d5
  6ee532b68cfa
  529dfc5bb875
  abf57d94268b
  d64d500024d1
  4dbf739dd63f
  9fff0871d230
  5f18015f9110
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  a2f58e9c1e56
  3a367db1fabc
  e7bd5218ca15
  1ea73414a91b
  $ cd ..


Test behavior with oedipus merges
=================================

  $ hg init recursion_oedipus
  $ cd recursion_oedipus
  $ echo base > base
  $ hg add base
  $ hg ci -m base
  $ hg branch foo
  marked working directory as branch foo
  (branches are permanent and global, did you want a bookmark?)
  $ echo foo1 > foo1
  $ hg add foo1
  $ hg ci -m foo1
  $ echo foo2 > foo2
  $ hg add foo2
  $ hg ci -m foo2
  $ hg up default
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg merge foo
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m oedipus_merge
  $ echo default1 > default1
  $ hg add default1
  $ hg ci -m default1
  $ hg log -G
  @  4 7f2454f6b04f default1 tip
  |
  o    3 ed776db7ed63 oedipus_merge
  |\
  | o  2 0dedbcd995b6 foo2
  | |
  | o  1 47da0f2c25e2 foo1
  |/
  o  0 d20a80d4def3 base
  
  $ hg debugrank -r 'all()'
  d20a80d4def3 1
  47da0f2c25e2 2
  0dedbcd995b6 3
  ed776db7ed63 4
  7f2454f6b04f 5
  $ hg showsort '.'
  7f2454f6b04f
  ed776db7ed63
  0dedbcd995b6
  47da0f2c25e2
  d20a80d4def3

  $ cd ..

Merge two branches with their own independant internal merge.
-------------------------------------------------------------

  $ hg init subbranch
  $ cd subbranch
  $ hg debugbuilddag '
  > .:base
  > +3:leftBranch
  > +2:leftA
  > <leftBranch.+2:leftB
  > /leftA:leftMerge
  > <base+2:rightBranch
  > +4:rightA
  > <rightBranch.+1:rightB
  > /rightA:rightMerge
  > +3/leftMerge
  > '
  $ hg log -G
  o    22 56526aefbff4 r22 tip
  |\
  | o  21 d4422659bc40 r21
  | |
  | o  20 6a97ef856f90 r20
  | |
  | o  19 5648bbf0e38b r19
  | |
  | o    18 4442c125b80d r18 rightMerge
  | |\
  | | o  17 65e683dd6db4 r17 rightB
  | | |
  | | o  16 5188cf52b7b7 r16
  | | |
  | o |  15 191bac7bf37c r15 rightA
  | | |
  | o |  14 5cb8e6902ff3 r14
  | | |
  | o |  13 448a7ac3ab1f r13
  | | |
  | o |  12 ee222cc71ce6 r12
  | |/
  | o  11 e5c0d969abc4 r11 rightBranch
  | |
  | o  10 7cc044fdf4a7 r10
  | |
  o |    9 9f6c364a3574 r9 leftMerge
  |\ \
  | o |  8 588f0bc87ecd r8 leftB
  | | |
  | o |  7 e2317cea05f7 r7
  | | |
  | o |  6 c2c595bcd4c6 r6
  | | |
  o | |  5 c8d03c1b5e94 r5 leftA
  | | |
  o | |  4 bebd167eb94d r4
  |/ /
  o |  3 2dc09a01254d r3 leftBranch
  | |
  o |  2 01241442b3c2 r2
  | |
  o |  1 66f7d451a68b r1
  |/
  o  0 1ea73414a91b r0 base
  
  $ hg debugrank -r 'all()'
  1ea73414a91b 1
  66f7d451a68b 2
  01241442b3c2 3
  2dc09a01254d 4
  bebd167eb94d 5
  c8d03c1b5e94 6
  c2c595bcd4c6 5
  e2317cea05f7 6
  588f0bc87ecd 7
  9f6c364a3574 10
  7cc044fdf4a7 2
  e5c0d969abc4 3
  ee222cc71ce6 4
  448a7ac3ab1f 5
  5cb8e6902ff3 6
  191bac7bf37c 7
  5188cf52b7b7 4
  65e683dd6db4 5
  4442c125b80d 10
  5648bbf0e38b 11
  6a97ef856f90 12
  d4422659bc40 13
  56526aefbff4 23
  $ hg showsort 'tip'
  56526aefbff4
  9f6c364a3574
  c8d03c1b5e94
  bebd167eb94d
  588f0bc87ecd
  e2317cea05f7
  c2c595bcd4c6
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  d4422659bc40
  6a97ef856f90
  5648bbf0e38b
  4442c125b80d
  65e683dd6db4
  5188cf52b7b7
  191bac7bf37c
  5cb8e6902ff3
  448a7ac3ab1f
  ee222cc71ce6
  e5c0d969abc4
  7cc044fdf4a7
  1ea73414a91b
  $ cd ..
