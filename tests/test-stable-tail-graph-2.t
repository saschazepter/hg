=========================================================================
Check that we can compute and exchange rank and stable tail sort properly
=========================================================================

#testcases real naive

#if naive
  $ cat << EOF >> $HGRCPATH
  > [defaults]
  > debug::stable-tail-sort=--naive
  > EOF
#endif

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=enable-unstable-format-and-corrupt-my-data
  > EOF


Test minimal rank computation with merge
========================================

  $ hg init rank-repo-minimal
  $ cd rank-repo-minimal
  $ touch 0
  $ hg commit -Aqm 0
  $ touch 1
  $ hg commit -Aqm 1
  $ hg update -qr 0
  $ touch 2
  $ hg commit -Aqm 2
  $ hg merge -qr 1
  $ hg commit -m 3
  $ touch 4
  $ hg commit -Aqm 4
  $ hg log --graph --template '{rev} {_fast_rank}\n'
  @  4 5
  |
  o    3 4
  |\
  | o  2 2
  | |
  o |  1 2
  |/
  o  0 1
  

  $ hg debug::stable-tail-sort 'max(all())'
  4
  3
  2
  1
  0

  $ cd ..

Test behavior around "criss cross" merges
=========================================

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
  $ hg log -G -T '{rev}:{node|short} {p1} {p2} {tags} {desc} rank: {_fast_rank}\n'
  o    94:01f771406cab 92:721ba7c5f4ff 93:84d6ec6a8e21 Cfinal tip r94 rank: 95
  |\
  | o    93:84d6ec6a8e21 91:8ae32c3ed670 90:8b79544bb56d CmergeZB r93 rank: 65
  | |\
  o | |  92:721ba7c5f4ff 89:041e1188f5f1 90:8b79544bb56d CmergeZA r92 rank: 77
  |\| |
  | | o    91:8ae32c3ed670 85:28be96b80dc1 86:469c700e9ed8 CmergeYC r91 rank: 48
  | | |\
  | o \ \    90:8b79544bb56d 84:dbde319d43a3 87:c7d3029bf731 CmergeYB r90 rank: 48
  | |\ \ \
  o \ \ \ \    89:041e1188f5f1 83:b3cf98c3d587 88:2472d042ec95 CmergeYA r89 rank: 55
  |\ \ \ \ \
  | o \ \ \ \    88:2472d042ec95 77:97d19fc5236f 72:eed373b0090d CmergeXF r88 rank: 43
  | |\ \ \ \ \
  | | | | o \ \    87:c7d3029bf731 76:37ad3ab0cddf 82:1da228afcf06 CmergeXE r87 rank: 38
  | | | | |\ \ \
  | | | | | | | o    86:469c700e9ed8 75:790cdfecd168 81:0bab31f71a21 CmergeXD r86 rank: 37
  | | | | | | | |\
  | | | | | | o \ \    85:28be96b80dc1 74:698970a2480b 80:cd345198cf12 CmergeXC r85 rank: 36
  | | | | | | |\ \ \
  | | | o \ \ \ \ \ \    84:dbde319d43a3 73:31d7b43cc321 79:82238c0bc950 CmergeXB r84 rank: 31
  | | | |\ \ \ \ \ \ \
  o | | | | | | | | | |  83:b3cf98c3d587 72:eed373b0090d 78:89a0fe204177 CmergeXA r83 rank: 49
  |\| | | | | | | | | |
  | | | | | | o | | | |    82:1da228afcf06 63:bf6593f7e073 62:3871506da61e CmergeWK r82 rank: 31
  | | | | | | |\ \ \ \ \
  | | | | | | +-+-------o  81:0bab31f71a21 63:bf6593f7e073 62:3871506da61e CmergeWJ r81 rank: 31
  | | | | | | | | | | |
  | | | | | | | | | o |    80:cd345198cf12 64:b33fd5ad4c0c 58:29141354a762 CmergeWI r80 rank: 27
  | | | | | | | | | |\ \
  | | | | o \ \ \ \ \ \ \    79:82238c0bc950 65:c713eae2d31f 57:e7135b665740 CmergeWH r79 rank: 25
  | | | | |\ \ \ \ \ \ \ \
  o \ \ \ \ \ \ \ \ \ \ \ \    78:89a0fe204177 68:fac9e582edd1 54:9a67238ad1c4 CmergeWG r78 rank: 36
  |\ \ \ \ \ \ \ \ \ \ \ \ \
  | | | o \ \ \ \ \ \ \ \ \ \    77:97d19fc5236f 70:c3c7fa726f88 48:8ecb28746ec4 CmergeWF r77 rank: 25
  | | | |\ \ \ \ \ \ \ \ \ \ \
  | | | | | | | | o \ \ \ \ \ \    76:37ad3ab0cddf 71:4f3b41956174 47:d6c9e2d27f14 CmergeWE r76 rank: 29
  | | | | | | | | |\ \ \ \ \ \ \
  | | | | | | | | | | | | | | | o    75:790cdfecd168 38:e3e6738c56ce 45:40553f55397e CmergeWD r75 rank: 24
  | | | | | | | | | | | | | | | |\
  | | | | | | | | | | | | o \ \ \ \    74:698970a2480b 37:32b41ca704e1 41:88eace5ce682 CmergeWC r74 rank: 31
  | | | | | | | | | | | | |\ \ \ \ \
  | | | | | o \ \ \ \ \ \ \ \ \ \ \ \    73:31d7b43cc321 35:1f4a19f83a29 42:43fc0b77ff07 CmergeWB r73 rank: 24
  | | | | | |\ \ \ \ \ \ \ \ \ \ \ \ \
  | | o \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \    72:eed373b0090d 34:722d1b8b8942 44:d94da36be176 CmergeWA r72 rank: 36
  | | |\ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \
  | | | | | | | | | | | o \ \ \ \ \ \ \ \    71:4f3b41956174 26:de05b9c29ec7 25:ad46a4a0fc10 CmergeT r71 rank: 24
  | | | | | | | | | | | |\ \ \ \ \ \ \ \ \
  | | | | | o | | | | | | | | | | | | | | |  70:c3c7fa726f88 69:d917f77a6439 -1:000000000000 CmergeS r70 rank: 21
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | o-------------+ | | | | | | | |  69:d917f77a6439 26:de05b9c29ec7 20:b115c694654e  r69 rank: 20
  | | | | | | | | | | | | | | | | | | | | |
  | o | | | | | | | | | | | | | | | | | | |  68:fac9e582edd1 67:e4cfd6264623 -1:000000000000 CmergeR r68 rank: 23
  | | | | | | | | | | | | | | | | | | | | |
  | o | | | | | | | | | | | | | | | | | | |  67:e4cfd6264623 66:d99e0f7dad5b -1:000000000000  r67 rank: 22
  | | | | | | | | | | | | | | | | | | | | |
  | o---------------------+ | | | | | | | |  66:d99e0f7dad5b 26:de05b9c29ec7 19:884936b34999  r66 rank: 21
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | o-----+ | | | | | | | |  65:c713eae2d31f 26:de05b9c29ec7 17:4f5078f7da8a CmergeQ r65 rank: 20
  | | | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | +-+-----------o | |  64:b33fd5ad4c0c 25:ad46a4a0fc10 26:de05b9c29ec7 CmergeP r64 rank: 24
  | | | | | | | | | | | | | | | | | |  / /
  | | | | | +-----------+-----o | | | / /  63:bf6593f7e073 25:ad46a4a0fc10 20:b115c694654e CmergeO r63 rank: 24
  | | | | | | | | | | | | | |  / / / / /
  | | | | | | | | | | | | | o | | | | |  62:3871506da61e 61:c84da74cf586 -1:000000000000 CmergeN r62 rank: 28
  | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | | | o | | | | |  61:c84da74cf586 60:5eec91b12a58 -1:000000000000  r61 rank: 27
  | | | | | | | | | | | | | | | | | | |
  | | | | | | | | | | | | | o | | | | |  60:5eec91b12a58 59:0484d39906c8 -1:000000000000  r60 rank: 26
  | | | | | | | | | | | | | | | | | | |
  | +-------------------+---o | | | | |  59:0484d39906c8 25:ad46a4a0fc10 19:884936b34999  r59 rank: 25
  | | | | | | | | | | | | |  / / / / /
  | | | | | | | | | +---+-------o / /  58:29141354a762 25:ad46a4a0fc10 17:4f5078f7da8a CmergeM r58 rank: 24
  | | | | | | | | | | | | | | |  / /
  | | | | | | | | o | | | | | | | |  57:e7135b665740 56:c7c1497fc270 -1:000000000000 CmergeL r57 rank: 22
  | | | | | | | | | | | | | | | | |
  | | | | | | | | o | | | | | | | |  56:c7c1497fc270 55:76151e8066e1 -1:000000000000  r56 rank: 21
  | | | | | | | | | | | | | | | | |
  | | | | | +-----o-------+ | | | |  55:76151e8066e1 20:b115c694654e 26:de05b9c29ec7  r55 rank: 20
  | | | | | | | |  / / / / / / / /
  o | | | | | | | | | | | | | | |  54:9a67238ad1c4 53:c37e7cd9f2bd -1:000000000000 CmergeK r54 rank: 29
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  53:c37e7cd9f2bd 52:0d153e3ad632 -1:000000000000  r53 rank: 28
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  52:0d153e3ad632 51:97ac964e34b7 -1:000000000000  r52 rank: 27
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  51:97ac964e34b7 50:900dd066a072 -1:000000000000  r51 rank: 26
  | | | | | | | | | | | | | | | |
  o | | | | | | | | | | | | | | |  50:900dd066a072 49:673f5499c8c2 -1:000000000000  r50 rank: 25
  | | | | | | | | | | | | | | | |
  o---------+---------+ | | | | |  49:673f5499c8c2 20:b115c694654e 25:ad46a4a0fc10  r49 rank: 24
   / / / / / / / / / / / / / / /
  +-----o / / / / / / / / / / /  48:8ecb28746ec4 20:b115c694654e 19:884936b34999 CmergeJ r48 rank: 21
  | | | |/ / / / / / / / / / /
  | | | | | | | o | | | | | |  47:d6c9e2d27f14 46:bfcfd9a61e84 -1:000000000000 CmergeI r47 rank: 21
  | | | | | | | | | | | | | |
  | | | +-------o | | | | | |  46:bfcfd9a61e84 20:b115c694654e 17:4f5078f7da8a  r46 rank: 20
  | | | | | | |/ / / / / / /
  +---------------+-------o  45:40553f55397e 19:884936b34999 26:de05b9c29ec7 CmergeH r45 rank: 21
  | | | | | | | | | | | |
  | | o | | | | | | | | |  44:d94da36be176 43:4b39f229a0ce -1:000000000000 CmergeG r44 rank: 26
  | | | | | | | | | | | |
  +---o---------+ | | | |  43:4b39f229a0ce 19:884936b34999 25:ad46a4a0fc10  r43 rank: 25
  | |  / / / / / / / / /
  +---+---o / / / / / /  42:43fc0b77ff07 19:884936b34999 20:b115c694654e CmergeF r42 rank: 21
  | | | |  / / / / / /
  | | | | | | | | o |  41:88eace5ce682 40:d928b4e8a515 -1:000000000000 CmergeE r41 rank: 23
  | | | | | | | | | |
  | | | | | | | | o |  40:d928b4e8a515 39:88714f4125cb -1:000000000000  r40 rank: 22
  | | | | | | | | | |
  +-------+-------o |  39:88714f4125cb 19:884936b34999 17:4f5078f7da8a  r39 rank: 21
  | | | | | | | |  /
  | | | | +---+---o  38:e3e6738c56ce 17:4f5078f7da8a 26:de05b9c29ec7 CmergeD r38 rank: 20
  | | | | | | | |
  | | | | | | | o  37:32b41ca704e1 36:01e29e20ea3f -1:000000000000 CmergeC r37 rank: 25
  | | | | | | | |
  | | | | +-+---o  36:01e29e20ea3f 17:4f5078f7da8a 25:ad46a4a0fc10  r36 rank: 24
  | | | | | | |
  | | | o | | |  35:1f4a19f83a29 17:4f5078f7da8a 20:b115c694654e CmergeB r35 rank: 20
  | | |/|/ / /
  | o | | | |  34:722d1b8b8942 33:47c836a1f13e -1:000000000000 CmergeA r34 rank: 28
  | | | | | |
  | o | | | |  33:47c836a1f13e 32:2ea3fbf151b5 -1:000000000000  r33 rank: 27
  | | | | | |
  | o | | | |  32:2ea3fbf151b5 31:0c3f2ba59eb7 -1:000000000000  r32 rank: 26
  | | | | | |
  | o | | | |  31:0c3f2ba59eb7 30:f3441cd3e664 -1:000000000000  r31 rank: 25
  | | | | | |
  | o | | | |  30:f3441cd3e664 29:b9c3aa92fba5 -1:000000000000  r30 rank: 24
  | | | | | |
  | o | | | |  29:b9c3aa92fba5 28:3bdb00d5c818 -1:000000000000  r29 rank: 23
  | | | | | |
  | o | | | |  28:3bdb00d5c818 27:2bd677d0f13a -1:000000000000  r28 rank: 22
  | | | | | |
  | o---+ | |  27:2bd677d0f13a 17:4f5078f7da8a 19:884936b34999  r27 rank: 21
  |/ / / / /
  | | | | o  26:de05b9c29ec7 16:3e1560705803 -1:000000000000 CbaseE r26 rank: 18
  | | | | |
  | | | o |  25:ad46a4a0fc10 24:a457569c5306 -1:000000000000 CbaseD r25 rank: 22
  | | | | |
  | | | o |  24:a457569c5306 23:f2bdd828a3aa -1:000000000000  r24 rank: 21
  | | | | |
  | | | o |  23:f2bdd828a3aa 22:5ce588c2b7c5 -1:000000000000  r23 rank: 20
  | | | | |
  | | | o |  22:5ce588c2b7c5 21:17b6e6bac221 -1:000000000000  r22 rank: 19
  | | | | |
  | | | o |  21:17b6e6bac221 16:3e1560705803 -1:000000000000  r21 rank: 18
  | | | |/
  | o---+  20:b115c694654e 16:3e1560705803 -1:000000000000 CbaseC r20 rank: 18
  |  / /
  o | |  19:884936b34999 18:9729470d9329 -1:000000000000 CbaseB r19 rank: 19
  | | |
  o---+  18:9729470d9329 16:3e1560705803 -1:000000000000  r18 rank: 18
   / /
  o /  17:4f5078f7da8a 16:3e1560705803 -1:000000000000 CbaseA r17 rank: 18
  |/
  o    16:3e1560705803 14:39bab1cb1cbe 15:55bf3fdb634f Bfinal r16 rank: 17
  |\
  | o    15:55bf3fdb634f 13:f7c6e7bfbcd0 12:26f59ee8b1d7 BmergeD r15 rank: 15
  | |\
  o---+  14:39bab1cb1cbe 12:26f59ee8b1d7 13:f7c6e7bfbcd0 BmergeC r14 rank: 15
  |/ /
  | o    13:f7c6e7bfbcd0 9:07c648efceeb 11:3e2da24aee59 BmergeB r13 rank: 13
  | |\
  o---+  12:26f59ee8b1d7 11:3e2da24aee59 9:07c648efceeb BmergeA r12 rank: 13
  |/ /
  | o  11:3e2da24aee59 10:5ba9a53052ed -1:000000000000 BbaseA r11 rank: 12
  | |
  | o  10:5ba9a53052ed 8:c81423bf5a24 9:07c648efceeb Afinal r10 rank: 11
  |/|
  o |    9:07c648efceeb 7:65eb34ffc3a8 5:c8d03c1b5e94 AmergeB BbaseB r9 rank: 9
  |\ \
  +---o  8:c81423bf5a24 5:c8d03c1b5e94 7:65eb34ffc3a8 AmergeA r8 rank: 9
  | |/
  | o  7:65eb34ffc3a8 6:0c1445abb33d -1:000000000000 AbaseB r7 rank: 5
  | |
  | o  6:0c1445abb33d 2:01241442b3c2 -1:000000000000  r6 rank: 4
  | |
  o |  5:c8d03c1b5e94 4:bebd167eb94d -1:000000000000 AbaseA r5 rank: 6
  | |
  o |  4:bebd167eb94d 3:2dc09a01254d -1:000000000000  r4 rank: 5
  | |
  o |  3:2dc09a01254d 2:01241442b3c2 -1:000000000000  r3 rank: 4
  |/
  o  2:01241442b3c2 1:66f7d451a68b -1:000000000000 base r2 rank: 3
  |
  o  1:66f7d451a68b 0:1ea73414a91b -1:000000000000  r1 rank: 2
  |
  o  0:1ea73414a91b -1:000000000000 -1:000000000000  r0 rank: 1
  
  $ hg debug::stable-tail-sort 'max(all())'
  94
  93
  91
  85
  80
  58
  64
  74
  41
  40
  39
  37
  36
  86
  75
  38
  45
  81
  92
  90
  84
  73
  35
  42
  79
  65
  57
  56
  55
  87
  76
  47
  46
  71
  82
  63
  62
  61
  60
  59
  89
  88
  77
  48
  70
  69
  83
  78
  68
  67
  66
  26
  54
  53
  52
  51
  50
  49
  20
  72
  44
  43
  25
  24
  23
  22
  21
  34
  33
  32
  31
  30
  29
  28
  27
  17
  19
  18
  16
  14
  15
  12
  13
  11
  10
  9
  8
  7
  6
  5
  4
  3
  2
  1
  0

  $ cd ..

Build a bigger example repo
===========================

  $ hg init rank-repo-generated
  $ cd rank-repo-generated
  $ hg debugbuilddag '.:root1+5:mp1<root1+10:mp2/mp1+3<mp1+2:mp3/mp2$+15/mp1+4'
  $ hg log -G -T '{desc}'
  o  r42
  |
  o  r41
  |
  o  r40
  |
  o  r39
  |
  o    r38
  |\
  | o  r37
  | |
  | o  r36
  | |
  | o  r35
  | |
  | o  r34
  | |
  | o  r33
  | |
  | o  r32
  | |
  | o  r31
  | |
  | o  r30
  | |
  | o  r29
  | |
  | o  r28
  | |
  | o  r27
  | |
  | o  r26
  | |
  | o  r25
  | |
  | o  r24
  | |
  | o  r23
  |
  | o    r22
  | |\
  | | o  r21
  | | |
  +---o  r20
  | |
  | | o  r19
  | | |
  | | o  r18
  | | |
  | | o  r17
  | | |
  +---o  r16
  | |/
  | o  r15
  | |
  | o  r14
  | |
  | o  r13
  | |
  | o  r12
  | |
  | o  r11
  | |
  | o  r10
  | |
  | o  r9
  | |
  | o  r8
  | |
  | o  r7
  | |
  | o  r6
  | |
  o |  r5
  | |
  o |  r4
  | |
  o |  r3
  | |
  o |  r2
  | |
  o |  r1
  |/
  o  r0
  


Check the rank
--------------

  $ hg log -G -T '{_fast_rank}'
  o  26
  |
  o  25
  |
  o  24
  |
  o  23
  |
  o    22
  |\
  | o  15
  | |
  | o  14
  | |
  | o  13
  | |
  | o  12
  | |
  | o  11
  | |
  | o  10
  | |
  | o  9
  | |
  | o  8
  | |
  | o  7
  | |
  | o  6
  | |
  | o  5
  | |
  | o  4
  | |
  | o  3
  | |
  | o  2
  | |
  | o  1
  |
  | o    19
  | |\
  | | o  8
  | | |
  +---o  7
  | |
  | | o  20
  | | |
  | | o  19
  | | |
  | | o  18
  | | |
  +---o  17
  | |/
  | o  11
  | |
  | o  10
  | |
  | o  9
  | |
  | o  8
  | |
  | o  7
  | |
  | o  6
  | |
  | o  5
  | |
  | o  4
  | |
  | o  3
  | |
  | o  2
  | |
  o |  6
  | |
  o |  5
  | |
  o |  4
  | |
  o |  3
  | |
  o |  2
  |/
  o  1
  

Check the stable tail sorting
-----------------------------

  $ hg debug::stable-tail-sort 'max(all())'
  42
  41
  40
  39
  38
  5
  4
  3
  2
  1
  0
  37
  36
  35
  34
  33
  32
  31
  30
  29
  28
  27
  26
  25
  24
  23
