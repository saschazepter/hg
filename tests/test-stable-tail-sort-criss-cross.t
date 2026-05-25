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
  > showsort = debug::stable-tail-sort --template="{node|short}\n" $NAIVE
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

Check criss cross merge
=======================

  $ hg init crisscross_A
  $ cd crisscross_A
  $ hg debugbuilddag '
  > ...:base         # create some base
  > # criss cross #1: simple
  > +3:AbaseA      # "A" branch for CC "A"
  > <base+2:AbaseB # "B" branch for CC "B"
  > <AbaseA/AbaseB:AmergeA
  > <AbaseB/AbaseA:AmergeB
  > <AmergeA/AmergeB:Afinal
  > # criss cross #2:multiple closes ones
  > .:BbaseA
  > <AmergeB:BbaseB
  > <BbaseA/BbaseB:BmergeA
  > <BbaseB/BbaseA:BmergeB
  > <BmergeA/BmergeB:BmergeC
  > <BmergeB/BmergeA:BmergeD
  > <BmergeC/BmergeD:Bfinal
  > # criss cross #2:many branches
  > <Bfinal.:CbaseA
  > <Bfinal+2:CbaseB
  > <Bfinal.:CbaseC
  > <Bfinal+5:CbaseD
  > <Bfinal.:CbaseE
  > <CbaseA/CbaseB+7:CmergeA
  > <CbaseA/CbaseC:CmergeB
  > <CbaseA/CbaseD.:CmergeC
  > <CbaseA/CbaseE:CmergeD
  > <CbaseB/CbaseA+2:CmergeE
  > <CbaseB/CbaseC:CmergeF
  > <CbaseB/CbaseD.:CmergeG
  > <CbaseB/CbaseE:CmergeH
  > <CbaseC/CbaseA.:CmergeI
  > <CbaseC/CbaseB:CmergeJ
  > <CbaseC/CbaseD+5:CmergeK
  > <CbaseC/CbaseE+2:CmergeL
  > <CbaseD/CbaseA:CmergeM
  > <CbaseD/CbaseB...:CmergeN
  > <CbaseD/CbaseC:CmergeO
  > <CbaseD/CbaseE:CmergeP
  > <CbaseE/CbaseA:CmergeQ
  > <CbaseE/CbaseB..:CmergeR
  > <CbaseE/CbaseC.:CmergeS
  > <CbaseE/CbaseD:CmergeT
  > <CmergeA/CmergeG:CmergeWA
  > <CmergeB/CmergeF:CmergeWB
  > <CmergeC/CmergeE:CmergeWC
  > <CmergeD/CmergeH:CmergeWD
  > <CmergeT/CmergeI:CmergeWE
  > <CmergeS/CmergeJ:CmergeWF
  > <CmergeR/CmergeK:CmergeWG
  > <CmergeQ/CmergeL:CmergeWH
  > <CmergeP/CmergeM:CmergeWI
  > <CmergeO/CmergeN:CmergeWJ
  > <CmergeO/CmergeN:CmergeWK
  > <CmergeWA/CmergeWG:CmergeXA
  > <CmergeWB/CmergeWH:CmergeXB
  > <CmergeWC/CmergeWI:CmergeXC
  > <CmergeWD/CmergeWJ:CmergeXD
  > <CmergeWE/CmergeWK:CmergeXE
  > <CmergeWF/CmergeWA:CmergeXF
  > <CmergeXA/CmergeXF:CmergeYA
  > <CmergeXB/CmergeXE:CmergeYB
  > <CmergeXC/CmergeXD:CmergeYC
  > <CmergeYA/CmergeYB:CmergeZA
  > <CmergeYC/CmergeYB:CmergeZB
  > <CmergeZA/CmergeZB:Cfinal
  > '
  $ hg log -G
  o    94 01f771406cab r94 Cfinal tip
  |\
  | o    93 84d6ec6a8e21 r93 CmergeZB
  | |\
  o | |  92 721ba7c5f4ff r92 CmergeZA
  |\| |
  | | o    91 8ae32c3ed670 r91 CmergeYC
  | | |\
  | o \ \    90 8b79544bb56d r90 CmergeYB
  | |\ \ \
  o \ \ \ \    89 041e1188f5f1 r89 CmergeYA
  |\ \ \ \ \
  | o \ \ \ \    88 2472d042ec95 r88 CmergeXF
  | |\ \ \ \ \
  | | | | o \ \    87 c7d3029bf731 r87 CmergeXE
  | | | | |\ \ \
  | | | | | | | o    86 469c700e9ed8 r86 CmergeXD
  | | | | | | | |\
  | | | | | | o \ \    85 28be96b80dc1 r85 CmergeXC
  | | | | | | |\ \ \
  | | | o \ \ \ \ \ \    84 dbde319d43a3 r84 CmergeXB
  | | | |\ \ \ \ \ \ \
  o | | | | | | | | | |  83 b3cf98c3d587 r83 CmergeXA
  |\| | | | | | | | | |
  | | | | | | o | | | |    82 1da228afcf06 r82 CmergeWK
  | | | | | | |\ \ \ \ \
  | | | | | | +-+-------o  81 0bab31f71a21 r81 CmergeWJ
  | | | | | | | | | | |
  | | | | | | | | | o |    80 cd345198cf12 r80 CmergeWI
  | | | | | | | | | |\ \
  | | | | o \ \ \ \ \ \ \    79 82238c0bc950 r79 CmergeWH
  | | | | |\ \ \ \ \ \ \ \
  o \ \ \ \ \ \ \ \ \ \ \ \    78 89a0fe204177 r78 CmergeWG
  |\ \ \ \ \ \ \ \ \ \ \ \ \
  | | | o \ \ \ \ \ \ \ \ \ \    77 97d19fc5236f r77 CmergeWF
  | | | |\ \ \ \ \ \ \ \ \ \ \
  | | | | | | | | o \ \ \ \ \ \    76 37ad3ab0cddf r76 CmergeWE
  | | | | | | | | |\ \ \ \ \ \ \
  | | | | | | | | | | | | | | | o    75 790cdfecd168 r75 CmergeWD
  | | | | | | | | | | | | | | | |\
  | | | | | | | | | | | | o \ \ \ \    74 698970a2480b r74 CmergeWC
  | | | | | | | | | | | | |\ \ \ \ \
  | | | | | o \ \ \ \ \ \ \ \ \ \ \ \    73 31d7b43cc321 r73 CmergeWB
  | | | | | |\ \ \ \ \ \ \ \ \ \ \ \ \
  | | o \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \    72 eed373b0090d r72 CmergeWA
  | | |\ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \
  | | | | | | | | | | | o \ \ \ \ \ \ \ \    71 4f3b41956174 r71 CmergeT
  | | | | | | | | | | | |\ \ \ \ \ \ \ \ \
  | | | | | o | | | | | | | | | | | | | | |  70 c3c7fa726f88 r70 CmergeS
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | o-------------+ | | | | | | | |  69 d917f77a6439 r69
  | | | | | | | | | | | | | | | | | | | | |
  | o | | | | | | | | | | | | | | | | | | |  68 fac9e582edd1 r68 CmergeR
  | | | | | | | | | | | | | | | | | | | | |
  | o | | | | | | | | | | | | | | | | | | |  67 e4cfd6264623 r67
  | | | | | | | | | | | | | | | | | | | | |
  | o---------------------+ | | | | | | | |  66 d99e0f7dad5b r66
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | o-----+ | | | | | | | |  65 c713eae2d31f r65 CmergeQ
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | +-+-----------o | |  64 b33fd5ad4c0c r64 CmergeP
  | | | | | | | | | | | | | | | | | |  / /
  | | | | | +-----------+-----o | | | / /  63 bf6593f7e073 r63 CmergeO
  | | | | | | | | | | | | | |  / / / / /
  | | | | | | | | | | | | | o | | | | |  62 3871506da61e r62 CmergeN
  | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | | | o | | | | |  61 c84da74cf586 r61
  | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | | | o | | | | |  60 5eec91b12a58 r60
  | | | | | | | | | | | | | | | | | | |
  | +-------------------+---o | | | | |  59 0484d39906c8 r59
  | | | | | | | | | | | | |  / / / / /
  | | | | | | | | | +---+-------o / /  58 29141354a762 r58 CmergeM
  | | | | | | | | | | | | | | |  / /
  | | | | | | | | o | | | | | | | |  57 e7135b665740 r57 CmergeL
  | | | | | | | | | | | | | | | | |
  | | | | | | | | o | | | | | | | |  56 c7c1497fc270 r56
  | | | | | | | | | | | | | | | | |
  | | | | | +-----o-------+ | | | |  55 76151e8066e1 r55
  | | | | | | | |  / / / / / / / /
  o | | | | | | | | | | | | | | |  54 9a67238ad1c4 r54 CmergeK
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  53 c37e7cd9f2bd r53
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  52 0d153e3ad632 r52
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  51 97ac964e34b7 r51
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  50 900dd066a072 r50
  | | | | | | | | | | | | | | | |
  o---------+---------+ | | | | |  49 673f5499c8c2 r49
   / / / / / / / / / / / / / / /
  +-----o / / / / / / / / / / /  48 8ecb28746ec4 r48 CmergeJ
  | | | |/ / / / / / / / / / /
  | | | | | | | o | | | | | |  47 d6c9e2d27f14 r47 CmergeI
  | | | | | | | | | | | | | |
  | | | +-------o | | | | | |  46 bfcfd9a61e84 r46
  | | | | | | |/ / / / / / /
  +---------------+-------o  45 40553f55397e r45 CmergeH
  | | | | | | | | | | | |
  | | o | | | | | | | | |  44 d94da36be176 r44 CmergeG
  | | | | | | | | | | | |
  +---o---------+ | | | |  43 4b39f229a0ce r43
  | |  / / / / / / / / /
  +---+---o / / / / / /  42 43fc0b77ff07 r42 CmergeF
  | | | |  / / / / / /
  | | | | | | | | o |  41 88eace5ce682 r41 CmergeE
  | | | | | | | | | |
  | | | | | | | | o |  40 d928b4e8a515 r40
  | | | | | | | | | |
  +-------+-------o |  39 88714f4125cb r39
  | | | | | | | |  /
  | | | | +---+---o  38 e3e6738c56ce r38 CmergeD
  | | | | | | | |
  | | | | | | | o  37 32b41ca704e1 r37 CmergeC
  | | | | | | | |
  | | | | +-+---o  36 01e29e20ea3f r36
  | | | | | | |
  | | | o | | |  35 1f4a19f83a29 r35 CmergeB
  | | |/|/ / /
  | o | | | |  34 722d1b8b8942 r34 CmergeA
  | | | | | |
  | o | | | |  33 47c836a1f13e r33
  | | | | | |
  | o | | | |  32 2ea3fbf151b5 r32
  | | | | | |
  | o | | | |  31 0c3f2ba59eb7 r31
  | | | | | |
  | o | | | |  30 f3441cd3e664 r30
  | | | | | |
  | o | | | |  29 b9c3aa92fba5 r29
  | | | | | |
  | o | | | |  28 3bdb00d5c818 r28
  | | | | | |
  | o---+ | |  27 2bd677d0f13a r27
  |/ / / / /
  | | | | o  26 de05b9c29ec7 r26 CbaseE
  | | | | |
  | | | o |  25 ad46a4a0fc10 r25 CbaseD
  | | | | |
  | | | o |  24 a457569c5306 r24
  | | | | |
  | | | o |  23 f2bdd828a3aa r23
  | | | | |
  | | | o |  22 5ce588c2b7c5 r22
  | | | | |
  | | | o |  21 17b6e6bac221 r21
  | | | |/
  | o---+  20 b115c694654e r20 CbaseC
  |  / /
  o | |  19 884936b34999 r19 CbaseB
  | | |
  o---+  18 9729470d9329 r18
   / /
  o /  17 4f5078f7da8a r17 CbaseA
  |/
  o    16 3e1560705803 r16 Bfinal
  |\
  | o    15 55bf3fdb634f r15 BmergeD
  | |\
  o---+  14 39bab1cb1cbe r14 BmergeC
  |/ /
  | o    13 f7c6e7bfbcd0 r13 BmergeB
  | |\
  o---+  12 26f59ee8b1d7 r12 BmergeA
  |/ /
  | o  11 3e2da24aee59 r11 BbaseA
  | |
  | o  10 5ba9a53052ed r10 Afinal
  |/|
  o |    9 07c648efceeb r9 AmergeB BbaseB
  |\ \
  +---o  8 c81423bf5a24 r8 AmergeA
  | |/
  | o  7 65eb34ffc3a8 r7 AbaseB
  | |
  | o  6 0c1445abb33d r6
  | |
  o |  5 c8d03c1b5e94 r5 AbaseA
  | |
  o |  4 bebd167eb94d r4
  | |
  o |  3 2dc09a01254d r3
  |/
  o  2 01241442b3c2 r2 base
  |
  o  1 66f7d451a68b r1
  |
  o  0 1ea73414a91b r0
  


Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  bebd167eb94d257ace0e814aeb98e6972ed2970d
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
  c8d03c1b5e94af74b772900c58259d2e08917735
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: bebd167eb94d257ace0e814aeb98e6972ed2970d
      - rank: 5
      - pow2: 2
      - pidx: p1
  0c1445abb33dfdf88f26bd1cc0e5f2169146b371
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  65eb34ffc3a822669d6a66afdcc2057050439251
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 0c1445abb33dfdf88f26bd1cc0e5f2169146b371
      - rank: 4
      - pow2: 2
      - pidx: p1
  c81423bf5a24e28484a591de88cc764941af2c5a
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p2
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p1
  07c648efceebcbbc7e048f8f58dff9fc54b867a7
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p2
  5ba9a53052edb1e633e32a7e9d55bb52c939eeef
  - rank: 11
  - pow2: 1
  - exclusive-part:
    - parent: 07c648efceebcbbc7e048f8f58dff9fc54b867a7
      - rank: 9
      - pow2: 3
      - pidx: p2
    - size: 1
    - splits:
      - head:   07c648efceebcbbc7e048f8f58dff9fc54b867a7
        length: 1
  - tail-part:
    - parent: c81423bf5a24e28484a591de88cc764941af2c5a
      - rank: 9
      - pow2: 3
      - pidx: p1
  3e2da24aee59e0c496381ae14182dd52344b5742
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: 5ba9a53052edb1e633e32a7e9d55bb52c939eeef
      - rank: 11
      - pow2: 1
      - pidx: p1
  26f59ee8b1d796abfa4071cdef1a96de632ddba8
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 3e2da24aee59e0c496381ae14182dd52344b5742
      - rank: 12
      - pow2: 3
      - pidx: p1
  f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 3e2da24aee59e0c496381ae14182dd52344b5742
      - rank: 12
      - pow2: 3
      - pidx: p2
  39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
  - rank: 15
  - pow2: 1
  - exclusive-part:
    - parent: 26f59ee8b1d796abfa4071cdef1a96de632ddba8
      - rank: 13
      - pow2: 3
      - pidx: p1
    - size: 1
    - splits:
      - head:   26f59ee8b1d796abfa4071cdef1a96de632ddba8
        length: 1
  - tail-part:
    - parent: f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
      - rank: 13
      - pow2: 3
      - pidx: p2
  55bf3fdb634f1f8f0b779f1a5e622fa475a2b98c
  - rank: 15
  - pow2: 1
  - exclusive-part:
    - parent: 26f59ee8b1d796abfa4071cdef1a96de632ddba8
      - rank: 13
      - pow2: 3
      - pidx: p2
    - size: 1
    - splits:
      - head:   26f59ee8b1d796abfa4071cdef1a96de632ddba8
        length: 1
  - tail-part:
    - parent: f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
      - rank: 13
      - pow2: 3
      - pidx: p1
  3e156070580322eac46974a017d8a19f0e0e107a
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: 39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
      - rank: 15
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
        length: 1
  - tail-part:
    - parent: 55bf3fdb634f1f8f0b779f1a5e622fa475a2b98c
      - rank: 15
      - pow2: 1
      - pidx: p2
  4f5078f7da8a803a00a633b0243fa335c4e74ad6
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 3e156070580322eac46974a017d8a19f0e0e107a
      - rank: 17
      - pow2: 4
      - pidx: p1
  9729470d93299765a5e2499301c63ce99ffff19e
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 3e156070580322eac46974a017d8a19f0e0e107a
      - rank: 17
      - pow2: 4
      - pidx: p1
  884936b34999687314cc009cba0dd88098bb5057
  - rank: 19
  - pow2: 4
  - tail-part:
    - parent: 9729470d93299765a5e2499301c63ce99ffff19e
      - rank: 18
      - pow2: 4
      - pidx: p1
  b115c694654ecc0ae9dbf84523309bcbdf882307
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 3e156070580322eac46974a017d8a19f0e0e107a
      - rank: 17
      - pow2: 4
      - pidx: p1
  17b6e6bac221de6517e9d34234393fc7864eed49
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 3e156070580322eac46974a017d8a19f0e0e107a
      - rank: 17
      - pow2: 4
      - pidx: p1
  5ce588c2b7c5790e36af99309a7435029470881e
  - rank: 19
  - pow2: 4
  - tail-part:
    - parent: 17b6e6bac221de6517e9d34234393fc7864eed49
      - rank: 18
      - pow2: 4
      - pidx: p1
  f2bdd828a3aa74eff9d50bf5e77ad7fbeb38bcec
  - rank: 20
  - pow2: 4
  - tail-part:
    - parent: 5ce588c2b7c5790e36af99309a7435029470881e
      - rank: 19
      - pow2: 4
      - pidx: p1
  a457569c530677cf4abcf22abb6e1e0448a703e9
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: f2bdd828a3aa74eff9d50bf5e77ad7fbeb38bcec
      - rank: 20
      - pow2: 4
      - pidx: p1
  ad46a4a0fc10d50de79329c5d5227a355e1e60df
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: a457569c530677cf4abcf22abb6e1e0448a703e9
      - rank: 21
      - pow2: 4
      - pidx: p1
  de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 3e156070580322eac46974a017d8a19f0e0e107a
      - rank: 17
      - pow2: 4
      - pidx: p1
  2bd677d0f13ad7ee2d1b04f53b971a3e6b3f25d8
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  3bdb00d5c818384a8a3377789e7536615487a262
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: 2bd677d0f13ad7ee2d1b04f53b971a3e6b3f25d8
      - rank: 21
      - pow2: 2
      - pidx: p1
  b9c3aa92fba570bda608761e9ce25f0037401665
  - rank: 23
  - pow2: 4
  - tail-part:
    - parent: 3bdb00d5c818384a8a3377789e7536615487a262
      - rank: 22
      - pow2: 4
      - pidx: p1
  f3441cd3e6644c074d4e021a99d002b853e07038
  - rank: 24
  - pow2: 4
  - tail-part:
    - parent: b9c3aa92fba570bda608761e9ce25f0037401665
      - rank: 23
      - pow2: 4
      - pidx: p1
  0c3f2ba59eb7de765275f51411a5bc210767e585
  - rank: 25
  - pow2: 4
  - tail-part:
    - parent: f3441cd3e6644c074d4e021a99d002b853e07038
      - rank: 24
      - pow2: 4
      - pidx: p1
  2ea3fbf151b5f9ba9703169dbea412b0202b67e8
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: 0c3f2ba59eb7de765275f51411a5bc210767e585
      - rank: 25
      - pow2: 4
      - pidx: p1
  47c836a1f13ef41c3394a9d435f69c422fc6d28b
  - rank: 27
  - pow2: 4
  - tail-part:
    - parent: 2ea3fbf151b5f9ba9703169dbea412b0202b67e8
      - rank: 26
      - pow2: 4
      - pidx: p1
  722d1b8b8942f62840c7ffcdd273cd579dd7012d
  - rank: 28
  - pow2: 4
  - tail-part:
    - parent: 47c836a1f13ef41c3394a9d435f69c422fc6d28b
      - rank: 27
      - pow2: 4
      - pidx: p1
  1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
  01e29e20ea3f7ed0d1b3894baffb277f15f110c1
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  32b41ca704e142a3d62ffd360b72f3a581336e96
  - rank: 25
  - pow2: 4
  - tail-part:
    - parent: 01e29e20ea3f7ed0d1b3894baffb277f15f110c1
      - rank: 24
      - pow2: 3
      - pidx: p1
  e3e6738c56ced8d1732d824579530511daba8789
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
  88714f4125cbd9202c8017e87a97b2ef9c663ce2
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  d928b4e8a515721c04527bdbf88859dea8ee2ad6
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: 88714f4125cbd9202c8017e87a97b2ef9c663ce2
      - rank: 21
      - pow2: 2
      - pidx: p1
  88eace5ce6823d539f94145551ab8a23125df051
  - rank: 23
  - pow2: 4
  - tail-part:
    - parent: d928b4e8a515721c04527bdbf88859dea8ee2ad6
      - rank: 22
      - pow2: 4
      - pidx: p1
  43fc0b77ff079900703a20b3cbe3b6645d345582
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  4b39f229a0ced1f6ffce4b63e91dd6034d6aa640
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
    - size: 2
    - splits:
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  d94da36be176bdbf1a3755708ee6fbde5a53e0b2
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: 4b39f229a0ced1f6ffce4b63e91dd6034d6aa640
      - rank: 25
      - pow2: 3
      - pidx: p1
  40553f55397e85f381e3d5813d838b180b707261
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  bfcfd9a61e8493d1968cb9cbd83f656ceeb5762a
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
  d6c9e2d27f140892757ae56fef23f89916420b8a
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: bfcfd9a61e8493d1968cb9cbd83f656ceeb5762a
      - rank: 20
      - pow2: 2
      - pidx: p1
  8ecb28746ec4493774464c23a3f01a18d3cfd172
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  673f5499c8c2e2165142bf8c2765ef494d66cc3e
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  900dd066a072f7f2bd5837614c8a1084a9b131a5
  - rank: 25
  - pow2: 4
  - tail-part:
    - parent: 673f5499c8c2e2165142bf8c2765ef494d66cc3e
      - rank: 24
      - pow2: 3
      - pidx: p1
  97ac964e34b7613f95480ec2a4c2cef5500d07fa
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: 900dd066a072f7f2bd5837614c8a1084a9b131a5
      - rank: 25
      - pow2: 4
      - pidx: p1
  0d153e3ad6320fba792315e52c5cfb53009cf50b
  - rank: 27
  - pow2: 4
  - tail-part:
    - parent: 97ac964e34b7613f95480ec2a4c2cef5500d07fa
      - rank: 26
      - pow2: 4
      - pidx: p1
  c37e7cd9f2bdc41916072669b18a38133f99867d
  - rank: 28
  - pow2: 4
  - tail-part:
    - parent: 0d153e3ad6320fba792315e52c5cfb53009cf50b
      - rank: 27
      - pow2: 4
      - pidx: p1
  9a67238ad1c448d3dd52eb183b96890eaca5676e
  - rank: 29
  - pow2: 4
  - tail-part:
    - parent: c37e7cd9f2bdc41916072669b18a38133f99867d
      - rank: 28
      - pow2: 4
      - pidx: p1
  76151e8066e129d27b08ab2a62a3cabba87d91c3
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
  c7c1497fc270aa2ed1de7d6202c1c7be605557a5
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: 76151e8066e129d27b08ab2a62a3cabba87d91c3
      - rank: 20
      - pow2: 2
      - pidx: p1
  e7135b665740f8de5ee7c6fd2c55b95265c5cbaa
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: c7c1497fc270aa2ed1de7d6202c1c7be605557a5
      - rank: 21
      - pow2: 4
      - pidx: p1
  29141354a762bb870a2606de41208700e27eaf53
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  0484d39906c8af29405c38238d7d7541cfd21b27
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
    - size: 2
    - splits:
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  5eec91b12a588a5b6d9cd8d7dd5ced3070cc9f0e
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: 0484d39906c8af29405c38238d7d7541cfd21b27
      - rank: 25
      - pow2: 3
      - pidx: p1
  c84da74cf586ba35c9c7a70b2a29299c76005ff3
  - rank: 27
  - pow2: 4
  - tail-part:
    - parent: 5eec91b12a588a5b6d9cd8d7dd5ced3070cc9f0e
      - rank: 26
      - pow2: 4
      - pidx: p1
  3871506da61ef9862ff9117e2e7255479489d2d5
  - rank: 28
  - pow2: 4
  - tail-part:
    - parent: c84da74cf586ba35c9c7a70b2a29299c76005ff3
      - rank: 27
      - pow2: 4
      - pidx: p1
  bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  b33fd5ad4c0c086b721ee2457e38c52bb6210763
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
  d99e0f7dad5be63dea245790377dfd63c094e9f0
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  e4cfd6264623da7c5bb90277ca857bff677236e9
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: d99e0f7dad5be63dea245790377dfd63c094e9f0
      - rank: 21
      - pow2: 2
      - pidx: p1
  fac9e582edd1c53906b1b1c8f48d5d612213ac63
  - rank: 23
  - pow2: 4
  - tail-part:
    - parent: e4cfd6264623da7c5bb90277ca857bff677236e9
      - rank: 22
      - pow2: 4
      - pidx: p1
  d917f77a643960caa231e26b47a57edea5410d00
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
  c3c7fa726f887f8a24b87244d4dc2389a352fc12
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: d917f77a643960caa231e26b47a57edea5410d00
      - rank: 20
      - pow2: 2
      - pidx: p1
  4f3b41956174ddc0b5c42448fcbf39c665e23d27
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  eed373b0090dceccc6935c146824995087762127
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: d94da36be176bdbf1a3755708ee6fbde5a53e0b2
      - rank: 26
      - pow2: 4
      - pidx: p2
    - size: 7
    - splits:
      - head:   d94da36be176bdbf1a3755708ee6fbde5a53e0b2
        length: 2
      - head:   ad46a4a0fc10d50de79329c5d5227a355e1e60df
        length: 5
  - tail-part:
    - parent: 722d1b8b8942f62840c7ffcdd273cd579dd7012d
      - rank: 28
      - pow2: 4
      - pidx: p1
  31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
        length: 2
  - tail-part:
    - parent: 43fc0b77ff079900703a20b3cbe3b6645d345582
      - rank: 21
      - pow2: 2
      - pidx: p2
  698970a2480b77b03bb3a47ba59934c9d43fdef8
  - rank: 31
  - pow2: 3
  - exclusive-part:
    - parent: 88eace5ce6823d539f94145551ab8a23125df051
      - rank: 23
      - pow2: 4
      - pidx: p2
    - size: 5
    - splits:
      - head:   88eace5ce6823d539f94145551ab8a23125df051
        length: 3
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: 32b41ca704e142a3d62ffd360b72f3a581336e96
      - rank: 25
      - pow2: 4
      - pidx: p1
  790cdfecd168ad7a449cda77ce67c265cd341d57
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: e3e6738c56ced8d1732d824579530511daba8789
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   e3e6738c56ced8d1732d824579530511daba8789
        length: 2
  - tail-part:
    - parent: 40553f55397e85f381e3d5813d838b180b707261
      - rank: 21
      - pow2: 2
      - pidx: p2
  37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
  - rank: 29
  - pow2: 3
  - exclusive-part:
    - parent: d6c9e2d27f140892757ae56fef23f89916420b8a
      - rank: 21
      - pow2: 4
      - pidx: p2
    - size: 4
    - splits:
      - head:   d6c9e2d27f140892757ae56fef23f89916420b8a
        length: 4
  - tail-part:
    - parent: 4f3b41956174ddc0b5c42448fcbf39c665e23d27
      - rank: 24
      - pow2: 3
      - pidx: p1
  97d19fc5236f8fddc35f1280c19ad2b2103ed619
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 8ecb28746ec4493774464c23a3f01a18d3cfd172
      - rank: 21
      - pow2: 2
      - pidx: p2
    - size: 3
    - splits:
      - head:   8ecb28746ec4493774464c23a3f01a18d3cfd172
        length: 1
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: c3c7fa726f887f8a24b87244d4dc2389a352fc12
      - rank: 21
      - pow2: 4
      - pidx: p1
  89a0fe204177cd77929e08fa7513ec4047453322
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: fac9e582edd1c53906b1b1c8f48d5d612213ac63
      - rank: 23
      - pow2: 4
      - pidx: p1
    - size: 6
    - splits:
      - head:   fac9e582edd1c53906b1b1c8f48d5d612213ac63
        length: 6
  - tail-part:
    - parent: 9a67238ad1c448d3dd52eb183b96890eaca5676e
      - rank: 29
      - pow2: 4
      - pidx: p2
  82238c0bc95013ccd9471ed46a28f2f8fc4dd109
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
        length: 2
  - tail-part:
    - parent: e7135b665740f8de5ee7c6fd2c55b95265c5cbaa
      - rank: 22
      - pow2: 4
      - pidx: p2
  cd345198cf120276f75c45707c24bb3fe344a7dc
  - rank: 27
  - pow2: 1
  - exclusive-part:
    - parent: 29141354a762bb870a2606de41208700e27eaf53
      - rank: 24
      - pow2: 3
      - pidx: p2
    - size: 2
    - splits:
      - head:   29141354a762bb870a2606de41208700e27eaf53
        length: 2
  - tail-part:
    - parent: b33fd5ad4c0c086b721ee2457e38c52bb6210763
      - rank: 24
      - pow2: 3
      - pidx: p1
  0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 2
    - splits:
      - head:   bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
        length: 2
  - tail-part:
    - parent: 3871506da61ef9862ff9117e2e7255479489d2d5
      - rank: 28
      - pow2: 4
      - pidx: p2
  1da228afcf06af6196afa761de51004d15734b84
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 2
    - splits:
      - head:   bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
        length: 2
  - tail-part:
    - parent: 3871506da61ef9862ff9117e2e7255479489d2d5
      - rank: 28
      - pow2: 4
      - pidx: p2
  b3cf98c3d5874e655f78ec8e4f47ff788349b3fb
  - rank: 49
  - pow2: 4
  - exclusive-part:
    - parent: 89a0fe204177cd77929e08fa7513ec4047453322
      - rank: 36
      - pow2: 5
      - pidx: p2
    - size: 12
    - splits:
      - head:   89a0fe204177cd77929e08fa7513ec4047453322
        length: 5
      - head:   9a67238ad1c448d3dd52eb183b96890eaca5676e
        length: 7
  - tail-part:
    - parent: eed373b0090dceccc6935c146824995087762127
      - rank: 36
      - pow2: 5
      - pidx: p1
  dbde319d43a36a94df7cfc877fb97fa1b6baaa80
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: 31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 5
    - splits:
      - head:   31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
        length: 2
      - head:   43fc0b77ff079900703a20b3cbe3b6645d345582
        length: 1
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: 82238c0bc95013ccd9471ed46a28f2f8fc4dd109
      - rank: 25
      - pow2: 3
      - pidx: p2
  28be96b80dc1d1af3a682c04b1961d6ed173df1e
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: cd345198cf120276f75c45707c24bb3fe344a7dc
      - rank: 27
      - pow2: 1
      - pidx: p2
    - size: 4
    - splits:
      - head:   cd345198cf120276f75c45707c24bb3fe344a7dc
        length: 2
      - head:   b33fd5ad4c0c086b721ee2457e38c52bb6210763
        length: 2
  - tail-part:
    - parent: 698970a2480b77b03bb3a47ba59934c9d43fdef8
      - rank: 31
      - pow2: 3
      - pidx: p1
  469c700e9ed8144bee92d51174ce07fdd2f3510b
  - rank: 37
  - pow2: 5
  - exclusive-part:
    - parent: 790cdfecd168ad7a449cda77ce67c265cd341d57
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 5
    - splits:
      - head:   790cdfecd168ad7a449cda77ce67c265cd341d57
        length: 5
  - tail-part:
    - parent: 0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
      - rank: 31
      - pow2: 2
      - pidx: p2
  c7d3029bf7319c20e0c14fdae8b2e06c701455fb
  - rank: 38
  - pow2: 5
  - exclusive-part:
    - parent: 37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
      - rank: 29
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
        length: 4
      - head:   4f3b41956174ddc0b5c42448fcbf39c665e23d27
        length: 2
  - tail-part:
    - parent: 1da228afcf06af6196afa761de51004d15734b84
      - rank: 31
      - pow2: 2
      - pidx: p2
  2472d042ec9577662c733295739e360ba18e0bc2
  - rank: 43
  - pow2: 5
  - exclusive-part:
    - parent: 97d19fc5236f8fddc35f1280c19ad2b2103ed619
      - rank: 25
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   97d19fc5236f8fddc35f1280c19ad2b2103ed619
        length: 2
      - head:   c3c7fa726f887f8a24b87244d4dc2389a352fc12
        length: 4
  - tail-part:
    - parent: eed373b0090dceccc6935c146824995087762127
      - rank: 36
      - pow2: 5
      - pidx: p2
  041e1188f5f170496b7d1f46ddb0e566bf2de697
  - rank: 55
  - pow2: 4
  - exclusive-part:
    - parent: 2472d042ec9577662c733295739e360ba18e0bc2
      - rank: 43
      - pow2: 5
      - pidx: p2
    - size: 5
    - splits:
      - head:   2472d042ec9577662c733295739e360ba18e0bc2
        length: 5
  - tail-part:
    - parent: b3cf98c3d5874e655f78ec8e4f47ff788349b3fb
      - rank: 49
      - pow2: 4
      - pidx: p1
  8b79544bb56d6be7ba5e7ac693e9054f20d35af6
  - rank: 48
  - pow2: 5
  - exclusive-part:
    - parent: dbde319d43a36a94df7cfc877fb97fa1b6baaa80
      - rank: 31
      - pow2: 2
      - pidx: p1
    - size: 9
    - splits:
      - head:   dbde319d43a36a94df7cfc877fb97fa1b6baaa80
        length: 4
      - head:   82238c0bc95013ccd9471ed46a28f2f8fc4dd109
        length: 2
      - head:   e7135b665740f8de5ee7c6fd2c55b95265c5cbaa
        length: 3
  - tail-part:
    - parent: c7d3029bf7319c20e0c14fdae8b2e06c701455fb
      - rank: 38
      - pow2: 5
      - pidx: p2
  8ae32c3ed67036ef7787649b4dbe2ea844ca633d
  - rank: 48
  - pow2: 4
  - exclusive-part:
    - parent: 28be96b80dc1d1af3a682c04b1961d6ed173df1e
      - rank: 36
      - pow2: 5
      - pidx: p1
    - size: 10
    - splits:
      - head:   28be96b80dc1d1af3a682c04b1961d6ed173df1e
        length: 4
      - head:   698970a2480b77b03bb3a47ba59934c9d43fdef8
        length: 4
      - head:   32b41ca704e142a3d62ffd360b72f3a581336e96
        length: 2
  - tail-part:
    - parent: 469c700e9ed8144bee92d51174ce07fdd2f3510b
      - rank: 37
      - pow2: 5
      - pidx: p2
  721ba7c5f4ff4b95fa05d28d6ff3360873a42a9f
  - rank: 77
  - pow2: 6
  - exclusive-part:
    - parent: 8b79544bb56d6be7ba5e7ac693e9054f20d35af6
      - rank: 48
      - pow2: 5
      - pidx: p2
    - size: 21
    - splits:
      - head:   8b79544bb56d6be7ba5e7ac693e9054f20d35af6
        length: 14
      - head:   4f3b41956174ddc0b5c42448fcbf39c665e23d27
        length: 1
      - head:   1da228afcf06af6196afa761de51004d15734b84
        length: 2
      - head:   3871506da61ef9862ff9117e2e7255479489d2d5
        length: 4
  - tail-part:
    - parent: 041e1188f5f170496b7d1f46ddb0e566bf2de697
      - rank: 55
      - pow2: 4
      - pidx: p1
  84d6ec6a8e21dac4717999019d29df0054dac0e0
  - rank: 65
  - pow2: 6
  - exclusive-part:
    - parent: 8ae32c3ed67036ef7787649b4dbe2ea844ca633d
      - rank: 48
      - pow2: 4
      - pidx: p1
    - size: 16
    - splits:
      - head:   8ae32c3ed67036ef7787649b4dbe2ea844ca633d
        length: 14
      - head:   40553f55397e85f381e3d5813d838b180b707261
        length: 1
      - head:   0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
        length: 1
  - tail-part:
    - parent: 8b79544bb56d6be7ba5e7ac693e9054f20d35af6
      - rank: 48
      - pow2: 5
      - pidx: p2
  01f771406cab36b0a9a5dd5f74bacf9596ab1b64
  - rank: 95
  - pow2: 4
  - exclusive-part:
    - parent: 84d6ec6a8e21dac4717999019d29df0054dac0e0
      - rank: 65
      - pow2: 6
      - pidx: p2
    - size: 17
    - splits:
      - head:   84d6ec6a8e21dac4717999019d29df0054dac0e0
        length: 17
  - tail-part:
    - parent: 721ba7c5f4ff4b95fa05d28d6ff3360873a42a9f
      - rank: 77
      - pow2: 6
      - pidx: p1

Basic check
-----------

  $ hg showsort 'Afinal'
  5ba9a53052ed
  07c648efceeb
  c81423bf5a24
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  $ checktopo Afinal
  ### FROM 5ba9a53052edb1e633e32a7e9d55bb52c939eeef ###
  === checking 5ba9a53052ed ===
  === checking 07c648efceeb ===
  === checking c81423bf5a24 ===
  === checking 65eb34ffc3a8 ===
  === checking 0c1445abb33d ===
  === checking c8d03c1b5e94 ===
  === checking bebd167eb94d ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  $ hg debug::stable-tail-info 'Afinal'
  5ba9a53052edb1e633e32a7e9d55bb52c939eeef
  - rank: 11
  - pow2: 1
  - exclusive-part:
    - parent: 07c648efceebcbbc7e048f8f58dff9fc54b867a7
      - rank: 9
      - pow2: 3
      - pidx: p2
    - size: 1
    - splits:
      - head:   07c648efceebcbbc7e048f8f58dff9fc54b867a7
        length: 1
  - tail-part:
    - parent: c81423bf5a24e28484a591de88cc764941af2c5a
      - rank: 9
      - pow2: 3
      - pidx: p1

  $ hg showsort 'AmergeA'
  c81423bf5a24
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  $ checktopo AmergeA
  ### FROM c81423bf5a24e28484a591de88cc764941af2c5a ###
  === checking c81423bf5a24 ===
  === checking 65eb34ffc3a8 ===
  === checking 0c1445abb33d ===
  === checking c8d03c1b5e94 ===
  === checking bebd167eb94d ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  $ hg debug::stable-tail-info 'AmergeA'
  c81423bf5a24e28484a591de88cc764941af2c5a
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p2
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p1

  $ hg showsort 'AmergeB'
  07c648efceeb
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  $ checktopo AmergeB
  ### FROM 07c648efceebcbbc7e048f8f58dff9fc54b867a7 ###
  === checking 07c648efceeb ===
  === checking 65eb34ffc3a8 ===
  === checking 0c1445abb33d ===
  === checking c8d03c1b5e94 ===
  === checking bebd167eb94d ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  $ hg debug::stable-tail-info 'AmergeB'
  07c648efceebcbbc7e048f8f58dff9fc54b867a7
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p2


close criss cross
  $ hg showsort 'Bfinal'
  3e1560705803
  39bab1cb1cbe
  55bf3fdb634f
  26f59ee8b1d7
  f7c6e7bfbcd0
  3e2da24aee59
  5ba9a53052ed
  07c648efceeb
  c81423bf5a24
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  $ checktopo Bfinal
  ### FROM 3e156070580322eac46974a017d8a19f0e0e107a ###
  === checking 3e1560705803 ===
  === checking 39bab1cb1cbe ===
  === checking 55bf3fdb634f ===
  === checking 26f59ee8b1d7 ===
  === checking f7c6e7bfbcd0 ===
  === checking 3e2da24aee59 ===
  === checking 5ba9a53052ed ===
  === checking 07c648efceeb ===
  === checking c81423bf5a24 ===
  === checking 65eb34ffc3a8 ===
  === checking 0c1445abb33d ===
  === checking c8d03c1b5e94 ===
  === checking bebd167eb94d ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  $ hg debug::stable-tail-info 'Bfinal'
  3e156070580322eac46974a017d8a19f0e0e107a
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: 39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
      - rank: 15
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
        length: 1
  - tail-part:
    - parent: 55bf3fdb634f1f8f0b779f1a5e622fa475a2b98c
      - rank: 15
      - pow2: 1
      - pidx: p2


many branches criss cross

  $ hg showsort 'Cfinal'
  01f771406cab
  84d6ec6a8e21
  8ae32c3ed670
  28be96b80dc1
  cd345198cf12
  29141354a762
  b33fd5ad4c0c
  698970a2480b
  88eace5ce682
  d928b4e8a515
  88714f4125cb
  32b41ca704e1
  01e29e20ea3f
  469c700e9ed8
  790cdfecd168
  e3e6738c56ce
  40553f55397e
  0bab31f71a21
  721ba7c5f4ff
  8b79544bb56d
  dbde319d43a3
  31d7b43cc321
  1f4a19f83a29
  43fc0b77ff07
  82238c0bc950
  c713eae2d31f
  e7135b665740
  c7c1497fc270
  76151e8066e1
  c7d3029bf731
  37ad3ab0cddf
  d6c9e2d27f14
  bfcfd9a61e84
  4f3b41956174
  1da228afcf06
  bf6593f7e073
  3871506da61e
  c84da74cf586
  5eec91b12a58
  0484d39906c8
  041e1188f5f1
  2472d042ec95
  97d19fc5236f
  8ecb28746ec4
  c3c7fa726f88
  d917f77a6439
  b3cf98c3d587
  89a0fe204177
  fac9e582edd1
  e4cfd6264623
  d99e0f7dad5b
  de05b9c29ec7
  9a67238ad1c4
  c37e7cd9f2bd
  0d153e3ad632
  97ac964e34b7
  900dd066a072
  673f5499c8c2
  b115c694654e
  eed373b0090d
  d94da36be176
  4b39f229a0ce
  ad46a4a0fc10
  a457569c5306
  f2bdd828a3aa
  5ce588c2b7c5
  17b6e6bac221
  722d1b8b8942
  47c836a1f13e
  2ea3fbf151b5
  0c3f2ba59eb7
  f3441cd3e664
  b9c3aa92fba5
  3bdb00d5c818
  2bd677d0f13a
  4f5078f7da8a
  884936b34999
  9729470d9329
  3e1560705803
  39bab1cb1cbe
  55bf3fdb634f
  26f59ee8b1d7
  f7c6e7bfbcd0
  3e2da24aee59
  5ba9a53052ed
  07c648efceeb
  c81423bf5a24
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b
  $ checktopo Cfinal
  ### FROM 01f771406cab36b0a9a5dd5f74bacf9596ab1b64 ###
  === checking 01f771406cab ===
  === checking 84d6ec6a8e21 ===
  === checking 8ae32c3ed670 ===
  === checking 28be96b80dc1 ===
  === checking cd345198cf12 ===
  === checking 29141354a762 ===
  === checking b33fd5ad4c0c ===
  === checking 698970a2480b ===
  === checking 88eace5ce682 ===
  === checking d928b4e8a515 ===
  === checking 88714f4125cb ===
  === checking 32b41ca704e1 ===
  === checking 01e29e20ea3f ===
  === checking 469c700e9ed8 ===
  === checking 790cdfecd168 ===
  === checking e3e6738c56ce ===
  === checking 40553f55397e ===
  === checking 0bab31f71a21 ===
  === checking 721ba7c5f4ff ===
  === checking 8b79544bb56d ===
  === checking dbde319d43a3 ===
  === checking 31d7b43cc321 ===
  === checking 1f4a19f83a29 ===
  === checking 43fc0b77ff07 ===
  === checking 82238c0bc950 ===
  === checking c713eae2d31f ===
  === checking e7135b665740 ===
  === checking c7c1497fc270 ===
  === checking 76151e8066e1 ===
  === checking c7d3029bf731 ===
  === checking 37ad3ab0cddf ===
  === checking d6c9e2d27f14 ===
  === checking bfcfd9a61e84 ===
  === checking 4f3b41956174 ===
  === checking 1da228afcf06 ===
  === checking bf6593f7e073 ===
  === checking 3871506da61e ===
  === checking c84da74cf586 ===
  === checking 5eec91b12a58 ===
  === checking 0484d39906c8 ===
  === checking 041e1188f5f1 ===
  === checking 2472d042ec95 ===
  === checking 97d19fc5236f ===
  === checking 8ecb28746ec4 ===
  === checking c3c7fa726f88 ===
  === checking d917f77a6439 ===
  === checking b3cf98c3d587 ===
  === checking 89a0fe204177 ===
  === checking fac9e582edd1 ===
  === checking e4cfd6264623 ===
  === checking d99e0f7dad5b ===
  === checking de05b9c29ec7 ===
  === checking 9a67238ad1c4 ===
  === checking c37e7cd9f2bd ===
  === checking 0d153e3ad632 ===
  === checking 97ac964e34b7 ===
  === checking 900dd066a072 ===
  === checking 673f5499c8c2 ===
  === checking b115c694654e ===
  === checking eed373b0090d ===
  === checking d94da36be176 ===
  === checking 4b39f229a0ce ===
  === checking ad46a4a0fc10 ===
  === checking a457569c5306 ===
  === checking f2bdd828a3aa ===
  === checking 5ce588c2b7c5 ===
  === checking 17b6e6bac221 ===
  === checking 722d1b8b8942 ===
  === checking 47c836a1f13e ===
  === checking 2ea3fbf151b5 ===
  === checking 0c3f2ba59eb7 ===
  === checking f3441cd3e664 ===
  === checking b9c3aa92fba5 ===
  === checking 3bdb00d5c818 ===
  === checking 2bd677d0f13a ===
  === checking 4f5078f7da8a ===
  === checking 884936b34999 ===
  === checking 9729470d9329 ===
  === checking 3e1560705803 ===
  === checking 39bab1cb1cbe ===
  === checking 55bf3fdb634f ===
  === checking 26f59ee8b1d7 ===
  === checking f7c6e7bfbcd0 ===
  === checking 3e2da24aee59 ===
  === checking 5ba9a53052ed ===
  === checking 07c648efceeb ===
  === checking c81423bf5a24 ===
  === checking 65eb34ffc3a8 ===
  === checking 0c1445abb33d ===
  === checking c8d03c1b5e94 ===
  === checking bebd167eb94d ===
  === checking 2dc09a01254d ===
  === checking 01241442b3c2 ===
  === checking 66f7d451a68b ===
  === checking 1ea73414a91b ===
  $ hg showsort 'Cfinal' --limit 72
  01f771406cab
  84d6ec6a8e21
  8ae32c3ed670
  28be96b80dc1
  cd345198cf12
  29141354a762
  b33fd5ad4c0c
  698970a2480b
  88eace5ce682
  d928b4e8a515
  88714f4125cb
  32b41ca704e1
  01e29e20ea3f
  469c700e9ed8
  790cdfecd168
  e3e6738c56ce
  40553f55397e
  0bab31f71a21
  721ba7c5f4ff
  8b79544bb56d
  dbde319d43a3
  31d7b43cc321
  1f4a19f83a29
  43fc0b77ff07
  82238c0bc950
  c713eae2d31f
  e7135b665740
  c7c1497fc270
  76151e8066e1
  c7d3029bf731
  37ad3ab0cddf
  d6c9e2d27f14
  bfcfd9a61e84
  4f3b41956174
  1da228afcf06
  bf6593f7e073
  3871506da61e
  c84da74cf586
  5eec91b12a58
  0484d39906c8
  041e1188f5f1
  2472d042ec95
  97d19fc5236f
  8ecb28746ec4
  c3c7fa726f88
  d917f77a6439
  b3cf98c3d587
  89a0fe204177
  fac9e582edd1
  e4cfd6264623
  d99e0f7dad5b
  de05b9c29ec7
  9a67238ad1c4
  c37e7cd9f2bd
  0d153e3ad632
  97ac964e34b7
  900dd066a072
  673f5499c8c2
  b115c694654e
  eed373b0090d
  d94da36be176
  4b39f229a0ce
  ad46a4a0fc10
  a457569c5306
  f2bdd828a3aa
  5ce588c2b7c5
  17b6e6bac221
  722d1b8b8942
  47c836a1f13e
  2ea3fbf151b5
  0c3f2ba59eb7
  f3441cd3e664
  $ hg showsort 'Cfinal' --limit 33
  01f771406cab
  84d6ec6a8e21
  8ae32c3ed670
  28be96b80dc1
  cd345198cf12
  29141354a762
  b33fd5ad4c0c
  698970a2480b
  88eace5ce682
  d928b4e8a515
  88714f4125cb
  32b41ca704e1
  01e29e20ea3f
  469c700e9ed8
  790cdfecd168
  e3e6738c56ce
  40553f55397e
  0bab31f71a21
  721ba7c5f4ff
  8b79544bb56d
  dbde319d43a3
  31d7b43cc321
  1f4a19f83a29
  43fc0b77ff07
  82238c0bc950
  c713eae2d31f
  e7135b665740
  c7c1497fc270
  76151e8066e1
  c7d3029bf731
  37ad3ab0cddf
  d6c9e2d27f14
  bfcfd9a61e84
  $ hg showsort 'Cfinal' --limit 4
  01f771406cab
  84d6ec6a8e21
  8ae32c3ed670
  28be96b80dc1
  $ hg debug::stable-tail-info 'Cfinal'
  01f771406cab36b0a9a5dd5f74bacf9596ab1b64
  - rank: 95
  - pow2: 4
  - exclusive-part:
    - parent: 84d6ec6a8e21dac4717999019d29df0054dac0e0
      - rank: 65
      - pow2: 6
      - pidx: p2
    - size: 17
    - splits:
      - head:   84d6ec6a8e21dac4717999019d29df0054dac0e0
        length: 17
  - tail-part:
    - parent: 721ba7c5f4ff4b95fa05d28d6ff3360873a42a9f
      - rank: 77
      - pow2: 6
      - pidx: p1


Test stability of this mess
---------------------------

  $ hg log -r tip
  94 01f771406cab r94 Cfinal tip
  $ show_sort_all > ../crisscross.source.order
  $ cd ..

  $ hg clone crisscross_A crisscross_random --rev 0
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd crisscross_random
  $ for x in `"$PYTHON" "$TESTDIR/testlib/random-revs.py" 50 44`; do
  >   # using python to benefit from the random seed
  >   hg pull -r $x --quiet
  > done;
  $ hg pull --quiet

  $ show_sort_all > ../crisscross.random.order
  $ "$PYTHON" "$RUNTESTDIR/md5sum.py" ../crisscross.*.order
  f36242a27453230f1dc1fa2c7085a145  ../crisscross.random.order
  f36242a27453230f1dc1fa2c7085a145  ../crisscross.source.order
  $ (cmp ../crisscross.*.order || diff -u ../crisscross.*.order)
  $ show_sort_all
  # head 01f771406cab36b0a9a5dd5f74bacf9596ab1b64
  01f771406cab
  84d6ec6a8e21
  8ae32c3ed670
  28be96b80dc1
  cd345198cf12
  29141354a762
  b33fd5ad4c0c
  698970a2480b
  88eace5ce682
  d928b4e8a515
  88714f4125cb
  32b41ca704e1
  01e29e20ea3f
  469c700e9ed8
  790cdfecd168
  e3e6738c56ce
  40553f55397e
  0bab31f71a21
  721ba7c5f4ff
  8b79544bb56d
  dbde319d43a3
  31d7b43cc321
  1f4a19f83a29
  43fc0b77ff07
  82238c0bc950
  c713eae2d31f
  e7135b665740
  c7c1497fc270
  76151e8066e1
  c7d3029bf731
  37ad3ab0cddf
  d6c9e2d27f14
  bfcfd9a61e84
  4f3b41956174
  1da228afcf06
  bf6593f7e073
  3871506da61e
  c84da74cf586
  5eec91b12a58
  0484d39906c8
  041e1188f5f1
  2472d042ec95
  97d19fc5236f
  8ecb28746ec4
  c3c7fa726f88
  d917f77a6439
  b3cf98c3d587
  89a0fe204177
  fac9e582edd1
  e4cfd6264623
  d99e0f7dad5b
  de05b9c29ec7
  9a67238ad1c4
  c37e7cd9f2bd
  0d153e3ad632
  97ac964e34b7
  900dd066a072
  673f5499c8c2
  b115c694654e
  eed373b0090d
  d94da36be176
  4b39f229a0ce
  ad46a4a0fc10
  a457569c5306
  f2bdd828a3aa
  5ce588c2b7c5
  17b6e6bac221
  722d1b8b8942
  47c836a1f13e
  2ea3fbf151b5
  0c3f2ba59eb7
  f3441cd3e664
  b9c3aa92fba5
  3bdb00d5c818
  2bd677d0f13a
  4f5078f7da8a
  884936b34999
  9729470d9329
  3e1560705803
  39bab1cb1cbe
  55bf3fdb634f
  26f59ee8b1d7
  f7c6e7bfbcd0
  3e2da24aee59
  5ba9a53052ed
  07c648efceeb
  c81423bf5a24
  65eb34ffc3a8
  0c1445abb33d
  c8d03c1b5e94
  bebd167eb94d
  2dc09a01254d
  01241442b3c2
  66f7d451a68b
  1ea73414a91b

  $ hg debug::stable-tail-info 'sort(merge(), "node")'
  01e29e20ea3f7ed0d1b3894baffb277f15f110c1
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  01f771406cab36b0a9a5dd5f74bacf9596ab1b64
  - rank: 95
  - pow2: 4
  - exclusive-part:
    - parent: 84d6ec6a8e21dac4717999019d29df0054dac0e0
      - rank: 65
      - pow2: 6
      - pidx: p2
    - size: 17
    - splits:
      - head:   84d6ec6a8e21dac4717999019d29df0054dac0e0
        length: 17
  - tail-part:
    - parent: 721ba7c5f4ff4b95fa05d28d6ff3360873a42a9f
      - rank: 77
      - pow2: 6
      - pidx: p1
  041e1188f5f170496b7d1f46ddb0e566bf2de697
  - rank: 55
  - pow2: 4
  - exclusive-part:
    - parent: 2472d042ec9577662c733295739e360ba18e0bc2
      - rank: 43
      - pow2: 5
      - pidx: p2
    - size: 5
    - splits:
      - head:   2472d042ec9577662c733295739e360ba18e0bc2
        length: 5
  - tail-part:
    - parent: b3cf98c3d5874e655f78ec8e4f47ff788349b3fb
      - rank: 49
      - pow2: 4
      - pidx: p1
  0484d39906c8af29405c38238d7d7541cfd21b27
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
    - size: 2
    - splits:
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  07c648efceebcbbc7e048f8f58dff9fc54b867a7
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p2
  0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 2
    - splits:
      - head:   bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
        length: 2
  - tail-part:
    - parent: 3871506da61ef9862ff9117e2e7255479489d2d5
      - rank: 28
      - pow2: 4
      - pidx: p2
  1da228afcf06af6196afa761de51004d15734b84
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 2
    - splits:
      - head:   bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
        length: 2
  - tail-part:
    - parent: 3871506da61ef9862ff9117e2e7255479489d2d5
      - rank: 28
      - pow2: 4
      - pidx: p2
  1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
  2472d042ec9577662c733295739e360ba18e0bc2
  - rank: 43
  - pow2: 5
  - exclusive-part:
    - parent: 97d19fc5236f8fddc35f1280c19ad2b2103ed619
      - rank: 25
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   97d19fc5236f8fddc35f1280c19ad2b2103ed619
        length: 2
      - head:   c3c7fa726f887f8a24b87244d4dc2389a352fc12
        length: 4
  - tail-part:
    - parent: eed373b0090dceccc6935c146824995087762127
      - rank: 36
      - pow2: 5
      - pidx: p2
  26f59ee8b1d796abfa4071cdef1a96de632ddba8
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 3e2da24aee59e0c496381ae14182dd52344b5742
      - rank: 12
      - pow2: 3
      - pidx: p1
  28be96b80dc1d1af3a682c04b1961d6ed173df1e
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: cd345198cf120276f75c45707c24bb3fe344a7dc
      - rank: 27
      - pow2: 1
      - pidx: p2
    - size: 4
    - splits:
      - head:   cd345198cf120276f75c45707c24bb3fe344a7dc
        length: 2
      - head:   b33fd5ad4c0c086b721ee2457e38c52bb6210763
        length: 2
  - tail-part:
    - parent: 698970a2480b77b03bb3a47ba59934c9d43fdef8
      - rank: 31
      - pow2: 3
      - pidx: p1
  29141354a762bb870a2606de41208700e27eaf53
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  2bd677d0f13ad7ee2d1b04f53b971a3e6b3f25d8
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: 1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   1f4a19f83a298a7c9cb2d3bdaaade5aff735137b
        length: 2
  - tail-part:
    - parent: 43fc0b77ff079900703a20b3cbe3b6645d345582
      - rank: 21
      - pow2: 2
      - pidx: p2
  37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
  - rank: 29
  - pow2: 3
  - exclusive-part:
    - parent: d6c9e2d27f140892757ae56fef23f89916420b8a
      - rank: 21
      - pow2: 4
      - pidx: p2
    - size: 4
    - splits:
      - head:   d6c9e2d27f140892757ae56fef23f89916420b8a
        length: 4
  - tail-part:
    - parent: 4f3b41956174ddc0b5c42448fcbf39c665e23d27
      - rank: 24
      - pow2: 3
      - pidx: p1
  39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
  - rank: 15
  - pow2: 1
  - exclusive-part:
    - parent: 26f59ee8b1d796abfa4071cdef1a96de632ddba8
      - rank: 13
      - pow2: 3
      - pidx: p1
    - size: 1
    - splits:
      - head:   26f59ee8b1d796abfa4071cdef1a96de632ddba8
        length: 1
  - tail-part:
    - parent: f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
      - rank: 13
      - pow2: 3
      - pidx: p2
  3e156070580322eac46974a017d8a19f0e0e107a
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: 39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
      - rank: 15
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   39bab1cb1cbeb1e28b3135fd68ed7b0052f75c52
        length: 1
  - tail-part:
    - parent: 55bf3fdb634f1f8f0b779f1a5e622fa475a2b98c
      - rank: 15
      - pow2: 1
      - pidx: p2
  40553f55397e85f381e3d5813d838b180b707261
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  43fc0b77ff079900703a20b3cbe3b6645d345582
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  469c700e9ed8144bee92d51174ce07fdd2f3510b
  - rank: 37
  - pow2: 5
  - exclusive-part:
    - parent: 790cdfecd168ad7a449cda77ce67c265cd341d57
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 5
    - splits:
      - head:   790cdfecd168ad7a449cda77ce67c265cd341d57
        length: 5
  - tail-part:
    - parent: 0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
      - rank: 31
      - pow2: 2
      - pidx: p2
  4b39f229a0ced1f6ffce4b63e91dd6034d6aa640
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
    - size: 2
    - splits:
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  4f3b41956174ddc0b5c42448fcbf39c665e23d27
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  55bf3fdb634f1f8f0b779f1a5e622fa475a2b98c
  - rank: 15
  - pow2: 1
  - exclusive-part:
    - parent: 26f59ee8b1d796abfa4071cdef1a96de632ddba8
      - rank: 13
      - pow2: 3
      - pidx: p2
    - size: 1
    - splits:
      - head:   26f59ee8b1d796abfa4071cdef1a96de632ddba8
        length: 1
  - tail-part:
    - parent: f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
      - rank: 13
      - pow2: 3
      - pidx: p1
  5ba9a53052edb1e633e32a7e9d55bb52c939eeef
  - rank: 11
  - pow2: 1
  - exclusive-part:
    - parent: 07c648efceebcbbc7e048f8f58dff9fc54b867a7
      - rank: 9
      - pow2: 3
      - pidx: p2
    - size: 1
    - splits:
      - head:   07c648efceebcbbc7e048f8f58dff9fc54b867a7
        length: 1
  - tail-part:
    - parent: c81423bf5a24e28484a591de88cc764941af2c5a
      - rank: 9
      - pow2: 3
      - pidx: p1
  673f5499c8c2e2165142bf8c2765ef494d66cc3e
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p2
  698970a2480b77b03bb3a47ba59934c9d43fdef8
  - rank: 31
  - pow2: 3
  - exclusive-part:
    - parent: 88eace5ce6823d539f94145551ab8a23125df051
      - rank: 23
      - pow2: 4
      - pidx: p2
    - size: 5
    - splits:
      - head:   88eace5ce6823d539f94145551ab8a23125df051
        length: 3
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: 32b41ca704e142a3d62ffd360b72f3a581336e96
      - rank: 25
      - pow2: 4
      - pidx: p1
  721ba7c5f4ff4b95fa05d28d6ff3360873a42a9f
  - rank: 77
  - pow2: 6
  - exclusive-part:
    - parent: 8b79544bb56d6be7ba5e7ac693e9054f20d35af6
      - rank: 48
      - pow2: 5
      - pidx: p2
    - size: 21
    - splits:
      - head:   8b79544bb56d6be7ba5e7ac693e9054f20d35af6
        length: 14
      - head:   4f3b41956174ddc0b5c42448fcbf39c665e23d27
        length: 1
      - head:   1da228afcf06af6196afa761de51004d15734b84
        length: 2
      - head:   3871506da61ef9862ff9117e2e7255479489d2d5
        length: 4
  - tail-part:
    - parent: 041e1188f5f170496b7d1f46ddb0e566bf2de697
      - rank: 55
      - pow2: 4
      - pidx: p1
  76151e8066e129d27b08ab2a62a3cabba87d91c3
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
  790cdfecd168ad7a449cda77ce67c265cd341d57
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: e3e6738c56ced8d1732d824579530511daba8789
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   e3e6738c56ced8d1732d824579530511daba8789
        length: 2
  - tail-part:
    - parent: 40553f55397e85f381e3d5813d838b180b707261
      - rank: 21
      - pow2: 2
      - pidx: p2
  82238c0bc95013ccd9471ed46a28f2f8fc4dd109
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
      - rank: 20
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
        length: 2
  - tail-part:
    - parent: e7135b665740f8de5ee7c6fd2c55b95265c5cbaa
      - rank: 22
      - pow2: 4
      - pidx: p2
  84d6ec6a8e21dac4717999019d29df0054dac0e0
  - rank: 65
  - pow2: 6
  - exclusive-part:
    - parent: 8ae32c3ed67036ef7787649b4dbe2ea844ca633d
      - rank: 48
      - pow2: 4
      - pidx: p1
    - size: 16
    - splits:
      - head:   8ae32c3ed67036ef7787649b4dbe2ea844ca633d
        length: 14
      - head:   40553f55397e85f381e3d5813d838b180b707261
        length: 1
      - head:   0bab31f71a21aea1c9a0a78f9704e6ffe8ae61fd
        length: 1
  - tail-part:
    - parent: 8b79544bb56d6be7ba5e7ac693e9054f20d35af6
      - rank: 48
      - pow2: 5
      - pidx: p2
  88714f4125cbd9202c8017e87a97b2ef9c663ce2
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p1
  89a0fe204177cd77929e08fa7513ec4047453322
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: fac9e582edd1c53906b1b1c8f48d5d612213ac63
      - rank: 23
      - pow2: 4
      - pidx: p1
    - size: 6
    - splits:
      - head:   fac9e582edd1c53906b1b1c8f48d5d612213ac63
        length: 6
  - tail-part:
    - parent: 9a67238ad1c448d3dd52eb183b96890eaca5676e
      - rank: 29
      - pow2: 4
      - pidx: p2
  8ae32c3ed67036ef7787649b4dbe2ea844ca633d
  - rank: 48
  - pow2: 4
  - exclusive-part:
    - parent: 28be96b80dc1d1af3a682c04b1961d6ed173df1e
      - rank: 36
      - pow2: 5
      - pidx: p1
    - size: 10
    - splits:
      - head:   28be96b80dc1d1af3a682c04b1961d6ed173df1e
        length: 4
      - head:   698970a2480b77b03bb3a47ba59934c9d43fdef8
        length: 4
      - head:   32b41ca704e142a3d62ffd360b72f3a581336e96
        length: 2
  - tail-part:
    - parent: 469c700e9ed8144bee92d51174ce07fdd2f3510b
      - rank: 37
      - pow2: 5
      - pidx: p2
  8b79544bb56d6be7ba5e7ac693e9054f20d35af6
  - rank: 48
  - pow2: 5
  - exclusive-part:
    - parent: dbde319d43a36a94df7cfc877fb97fa1b6baaa80
      - rank: 31
      - pow2: 2
      - pidx: p1
    - size: 9
    - splits:
      - head:   dbde319d43a36a94df7cfc877fb97fa1b6baaa80
        length: 4
      - head:   82238c0bc95013ccd9471ed46a28f2f8fc4dd109
        length: 2
      - head:   e7135b665740f8de5ee7c6fd2c55b95265c5cbaa
        length: 3
  - tail-part:
    - parent: c7d3029bf7319c20e0c14fdae8b2e06c701455fb
      - rank: 38
      - pow2: 5
      - pidx: p2
  8ecb28746ec4493774464c23a3f01a18d3cfd172
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  97d19fc5236f8fddc35f1280c19ad2b2103ed619
  - rank: 25
  - pow2: 3
  - exclusive-part:
    - parent: 8ecb28746ec4493774464c23a3f01a18d3cfd172
      - rank: 21
      - pow2: 2
      - pidx: p2
    - size: 3
    - splits:
      - head:   8ecb28746ec4493774464c23a3f01a18d3cfd172
        length: 1
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: c3c7fa726f887f8a24b87244d4dc2389a352fc12
      - rank: 21
      - pow2: 4
      - pidx: p1
  b33fd5ad4c0c086b721ee2457e38c52bb6210763
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  b3cf98c3d5874e655f78ec8e4f47ff788349b3fb
  - rank: 49
  - pow2: 4
  - exclusive-part:
    - parent: 89a0fe204177cd77929e08fa7513ec4047453322
      - rank: 36
      - pow2: 5
      - pidx: p2
    - size: 12
    - splits:
      - head:   89a0fe204177cd77929e08fa7513ec4047453322
        length: 5
      - head:   9a67238ad1c448d3dd52eb183b96890eaca5676e
        length: 7
  - tail-part:
    - parent: eed373b0090dceccc6935c146824995087762127
      - rank: 36
      - pow2: 5
      - pidx: p1
  bf6593f7e073cbe377ef1ec19b87f30b7d77cc00
  - rank: 24
  - pow2: 3
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: ad46a4a0fc10d50de79329c5d5227a355e1e60df
      - rank: 22
      - pow2: 4
      - pidx: p1
  bfcfd9a61e8493d1968cb9cbd83f656ceeb5762a
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p1
  c713eae2d31fc9291cdd7ed1922c68cda7ac95d4
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
  c7d3029bf7319c20e0c14fdae8b2e06c701455fb
  - rank: 38
  - pow2: 5
  - exclusive-part:
    - parent: 37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
      - rank: 29
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   37ad3ab0cddf9f01d48f38e1a26d2a258846e4b6
        length: 4
      - head:   4f3b41956174ddc0b5c42448fcbf39c665e23d27
        length: 2
  - tail-part:
    - parent: 1da228afcf06af6196afa761de51004d15734b84
      - rank: 31
      - pow2: 2
      - pidx: p2
  c81423bf5a24e28484a591de88cc764941af2c5a
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 65eb34ffc3a822669d6a66afdcc2057050439251
      - rank: 5
      - pow2: 2
      - pidx: p2
    - size: 2
    - splits:
      - head:   65eb34ffc3a822669d6a66afdcc2057050439251
        length: 2
  - tail-part:
    - parent: c8d03c1b5e94af74b772900c58259d2e08917735
      - rank: 6
      - pow2: 2
      - pidx: p1
  cd345198cf120276f75c45707c24bb3fe344a7dc
  - rank: 27
  - pow2: 1
  - exclusive-part:
    - parent: 29141354a762bb870a2606de41208700e27eaf53
      - rank: 24
      - pow2: 3
      - pidx: p2
    - size: 2
    - splits:
      - head:   29141354a762bb870a2606de41208700e27eaf53
        length: 2
  - tail-part:
    - parent: b33fd5ad4c0c086b721ee2457e38c52bb6210763
      - rank: 24
      - pow2: 3
      - pidx: p1
  d917f77a643960caa231e26b47a57edea5410d00
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: b115c694654ecc0ae9dbf84523309bcbdf882307
      - rank: 18
      - pow2: 4
      - pidx: p2
    - size: 1
    - splits:
      - head:   b115c694654ecc0ae9dbf84523309bcbdf882307
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
  d99e0f7dad5be63dea245790377dfd63c094e9f0
  - rank: 21
  - pow2: 2
  - exclusive-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
        length: 1
  - tail-part:
    - parent: 884936b34999687314cc009cba0dd88098bb5057
      - rank: 19
      - pow2: 4
      - pidx: p2
  dbde319d43a36a94df7cfc877fb97fa1b6baaa80
  - rank: 31
  - pow2: 2
  - exclusive-part:
    - parent: 31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
      - rank: 24
      - pow2: 3
      - pidx: p1
    - size: 5
    - splits:
      - head:   31d7b43cc321f64e56f1d7afb1e3a68b33c153ef
        length: 2
      - head:   43fc0b77ff079900703a20b3cbe3b6645d345582
        length: 1
      - head:   884936b34999687314cc009cba0dd88098bb5057
        length: 2
  - tail-part:
    - parent: 82238c0bc95013ccd9471ed46a28f2f8fc4dd109
      - rank: 25
      - pow2: 3
      - pidx: p2
  e3e6738c56ced8d1732d824579530511daba8789
  - rank: 20
  - pow2: 2
  - exclusive-part:
    - parent: 4f5078f7da8a803a00a633b0243fa335c4e74ad6
      - rank: 18
      - pow2: 4
      - pidx: p1
    - size: 1
    - splits:
      - head:   4f5078f7da8a803a00a633b0243fa335c4e74ad6
        length: 1
  - tail-part:
    - parent: de05b9c29ec79931c2e9af9e3c3c5477e7be1d84
      - rank: 18
      - pow2: 4
      - pidx: p2
  eed373b0090dceccc6935c146824995087762127
  - rank: 36
  - pow2: 5
  - exclusive-part:
    - parent: d94da36be176bdbf1a3755708ee6fbde5a53e0b2
      - rank: 26
      - pow2: 4
      - pidx: p2
    - size: 7
    - splits:
      - head:   d94da36be176bdbf1a3755708ee6fbde5a53e0b2
        length: 2
      - head:   ad46a4a0fc10d50de79329c5d5227a355e1e60df
        length: 5
  - tail-part:
    - parent: 722d1b8b8942f62840c7ffcdd273cd579dd7012d
      - rank: 28
      - pow2: 4
      - pidx: p1
  f7c6e7bfbcd0c7eab2106d044966c3df66e29b1d
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 3e2da24aee59e0c496381ae14182dd52344b5742
      - rank: 12
      - pow2: 3
      - pidx: p2
