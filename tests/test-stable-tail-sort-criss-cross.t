Test for stable ordering capabilities
=====================================

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
  

  $ hg debugrank -r 'all()'
  1ea73414a91b 1
  66f7d451a68b 2
  01241442b3c2 3
  2dc09a01254d 4
  bebd167eb94d 5
  c8d03c1b5e94 6
  0c1445abb33d 4
  65eb34ffc3a8 5
  c81423bf5a24 9
  07c648efceeb 9
  5ba9a53052ed 11
  3e2da24aee59 12
  26f59ee8b1d7 13
  f7c6e7bfbcd0 13
  39bab1cb1cbe 15
  55bf3fdb634f 15
  3e1560705803 17
  4f5078f7da8a 18
  9729470d9329 18
  884936b34999 19
  b115c694654e 18
  17b6e6bac221 18
  5ce588c2b7c5 19
  f2bdd828a3aa 20
  a457569c5306 21
  ad46a4a0fc10 22
  de05b9c29ec7 18
  2bd677d0f13a 21
  3bdb00d5c818 22
  b9c3aa92fba5 23
  f3441cd3e664 24
  0c3f2ba59eb7 25
  2ea3fbf151b5 26
  47c836a1f13e 27
  722d1b8b8942 28
  1f4a19f83a29 20
  01e29e20ea3f 24
  32b41ca704e1 25
  e3e6738c56ce 20
  88714f4125cb 21
  d928b4e8a515 22
  88eace5ce682 23
  43fc0b77ff07 21
  4b39f229a0ce 25
  d94da36be176 26
  40553f55397e 21
  bfcfd9a61e84 20
  d6c9e2d27f14 21
  8ecb28746ec4 21
  673f5499c8c2 24
  900dd066a072 25
  97ac964e34b7 26
  0d153e3ad632 27
  c37e7cd9f2bd 28
  9a67238ad1c4 29
  76151e8066e1 20
  c7c1497fc270 21
  e7135b665740 22
  29141354a762 24
  0484d39906c8 25
  5eec91b12a58 26
  c84da74cf586 27
  3871506da61e 28
  bf6593f7e073 24
  b33fd5ad4c0c 24
  c713eae2d31f 20
  d99e0f7dad5b 21
  e4cfd6264623 22
  fac9e582edd1 23
  d917f77a6439 20
  c3c7fa726f88 21
  4f3b41956174 24
  eed373b0090d 36
  31d7b43cc321 24
  698970a2480b 31
  790cdfecd168 24
  37ad3ab0cddf 29
  97d19fc5236f 25
  89a0fe204177 36
  82238c0bc950 25
  cd345198cf12 27
  0bab31f71a21 31
  1da228afcf06 31
  b3cf98c3d587 49
  dbde319d43a3 31
  28be96b80dc1 36
  469c700e9ed8 37
  c7d3029bf731 38
  2472d042ec95 43
  041e1188f5f1 55
  8b79544bb56d 48
  8ae32c3ed670 48
  721ba7c5f4ff 77
  84d6ec6a8e21 65
  01f771406cab 95

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
