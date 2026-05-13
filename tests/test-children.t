#testcases revlogv1 changelogv2

=========================
test children computation
=========================

The revlogv1 case check old school computation

The changelogv2 case check the tracking of children in the index



  $ cat << EOF >> $HGRCPATH
  > [format]
  > revlog-compression=none
  > EOF

#if changelogv2

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=enable-unstable-format-and-corrupt-my-data
  > EOF

#endif

#if revlogv1

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=no
  > EOF

#endif


init
  $ hg init t
  $ cd t

no working directory
  $ hg log -r 'children(.)'

setup

  $ hg debugbuilddag ".+2:f+1<4+3/f<f+3$+2<2/8"


resulting graph

  $ hg log -G -T '{rev}\n'
  o    13
  |\
  | | o  12
  | |/
  | o  11
  |
  | o  10
  | |
  | o  9
  | |
  | o  8
  | |
  | | o  7
  | |/|
  +---o  6
  | |
  o |  5
  | |
  o |  4
  | |
  | | o  3
  | |/
  | o  2
  | |
  | o  1
  |/
  o  0
  

#if changelogv2

  $ hg debugindex -v -c
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size   child-p1   child-p2 sibling-p1 sibling-p2
       0      1       0 1ea73414a91b     -1 000000000000     -1 000000000000                   62          0     0         0                    0         62        plain                    0             0                    0                  0          1         -1         -1         -1
       1      2       1 66f7d451a68b      0 1ea73414a91b     -1 000000000000                   62          1     0         0                   62         62        plain                    0             0                    0                  0          2         -1          4         -1
       2      3       2 01241442b3c2      1 66f7d451a68b     -1 000000000000                   62          2     0         0                  124         62        plain                    0             0                    0                  0          3          7         -1         -1
       3      4       3 2dc09a01254d      2 01241442b3c2     -1 000000000000                   62          3     0         0                  186         62        plain                    0             0                    0                  0         -1         -1          8         -1
       4      2       4 e7bd5218ca15      0 1ea73414a91b     -1 000000000000                   62          4     0         0                  248         62        plain                    0             0                    0                  0          5         -1         -1         -1
       5      3       5 3a367db1fabc      4 e7bd5218ca15     -1 000000000000                   62          5     0         0                  310         62        plain                    0             0                    0                  0          6         13         -1         -1
       6      4       6 a2f58e9c1e56      5 3a367db1fabc     -1 000000000000                   62          6     0         0                  372         62        plain                    0             0                    0                  0          7         -1         -1         -1
       7      7       7 0b5c7eb4d8af      6 a2f58e9c1e56      2 01241442b3c2                   62          7     0         0                  434         62        plain                    0             0                    0                  0         -1         -1         -1         -1
       8      4       8 f27daae5831e      2 01241442b3c2     -1 000000000000                   62          8     0         0                  496         62        plain                    0             0                    0                  0          9         -1         -1         -1
       9      5       9 eeb3ffa95e25      8 f27daae5831e     -1 000000000000                   62          9     0         0                  558         62        plain                    0             0                    0                  0         10         -1         -1         -1
      10      6      10 6b5bd497916c      9 eeb3ffa95e25     -1 000000000000                   64         10     0         0                  620         64        plain                    0             0                    0                  0         -1         -1         -1         -1
      11      1      11 68b2f8864486     -1 000000000000     -1 000000000000                   64         11     0         0                  684         64        plain                    0             0                    0                  0         12         -1         -1         -1
      12      2      12 c5e1c0035018     11 68b2f8864486     -1 000000000000                   64         12     0         0                  748         64        plain                    0             0                    0                  0         -1         -1         13         -1
      13      5      13 f537e7bd1a5f     11 68b2f8864486      5 3a367db1fabc                   64         13     0         0                  812         64        plain                    0             0                    0                  0         -1         -1         -1         -1

#endif


children listing

  $ for i in null `hg log -r 'all()' -T '{rev} '`; do
  > echo "### children of '$i'"
  > hg log -r "children($i)" -T '{rev}\n'
  > done
  ### children of 'null'
  0
  11
  ### children of '0'
  1
  4
  ### children of '1'
  2
  ### children of '2'
  3
  7
  8
  ### children of '3'
  ### children of '4'
  5
  ### children of '5'
  6
  13
  ### children of '6'
  7
  ### children of '7'
  ### children of '8'
  9
  ### children of '9'
  10
  ### children of '10'
  ### children of '11'
  12
  13
  ### children of '12'
  ### children of '13'
  $ cd ..
