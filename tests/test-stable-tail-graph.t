====================================
Test for the stabletailgraph package
====================================

This test file contains a bunch of small test graphs with some minimal yet
non-trivial structure, on which the various stable-tail graph and stable-tail
sort functions are tested.

Each case consists of the creation of the interesting graph structure, followed
by a check, for each noteworthy node, of:
- the stable-tail sort output (with the linear parts globbed),
- the leap set,
- the specific leap set.

In the ASCII art of the diagrams, the side of the exclusive part which is
followed in priority is denoted with "<" or ">" if it is on the left or right
respectively.

The intermediary linear parts in the example graph are there to force the
exclusive part choice (made on a min rank condition).

#testcases real naive

#if naive
  $ cat << EOF >> $HGRCPATH
  > [defaults]
  > debug::stable-tail-sort=--naive
  > EOF
#endif


Setup
=====

Enable the rank computation to test sorting based on the rank.

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=enable-unstable-format-and-corrupt-my-data
  > 
  > [alias]
  > test-sts = debug::stable-tail-sort -T '{if(tags, "{tags},")}'
  > test-splits = debug::stable-tail-sort-excl-splits -T '{tags}'
  > test-log = log --graph -T '{tags} rank={_fast_rank}' --rev 'tagged()'
  > EOF


Example 1: single merge node
============================

A base case with one branchpoint "b" and one merge node "e".

The exclusive part, starting with the lowest-ranking parent "c" of "e",
appears first in stable-tail sort of "e" and "f".

#        f
#        |
#        e
#        |
#      --<--
#      |   |
#      c   d
#      |   |
#      --+--      <- at this point, the sort of "e" is done consuming its
#        |           exclusive part [c] and jumps back to its other parent "d"
#        b
#        |
#        a

  $ hg init example-1
  $ cd example-1
  $ hg debugbuilddag '.:a*a:b*b:c<b+2:d*c/d:e*e:f.'
  $ hg test-log
  o  f rank=7
  |
  o    e rank=6
  |\
  | o  d rank=4
  | :
  o :  c rank=3
  :/
  o  b rank=2
  |
  o  a rank=1
  

Check the sort of the base linear case.

  $ hg test-sts c
  c,b,a, (no-eol)

Check the stable-tail sort of "e": "c" should come before "d".

  $ hg test-sts e
  e,c,d,b,a, (no-eol)

Check that the linear descendant of the merge inherits its sort properly.

  $ hg test-sts f
  f,e,c,d,b,a, (no-eol)

Check the leaps of "e": arriving at "c", the sort continues at "d", which
which breaks the child-parent chain and results in a leap.

  $ hg test-splits e
  c length: 1


Check that this leap is inherited by its direct ancestor "f".

  $ hg test-splits f

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  eda60bcb1a4164115a0f525ff7a81e0d87bbd730
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  87702a37554db29dc516c095781073ce3cb1ed55
  - rank: 6
  - pow2: 2
  - exclusive-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   01241442b3c2bf3211e593b549c655ea65b295e3
        length: 1
  - tail-part:
    - parent: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank: 4
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank:   4
      - pow2:   2
    - size:     2
    - min-rank: 3
  92cc02877558195870002dc5233e7a5a589e50ff
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: 87702a37554db29dc516c095781073ce3cb1ed55
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 87702a37554db29dc516c095781073ce3cb1ed55
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  b3229d0f7d46405c2cbde780dd023333d52a04bc
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: 92cc02877558195870002dc5233e7a5a589e50ff
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1

  $ cd ..


Example 2: nested exclusive parts, without specific leap
========================================================

"g" is a merge node whose exclusive part contains a merge node "e".
We check that the stable-tail sort recurses properly by delegating.

Notice that parts of the sort of "e" is an infix of the sort of "g".
This is an expected property of the sort.

#           g
#           |
#        ---<---
#        |     |
#        e     |    <- while processing the sort in the exclusive part of "g"
#        |     |       we recursively process the exclusive part of "e"
#      --<--   f
#      |   |   |
#      c   d   |
#      |   |   |
#      --+--   |
#        |     |
#        b     |
#        |     |
#        ---+---    <- done with excl(g), jump to "f"
#           |
#           a

  $ hg init example-2
  $ cd example-2
  $ hg debugbuilddag '.:a*a:b*b:c<b+2:d*c/d:e<a+6:f*e/f:g.'
  $ hg test-log
  o    g rank=13
  |\
  | o  f rank=7
  | :
  o :    e rank=6
  |\ \
  | o :  d rank=4
  | : :
  o : :  c rank=3
  :/ /
  o /  b rank=2
  :/
  o  a rank=1
  
Display the sort of "e" for reference

  $ hg test-sts e
  e,c,d,b,a, (no-eol)

Check the correctness of the sort of "g",
and that a part of the sort of "e" appears as an infix.

  $ hg test-sts g
  g,e,c,d,b,f,a, (no-eol)

Check the leaps of "e".

  $ hg test-splits e
  c length: 1


Check that "g" inherits a leap from "e" in addition of its own.

  $ hg test-splits g
  e length: 5

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  eda60bcb1a4164115a0f525ff7a81e0d87bbd730
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  87702a37554db29dc516c095781073ce3cb1ed55
  - rank: 6
  - pow2: 2
  - exclusive-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   01241442b3c2bf3211e593b549c655ea65b295e3
        length: 1
  - tail-part:
    - parent: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank: 4
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank:   4
      - pow2:   2
    - size:     2
    - min-rank: 3
  c62a56df2f57b8adb3e2fea07bafc041cdcffcca
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  cebb58bd334c81afbf99748e000575ba1cbad129
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: c62a56df2f57b8adb3e2fea07bafc041cdcffcca
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: c62a56df2f57b8adb3e2fea07bafc041cdcffcca
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  951f5a448914ae8b2c631f45d9ceff8766e13397
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: cebb58bd334c81afbf99748e000575ba1cbad129
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  443ac570ac90a1d14558fcb61b8998b3707031cc
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 951f5a448914ae8b2c631f45d9ceff8766e13397
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 951f5a448914ae8b2c631f45d9ceff8766e13397
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  68356c65e6696f98a1ed8929f6b0685fe8527989
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 443ac570ac90a1d14558fcb61b8998b3707031cc
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 443ac570ac90a1d14558fcb61b8998b3707031cc
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  8bf5766b5293c3b3ca008ea3f90b670b92a19807
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: 68356c65e6696f98a1ed8929f6b0685fe8527989
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 68356c65e6696f98a1ed8929f6b0685fe8527989
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  f25bd3a81f49040ae7ecf5a75e3ed2529912f1d3
  - rank: 13
  - pow2: 3
  - exclusive-part:
    - parent: 87702a37554db29dc516c095781073ce3cb1ed55
      - rank: 6
      - pow2: 2
      - pidx: p1
    - size: 5
    - splits:
      - head:   87702a37554db29dc516c095781073ce3cb1ed55
        length: 5
  - tail-part:
    - parent: 8bf5766b5293c3b3ca008ea3f90b670b92a19807
      - rank: 7
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     13
    - min-rank: 1
  c9f0d9896a25d4453e20d2560be88504e4c5008a
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: f25bd3a81f49040ae7ecf5a75e3ed2529912f1d3
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: f25bd3a81f49040ae7ecf5a75e3ed2529912f1d3
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14

  $ cd ..


Example 3: shadowing of a final leap
====================================

We have a merge "f" whose exclusive part contains a merge "d".

The inherited parent of "d" is not in the exclusive part of "f".
At the end of the exclusive part of "d",
the leap to "c" is shadowed by the leap to "e", i.e. the inherited part to "f".

Notice that emitting "c" before "e" would break the reverse topological
ordering.

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      --<--   |
#      |   |   |
#      |   +----
#      b   |
#      |   c
#      |   |
#      --+--       <- at this point, jumping to "e", not the shadowed "c"
#        |
#        a

  $ hg init example-3
  $ cd example-3
  $ hg debugbuilddag '.:a*a:b<a+2:c*b/c:d<c+3:e*d/e:f.'
  $ hg test-log
  o    f rank=9
  |\
  | o  e rank=6
  | :
  o :  d rank=5
  |\:
  | o  c rank=3
  | :
  o :  b rank=2
  :/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,b,c,a, (no-eol)

Check that we leap from "b" directly to "e" (shadowing the leap to "c"),
and that "c" is then emitted after "e" (its descendant).

  $ hg test-sts f
  f,d,b,e,c,a, (no-eol)

Check the leaps of "d".

  $ hg test-splits d
  b length: 1


Check thet leaps of "f", which, despite being a descendant of "f", has a
different stable-tail sort which does not reuse any leap of "d".

  $ hg test-splits f
  d length: 2

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  fa942426a6fdfa3e512ef78f0ea686aca7210ef7
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  36315563e2fa12a641012831d9998bfa99924bda
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: fa942426a6fdfa3e512ef78f0ea686aca7210ef7
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: fa942426a6fdfa3e512ef78f0ea686aca7210ef7
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  f37e476fba9a08440a9e28b4b35453600e088a97
  - rank: 5
  - pow2: 2
  - exclusive-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   66f7d451a68b85ed82ff5fcc254daf50c74144bd
        length: 1
  - tail-part:
    - parent: 36315563e2fa12a641012831d9998bfa99924bda
      - rank: 3
      - pow2: 1
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     5
    - min-rank: 1
  46667b8667bb6a6d7358940b2a362704a00021f4
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 36315563e2fa12a641012831d9998bfa99924bda
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  67ddbd5e059a53fcc951579f0e175355930e2564
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 46667b8667bb6a6d7358940b2a362704a00021f4
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 46667b8667bb6a6d7358940b2a362704a00021f4
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  dcafac55b777e053c1b1cfd5171dd3e0d733147d
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 67ddbd5e059a53fcc951579f0e175355930e2564
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 67ddbd5e059a53fcc951579f0e175355930e2564
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  33d325fb53066d8224707fc83ac71e8af79233e4
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: f37e476fba9a08440a9e28b4b35453600e088a97
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 2
    - splits:
      - head:   f37e476fba9a08440a9e28b4b35453600e088a97
        length: 2
  - tail-part:
    - parent: dcafac55b777e053c1b1cfd5171dd3e0d733147d
      - rank: 6
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  3ffeb34d6b3d30a5f6d9f0a678f9475b7aa70117
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 33d325fb53066d8224707fc83ac71e8af79233e4
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 33d325fb53066d8224707fc83ac71e8af79233e4
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10


  $ cd ..


Example 4: skipping over nested exclusive part (entirely)
=========================================================

We have a merge "f" whose exclusive part contains a merge "d".

The exclusive part of "d" is not in the exclusive part of "f".
However, some of the inherited part of "d" is part of the exclusive part of "f"
and needs to be iterated over before leaping to the inherited part of "f".

The sort of "d" is partially reused for the ordering of the exclusive part of
"f". However the reused part is not contiguous in the sort of "d".

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      -->--   |    <- in the sort of "f", we need to skip "c" and leap to the
#      |   |   |       inherited part of "d"
#      |   +----
#      b   |
#      |   c
#      |   |
#      --+--
#        |
#        a

  $ hg init example-4
  $ cd example-4
  $ hg debugbuilddag '.:a*a+1:b<a+1:c*b/c:d<c+4:e*d/e:f.'
  $ hg test-log
  o    f rank=10
  |\
  | o  e rank=6
  | :
  o :  d rank=5
  |\:
  | o  c rank=2
  | |
  o |  b rank=3
  |/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,c,b,a, (no-eol)

Check that sort "f" leaps from "d" to "b":

  $ hg test-sts f
  f,d,b,e,c,a, (no-eol)

Check the leaps of "d".

  $ hg test-splits d
  c length: 1


Check the leaps of "f".

  $ hg test-splits f
  d length: 1
  b length: 2

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  6100d3090acf50ed11ec23196cec20f5bd7323aa
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  b814aa700de2aa434cfcdfb4ad23a41dd7f18a29
  - rank: 5
  - pow2: 2
  - exclusive-part:
    - parent: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank: 2
      - pow2: 1
      - pidx: p2
    - size: 1
    - splits:
      - head:   6100d3090acf50ed11ec23196cec20f5bd7323aa
        length: 1
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     5
    - min-rank: 1
  7777e46d7cba2d3f8748dbefb959c2af5a08cde9
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  148a8f7efe75033b730da3bf38767b86fd70c717
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 7777e46d7cba2d3f8748dbefb959c2af5a08cde9
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  24d07184033af36f0c4955ccbc700eaa97cd3ef8
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 148a8f7efe75033b730da3bf38767b86fd70c717
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 148a8f7efe75033b730da3bf38767b86fd70c717
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  6cf9d19988e8c3209227a993c59a894376d7ea26
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 24d07184033af36f0c4955ccbc700eaa97cd3ef8
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 24d07184033af36f0c4955ccbc700eaa97cd3ef8
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  3318b8048ed4a3285c0b62874c5a2ea8b497254a
  - rank: 10
  - pow2: 3
  - exclusive-part:
    - parent: b814aa700de2aa434cfcdfb4ad23a41dd7f18a29
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   b814aa700de2aa434cfcdfb4ad23a41dd7f18a29
        length: 1
      - head:   01241442b3c2bf3211e593b549c655ea65b295e3
        length: 2
  - tail-part:
    - parent: 6cf9d19988e8c3209227a993c59a894376d7ea26
      - rank: 6
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     10
    - min-rank: 1
  6d5f2e616bdbe8ef576781b4d135975c4b6c7ba7
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 3318b8048ed4a3285c0b62874c5a2ea8b497254a
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 3318b8048ed4a3285c0b62874c5a2ea8b497254a
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11

  $ cd ..


Example 5: skipping over nested exclusive part (partially)
==========================================================

We have a merge "f" whose exclusive part contains a merge "d".

Similar to example 4, but the exclusive part of "d" is only partially
contained in the inherited part of "f".
So, we need to leap in the middle of the exclusive part of "d".

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      -->--   |
#      |   |   |
#      |   g   |
#      |   |   |
#      |   +----    <- in the sort of "f", leaping from "g" to "b"
#      b   |
#      |   c
#      |   |
#      --+--
#        |
#        a

  $ hg init example-5
  $ cd example-5
  $ hg debugbuilddag '.:a*a+2:b<a+1:c+1:g*b/g:d<c+6:e*d/e:f.'
  $ hg test-log
  o    f rank=14
  |\
  | o  e rank=8
  | :
  o :    d rank=7
  |\ \
  | o :  g rank=3
  | :/
  | o  c rank=2
  | |
  o |  b rank=4
  |/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,g,c,b,a, (no-eol)

Check that sort "f" leaps from "g" to "b":

  $ hg test-sts f
  f,d,g,b,e,c,a, (no-eol)

Check the leaps of "d".

  $ hg test-splits d
  g length: 2

Check the leaps of "f".

  $ hg test-splits f
  d length: 2
  b length: 3

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  e7bd5218ca1581c6fbe5aca38649e8a36d742881
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  3a367db1fabcd39958917c3b3b30303517ca4ddf
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  208fba66b5592f9d4f401ba8ac48746e426d8ac7
  - rank: 7
  - pow2: 2
  - exclusive-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p2
    - size: 2
    - splits:
      - head:   3a367db1fabcd39958917c3b3b30303517ca4ddf
        length: 2
  - tail-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank:   4
      - pow2:   2
    - size:     3
    - min-rank: 2
  5ef6ffbf7d71960ef3a23ac12fdb76f17b553873
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  27db97874b745eeceb462caecfc34f04c0913425
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 5ef6ffbf7d71960ef3a23ac12fdb76f17b553873
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  c07e5617e897f4df9cf5465905a43e6163152eb0
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 27db97874b745eeceb462caecfc34f04c0913425
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 27db97874b745eeceb462caecfc34f04c0913425
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  159f0ac1b335ed4f13c5f0afa0a4b87820293ee8
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: c07e5617e897f4df9cf5465905a43e6163152eb0
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: c07e5617e897f4df9cf5465905a43e6163152eb0
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  9c7222791872b3025cff57f2d78b288b1d493420
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: 159f0ac1b335ed4f13c5f0afa0a4b87820293ee8
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 159f0ac1b335ed4f13c5f0afa0a4b87820293ee8
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  6f36a96d78289a714c4fb4a9f473f0e61cc01380
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: 9c7222791872b3025cff57f2d78b288b1d493420
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  1d793cc7f9eff97ec1ddd4054e8d79e5638a6d26
  - rank: 14
  - pow2: 3
  - exclusive-part:
    - parent: 208fba66b5592f9d4f401ba8ac48746e426d8ac7
      - rank: 7
      - pow2: 2
      - pidx: p1
    - size: 5
    - splits:
      - head:   208fba66b5592f9d4f401ba8ac48746e426d8ac7
        length: 2
      - head:   2dc09a01254db841290af0538aa52f6f52c776e3
        length: 3
  - tail-part:
    - parent: 6f36a96d78289a714c4fb4a9f473f0e61cc01380
      - rank: 8
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 6f36a96d78289a714c4fb4a9f473f0e61cc01380
      - rank:   8
      - pow2:   3
    - size:     6
    - min-rank: 2
  88071ef9f76d08b3be7f90f08391b3f2458697d5
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 1d793cc7f9eff97ec1ddd4054e8d79e5638a6d26
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 1d793cc7f9eff97ec1ddd4054e8d79e5638a6d26
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15

  $ cd ..


Example 6: merge in the inherited part
======================================

Variant of example 2, but with a merge ("f") in the inherited part of "g".

"g" is a merge node whose inherited part contains a merge node "f".
We check that the stable-tail sort delegates properly after the exclusive part.

#         g
#         |
#      ---<---
#      |     |
#      d     f
#      |     |
#      |  ---<---
#      |  |     |
#      |  e     c
#      |  |     |
#      ---+     |    <- at this point, we're done (for good) with the exclusive
#         |     |       part of "g"
#         b     |
#         |     |
#         ---+---
#            |
#            a

  $ hg init example-6
  $ cd example-6
  $ hg debugbuilddag '.:a*a:b<a+3:c*b:d*b:e*e/c:f*d/f:g.'
  $ hg test-log
  o    g rank=9
  |\
  | o    f rank=7
  | |\
  | | o  e rank=3
  | | |
  o---+  d rank=3
   / /
  o |  c rank=4
  : |
  : o  b rank=2
  :/
  o  a rank=1
  

Display the sort of "f" for reference:

  $ hg test-sts f
  f,e,b,c,a, (no-eol)

Check that the sort of "g" delegates to the sort of "f" after processing its
exclusive part of "g":

  $ hg test-sts g
  g,d,f,e,b,c,a, (no-eol)

Check the leaps of "f".

  $ hg test-splits f
  e length: 2

Check the leaps of "g".

  $ hg test-splits g
  d length: 1

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  fa942426a6fdfa3e512ef78f0ea686aca7210ef7
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  36315563e2fa12a641012831d9998bfa99924bda
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: fa942426a6fdfa3e512ef78f0ea686aca7210ef7
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: fa942426a6fdfa3e512ef78f0ea686aca7210ef7
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  aa666880d7f5293501aed80f8504b1592a196692
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 36315563e2fa12a641012831d9998bfa99924bda
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  914970512d6560ada78b4d9c1b3015b19a184247
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  70da8ff7a36e7974122d7b7393c3052d4b087403
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  3bd1d3d7353d77858933a89ad6528366ae046d2a
  - rank: 7
  - pow2: 2
  - exclusive-part:
    - parent: 70da8ff7a36e7974122d7b7393c3052d4b087403
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 2
    - splits:
      - head:   70da8ff7a36e7974122d7b7393c3052d4b087403
        length: 2
  - tail-part:
    - parent: aa666880d7f5293501aed80f8504b1592a196692
      - rank: 4
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: aa666880d7f5293501aed80f8504b1592a196692
      - rank:   4
      - pow2:   2
    - size:     3
    - min-rank: 2
  36ac8b2edde84aa01a5f8f07ac4058089897741d
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 914970512d6560ada78b4d9c1b3015b19a184247
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   914970512d6560ada78b4d9c1b3015b19a184247
        length: 1
  - tail-part:
    - parent: 3bd1d3d7353d77858933a89ad6528366ae046d2a
      - rank: 7
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  d0b6bb458678619db671e3c9996328261f4c04fe
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 36ac8b2edde84aa01a5f8f07ac4058089897741d
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 36ac8b2edde84aa01a5f8f07ac4058089897741d
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10

  $ cd ..


Example 7: postponed iteration of common exclusive ancestors
============================================================

Sibling merges "j" and "k", with partially shared exclusive parts.

When considering the sort of "l", the iteration over this shared part cannot
happen when iterating over excl(j) and has to be postponed to excl(k).

#            l
#            |
#        ----<----
#        |       |
#        j       k
#        |       |
#      -->--   --<--
#      |   |   |   |
#      g   e   h   i
#      |   |   |   |
#      |   --+--   |   <- at this point, for the sort of "l", the iteration on
#      f     |     |      the end of excl(j) is postponed to the iteration of
#      |     d     |      excl(k)
#      |     |     |
#      |     c     |
#      |     |     |
#      ---+---     |
#         |        |
#         b        |
#         |        |
#         ----+-----
#             |
#             a

  $ hg init example-7
  $ cd example-7
  $ hg debugbuilddag \
  > '.:a*a:b*b:c*c:d*d:e*b:f<f+3:g<d+2:h<a+6:i*e/g:j*h/i:k*j/k:l.'
  $ hg test-log
  o    l rank=20
  |\
  | o    k rank=13
  | |\
  o \ \    j rank=10
  |\ \ \
  | | | o  i rank=7
  | | | :
  | | o :  h rank=6
  | | : :
  | o : :  g rank=6
  | : : :
  | o : :  f rank=3
  | | : :
  o---+ :  e rank=5
   / / /
  | o :  d rank=4
  | | :
  | o :  c rank=3
  |/ /
  o /  b rank=2
  :/
  o  a rank=1
  

Display the sort of "j" for reference:

  $ hg test-sts j
  j,e,d,c,g,f,b,a, (no-eol)

Display the sort of "k" for reference:

  $ hg test-sts k
  k,h,d,c,b,i,a, (no-eol)

Check that the common part of excl(j) and excl(k) is iterated over after "k":

  $ hg test-sts l
  l,j,e,g,f,k,h,d,c,b,i,a, (no-eol)

Check the leaps of "j".

  $ hg test-splits j
  e length: 3

Check the leaps of "k".

  $ hg test-splits k
  h length: 5

Check the leaps of "l".

  $ hg test-splits l
  j length: 2
  g length: 4

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  bebd167eb94d257ace0e814aeb98e6972ed2970d
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  914970512d6560ada78b4d9c1b3015b19a184247
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  8bbe846c2602e829c55229979e60d2bfb2e1a9a2
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 914970512d6560ada78b4d9c1b3015b19a184247
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  92eaf3b9df4c321b7352febbbed60c0349094b1c
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 8bbe846c2602e829c55229979e60d2bfb2e1a9a2
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 8bbe846c2602e829c55229979e60d2bfb2e1a9a2
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  d291ff0893c44c862db04a03c7983c0406a44311
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 92eaf3b9df4c321b7352febbbed60c0349094b1c
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 92eaf3b9df4c321b7352febbbed60c0349094b1c
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  aa512f39d9bec98182d4f06c0fb50d0f4d26326b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  2b04f6067d1c830bc829d92be3b9c1af9534e36b
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: aa512f39d9bec98182d4f06c0fb50d0f4d26326b
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: aa512f39d9bec98182d4f06c0fb50d0f4d26326b
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  8a84167897831173f6516f05f491aef039333135
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  cef15d7fbe35d6fc4f1b3f793d251a9339620bf0
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 8a84167897831173f6516f05f491aef039333135
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 8a84167897831173f6516f05f491aef039333135
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  d407eea75768c195aceb102a218cb19b7cacfcde
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: cef15d7fbe35d6fc4f1b3f793d251a9339620bf0
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  15266bf23f38213640594eab3e767e30f7bf9e2d
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: d407eea75768c195aceb102a218cb19b7cacfcde
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: d407eea75768c195aceb102a218cb19b7cacfcde
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  96aef1dce51f5e513b997ba79836aeb09da4bc2e
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 15266bf23f38213640594eab3e767e30f7bf9e2d
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 15266bf23f38213640594eab3e767e30f7bf9e2d
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  d46010c4fdb39ad7306c0684629aae3e4a2b2e56
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: 96aef1dce51f5e513b997ba79836aeb09da4bc2e
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 96aef1dce51f5e513b997ba79836aeb09da4bc2e
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  2d240335b9a029f9cdc1c57434036219c723834e
  - rank: 10
  - pow2: 3
  - exclusive-part:
    - parent: bebd167eb94d257ace0e814aeb98e6972ed2970d
      - rank: 5
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   bebd167eb94d257ace0e814aeb98e6972ed2970d
        length: 3
  - tail-part:
    - parent: d291ff0893c44c862db04a03c7983c0406a44311
      - rank: 6
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     10
    - min-rank: 1
  96c52fb21bd862613cc8b5f4426c15941a6f6158
  - rank: 13
  - pow2: 3
  - exclusive-part:
    - parent: 2b04f6067d1c830bc829d92be3b9c1af9534e36b
      - rank: 6
      - pow2: 2
      - pidx: p1
    - size: 5
    - splits:
      - head:   2b04f6067d1c830bc829d92be3b9c1af9534e36b
        length: 5
  - tail-part:
    - parent: d46010c4fdb39ad7306c0684629aae3e4a2b2e56
      - rank: 7
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     13
    - min-rank: 1
  b05c83bc145f902be18dc86f4e4126e148ebbf4d
  - rank: 20
  - pow2: 4
  - exclusive-part:
    - parent: 2d240335b9a029f9cdc1c57434036219c723834e
      - rank: 10
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   2d240335b9a029f9cdc1c57434036219c723834e
        length: 2
      - head:   d291ff0893c44c862db04a03c7983c0406a44311
        length: 4
  - tail-part:
    - parent: 96c52fb21bd862613cc8b5f4426c15941a6f6158
      - rank: 13
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     20
    - min-rank: 1
  d9e33a06fdfa21ea48a11516f56f4da7eb9fb499
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: b05c83bc145f902be18dc86f4e4126e148ebbf4d
      - rank: 20
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: b05c83bc145f902be18dc86f4e4126e148ebbf4d
      - rank:   20
      - pow2:   4
    - size:     1
    - min-rank: 21

  $ cd ..


Example 8: postponed iteration of common ancestors between parts
================================================================

Sibling merges "g" and "i", with some part shared between the inherited part
of "g" and the exclusive part of "i".

When considering the sort of "j", the iteration over this shared part cannot
happen when iterating over inherited(g) and has to be postponed to excl(i).

#            j
#            |
#        ----<----
#        |       |
#        g       i
#        |       |
#      --<--   --<--
#      |   |   |   |
#      c   f   |   h
#      |   |   |   |
#      |   --+--   |   <- at this point, for the sort of "j", the iteration
#      |     |     |      on the end of inherited(g) is postponed to the
#      |     e     |      iteration of excl(k)
#      |     |     |
#      ---+---     |
#         b        |
#         |        |
#         ----+-----
#             |
#             a

  $ hg init example-8
  $ cd example-8
  $ hg debugbuilddag '.:a*a:b*b:c*b:d*d:e*e:f*c/f:g<a+5:h*e/h:i*g/i:j.'
  $ hg test-log
  o    j rank=14
  |\
  | o    i rank=10
  | |\
  | | o  h rank=6
  | | :
  o | :    g rank=7
  |\ \ \
  | o | :  f rank=5
  | |/ /
  | o :  e rank=4
  | | :
  | o :  d rank=3
  | | :
  o | :  c rank=3
  |/ /
  o /  b rank=2
  :/
  o  a rank=1
  

Display the sort of "g" for reference:

  $ hg test-sts g
  g,c,f,e,d,b,a, (no-eol)

Display the sort of "i" for reference:

  $ hg test-sts i
  i,e,d,b,h,a, (no-eol)

Check that the common part of inherited(g) and excl(k) is iterated over after
"i":

  $ hg test-sts j
  j,g,c,f,i,e,d,b,h,a, (no-eol)

Check the leaps of "g".

  $ hg test-splits g
  c length: 1
  $ hg test-splits g
  c length: 1

Check the leaps of "i".

  $ hg test-splits i
  e length: 3

Check the leaps of "j".

  $ hg test-splits j
  g length: 3

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  eda60bcb1a4164115a0f525ff7a81e0d87bbd730
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 7f07ae0d7af417ecdd63baabdd05c52da95bb2e9
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  6853e939ec7f133b2c4cc6e3b0abd23411c1b3e1
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  759da8042ca23881179e0fa43bf6930ef64f306b
  - rank: 7
  - pow2: 2
  - exclusive-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 1
    - splits:
      - head:   01241442b3c2bf3211e593b549c655ea65b295e3
        length: 1
  - tail-part:
    - parent: 6853e939ec7f133b2c4cc6e3b0abd23411c1b3e1
      - rank: 5
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 6853e939ec7f133b2c4cc6e3b0abd23411c1b3e1
      - rank:   5
      - pow2:   2
    - size:     2
    - min-rank: 3
  37c211a50b3425ee071dc027762a6c814e3a4159
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  80f9579eb88630ebbfd1e034f520a3b5a6a9fd88
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 37c211a50b3425ee071dc027762a6c814e3a4159
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 37c211a50b3425ee071dc027762a6c814e3a4159
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  8916dcd560ef2116e0f3c27c97153875f3946118
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 80f9579eb88630ebbfd1e034f520a3b5a6a9fd88
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  cd58d65d0adc71ea4987ea049a7b8ca0ec5dcb27
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 8916dcd560ef2116e0f3c27c97153875f3946118
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 8916dcd560ef2116e0f3c27c97153875f3946118
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  50ef8be5cecd78348c44a629e19084c613764db7
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: cd58d65d0adc71ea4987ea049a7b8ca0ec5dcb27
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: cd58d65d0adc71ea4987ea049a7b8ca0ec5dcb27
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  1caee9ae052b88b47509e527bc1f859391e1bb1f
  - rank: 10
  - pow2: 3
  - exclusive-part:
    - parent: eda60bcb1a4164115a0f525ff7a81e0d87bbd730
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   eda60bcb1a4164115a0f525ff7a81e0d87bbd730
        length: 3
  - tail-part:
    - parent: 50ef8be5cecd78348c44a629e19084c613764db7
      - rank: 6
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     10
    - min-rank: 1
  8e222cdf13b3a3020b97d2cf051768fe9160d721
  - rank: 14
  - pow2: 3
  - exclusive-part:
    - parent: 759da8042ca23881179e0fa43bf6930ef64f306b
      - rank: 7
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   759da8042ca23881179e0fa43bf6930ef64f306b
        length: 3
  - tail-part:
    - parent: 1caee9ae052b88b47509e527bc1f859391e1bb1f
      - rank: 10
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 1caee9ae052b88b47509e527bc1f859391e1bb1f
      - rank:   10
      - pow2:   3
    - size:     4
    - min-rank: 3
  9d77f9f46015f12e7be5b5b7ec1054536741f0a3
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 8e222cdf13b3a3020b97d2cf051768fe9160d721
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 8e222cdf13b3a3020b97d2cf051768fe9160d721
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15


  $ cd ..


Example 9: postponed iteration of common ancestors between both parts
=====================================================================

This is a combination of example 7 and 8 at the same time.
Both excl(i) and excl(j) share a common part.
Same with inherited(i) and inherited(j).

We test that the walk on the common ancestors in both cases is properly
postponed when considering sort(k).

#            k
#            |
#        ----<----
#        |       |
#        i       j
#        |       |
#      --<--   --<--
#      |   |   |   |
#      c   f   g   h
#      |   |   |   |
#      |   e   |   |
#      |   |   |   |
#      +--]|[---   |   <- rest of excl(i) postponed to excl(j)
#      |   |       |
#      b   ----+----   <- rest of inherited(i) postponed to inherited(j)
#      |       |
#      |       d
#      |       |
#      ----+----
#          |
#          a

  $ hg init example-9
  $ cd example-9
  $ hg debugbuilddag '.:a*a:b*b:c*a:d*d:e*e:f<b+2:g<d+3:h*c/f:i*g/h:j*i/j:k.'
  $ hg test-log
  o    k rank=14
  |\
  | o    j rank=9
  | |\
  o \ \    i rank=7
  |\ \ \
  | | | o  h rank=5
  | | | :
  | | o :  g rank=4
  | | : :
  | o : :  f rank=4
  | | : :
  | o---+  e rank=3
  |  / /
  | : o  d rank=2
  | : |
  o : |  c rank=3
  :/ /
  o /  b rank=2
  |/
  o  a rank=1
  

Display sort(i) for reference:

  $ hg test-sts i
  i,c,b,f,e,d,a, (no-eol)

Display sort(j) for reference:

  $ hg test-sts j
  j,g,b,h,d,a, (no-eol)

Check that the end of excl(i) is postponed to excl(j), the end of inherited(i)
is postponed to inherited(j) in sort(k):

  $ hg test-sts k
  k,i,c,f,e,j,g,b,h,d,a, (no-eol)

Check the leaps of "i".

  $ hg test-splits i
  c length: 2

Check the leaps of "j".

  $ hg test-splits j
  g length: 3

Check the leaps of "k".

  $ hg test-splits k
  i length: 2
  f length: 2

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  6100d3090acf50ed11ec23196cec20f5bd7323aa
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  aff549d9c64a908b3c1378b7beba7af65aa16a04
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  c8a5c0a3664e2d7220607ed9d0d0919009eb9090
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: aff549d9c64a908b3c1378b7beba7af65aa16a04
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  70da8ff7a36e7974122d7b7393c3052d4b087403
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  ee15b7e5882aa517a731f91ac608d9ecdf49141e
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 70da8ff7a36e7974122d7b7393c3052d4b087403
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  d404388f0de8d90703f7af4c7a733f9209242b9d
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 6100d3090acf50ed11ec23196cec20f5bd7323aa
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  4172904bafcfde03aaa3632e0465ad84188ab0cd
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: d404388f0de8d90703f7af4c7a733f9209242b9d
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  ee4a48cdd6d6ccb05b7343dad75f31ede4cafc02
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 4172904bafcfde03aaa3632e0465ad84188ab0cd
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 4172904bafcfde03aaa3632e0465ad84188ab0cd
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  f9db7a637ff4867369bc96e03989c17a1424d8d0
  - rank: 7
  - pow2: 2
  - exclusive-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
    - size: 2
    - splits:
      - head:   01241442b3c2bf3211e593b549c655ea65b295e3
        length: 2
  - tail-part:
    - parent: c8a5c0a3664e2d7220607ed9d0d0919009eb9090
      - rank: 4
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: c8a5c0a3664e2d7220607ed9d0d0919009eb9090
      - rank:   4
      - pow2:   2
    - size:     3
    - min-rank: 2
  c5109efe129ec2ce28ab3c48c6b348be16b2501d
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: ee15b7e5882aa517a731f91ac608d9ecdf49141e
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   ee15b7e5882aa517a731f91ac608d9ecdf49141e
        length: 3
  - tail-part:
    - parent: ee4a48cdd6d6ccb05b7343dad75f31ede4cafc02
      - rank: 5
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  60b1e46ffe42db3c59b2e72ce8219364b6093847
  - rank: 14
  - pow2: 3
  - exclusive-part:
    - parent: f9db7a637ff4867369bc96e03989c17a1424d8d0
      - rank: 7
      - pow2: 2
      - pidx: p1
    - size: 4
    - splits:
      - head:   f9db7a637ff4867369bc96e03989c17a1424d8d0
        length: 2
      - head:   c8a5c0a3664e2d7220607ed9d0d0919009eb9090
        length: 2
  - tail-part:
    - parent: c5109efe129ec2ce28ab3c48c6b348be16b2501d
      - rank: 9
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: c5109efe129ec2ce28ab3c48c6b348be16b2501d
      - rank:   9
      - pow2:   3
    - size:     5
    - min-rank: 3
  b0d131be8dfd8c4cfb2f731c5393b55b613ab1d3
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 60b1e46ffe42db3c59b2e72ce8219364b6093847
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 60b1e46ffe42db3c59b2e72ce8219364b6093847
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15

  $ cd ..


Example 10: adjusting other leaps
=================================

This test checks the adjustment of leaps attached to other open merges in the
stack.

#            o
#            |
#      ------>------
#      |           |
#      n           l
#      |           |
#      |       ----<----
#      |       |       |
#      |       i       k
#      m       |       |
#      |    ---<---    |
#      |    |     |    |
#      |    d     h    |
#      |    |     |    j
#      |    |     g    |
#      |    c     |    |
#      |    |     +-----
#      -----+     |
#           |     f
#           b     |
#           |     e         <- Done with excl(o) by element count, without
#           |     |            having emitted "b". Implicitly unstack open
#           ---+---            merges to leap e->n.
#              |
#              a

  $ hg init example-10
  $ cd example-10
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o.
  > '
  $ hg test-log
  o    o rank=34
  |\
  | o  n rank=18
  | :
  | o  m rank=3
  | |
  o |    l rank=17
  |\ \
  | o |  k rank=10
  | : |
  | o |  j rank=4
  | | |
  o | |    i rank=9
  |\ \ \
  | o | |  h rank=5
  | | | |
  | o | |  g rank=4
  | |/ /
  | o |  f rank=3
  | | |
  | o |  e rank=2
  | | |
  o | |  d rank=4
  | | |
  o---+  c rank=3
   / /
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "o":

  $ hg test-sts o
  o,l,i,d,c,h,g,k,j,f,e,n,m,b,a, (no-eol)

Stale-tail sort of "l" for reference:

  $ hg test-sts l
  l,i,d,c,b,h,g,k,j,f,e,a, (no-eol)

Check the corresponding leaps:

  $ hg test-splits o
  l length: 4
  h length: 2
  k length: 9

  $ hg test-splits l
  i length: 6

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  e7bd5218ca1581c6fbe5aca38649e8a36d742881
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  3a367db1fabcd39958917c3b3b30303517ca4ddf
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  a2f58e9c1e565f2a51d679bcf3ab36665748a686
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  d423bbba4459fb604f6b021d8837e0a13143fc8b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  c3252e853aa816577d1ab44250b52a91aefa2b3e
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   2dc09a01254db841290af0538aa52f6f52c776e3
        length: 3
  - tail-part:
    - parent: d423bbba4459fb604f6b021d8837e0a13143fc8b
      - rank: 5
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  bf25d38df0d7447cddaecc5f2fbdb77d404a9882
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  5e9928831c58cf0f077cc6d24def95d3f4832a0b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  e1c6ca038f7bae68bcdc9776adc4f187c74b6536
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  a5deaec860a631b1590e7a678db8bda0a8424894
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  1d3b25a78a443b16c7597c8d7ea0cbb183666821
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: a5deaec860a631b1590e7a678db8bda0a8424894
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  d032f07834c917b519268dd6efaeab78cdcb55c1
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: c3252e853aa816577d1ab44250b52a91aefa2b3e
      - rank: 9
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   c3252e853aa816577d1ab44250b52a91aefa2b3e
        length: 6
  - tail-part:
    - parent: c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
      - rank: 10
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     17
    - min-rank: 1
  a9f4c1272461fc49aa8b40a4be92335d952d370b
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  841fe954a309cdab6b1ce437a5ceeab2b29355c4
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: a9f4c1272461fc49aa8b40a4be92335d952d370b
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  a74bcc3b651bf62ba42b71c9bc78199a2715c284
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  eb927cb6c12750bcc620c84e859b287471adc0f3
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  6ba567ae287ff00744cb0194e64513601087e172
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: eb927cb6c12750bcc620c84e859b287471adc0f3
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  07ef4b04e71f91570af50232485b1f6f95ef5621
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 6ba567ae287ff00744cb0194e64513601087e172
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 6ba567ae287ff00744cb0194e64513601087e172
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11
  d60db0c3c409b32295b6cf551020ecb8e5231b1a
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank: 11
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank:   11
      - pow2:   3
    - size:     1
    - min-rank: 12
  94a5e8b61b1c844565b51f54868f3f1e8628a154
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank: 12
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank:   12
      - pow2:   3
    - size:     1
    - min-rank: 13
  407efd248a7a1b0f91a194668b9f2646487e80de
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14
  d4134bfcd915ee0300e5ffd06914341de3f37d6b
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15
  725b85ced0f1dbc37ed068c8e9589a5dafdd3301
  - rank: 16
  - pow2: 4
  - tail-part:
    - parent: d4134bfcd915ee0300e5ffd06914341de3f37d6b
      - rank: 15
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     16
    - min-rank: 1
  4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
  - rank: 17
  - pow2: 4
  - tail-part:
    - parent: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank: 16
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank:   16
      - pow2:   4
    - size:     1
    - min-rank: 17
  41a25b4c6272d70e21ded9e984117c93be642867
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank: 17
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank:   17
      - pow2:   4
    - size:     1
    - min-rank: 18
  973c306833a5c789251bfb53428783fa6ab4eb5f
  - rank: 34
  - pow2: 5
  - exclusive-part:
    - parent: d032f07834c917b519268dd6efaeab78cdcb55c1
      - rank: 17
      - pow2: 4
      - pidx: p2
    - size: 15
    - splits:
      - head:   d032f07834c917b519268dd6efaeab78cdcb55c1
        length: 4
      - head:   d423bbba4459fb604f6b021d8837e0a13143fc8b
        length: 2
      - head:   c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
        length: 9
  - tail-part:
    - parent: 41a25b4c6272d70e21ded9e984117c93be642867
      - rank: 18
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     34
    - min-rank: 1
  d32554f8582631ba9521c4adafa6874c5cd6b4ac
  - rank: 35
  - pow2: 5
  - tail-part:
    - parent: 973c306833a5c789251bfb53428783fa6ab4eb5f
      - rank: 34
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: 973c306833a5c789251bfb53428783fa6ab4eb5f
      - rank:   34
      - pow2:   5
    - size:     1
    - min-rank: 35

  $ cd ..


Example 11: adjusting other leaps with the same destination
===========================================================

This is a variant of the previous test, checking the adjustment of leaps having
the same destination in particular.

#            r
#            |
#      ------>------
#      |           |
#      |           o
#      q           |
#      |     ------>------
#      |     |           |
#      |     n           l
#      |     |           |
#      |     |       ----<----
#      p     |       |       |
#      |     |       i       k
#      |     m       |       |
#      |     |    ---<---    |
#      |     |    |     |    |
#      |     |    d     h    |
#      |     |    |     |    j
#      -----]|[---+     |    |   <- in sts(r): leap d->h
#            |    |     g    |
#            |    c     |    |
#            |    |     +-----
#            -----+     |        <- the leap c->h of sts(o)
#                 |     f           is shadowed in sts(r)
#                 b     |
#                 |     e
#                 |     |
#                 ---+---
#                    |
#                    a

  $ hg init example-11
  $ cd example-11
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o
  >          *c:p+31:q
  >                       *o/q:r.
  > '
  $ hg test-log
  o    r rank=67
  |\
  | o  q rank=35
  | :
  | o  p rank=4
  | |
  o |    o rank=34
  |\ \
  | o |  n rank=18
  | : |
  | o |  m rank=3
  | | |
  o | |    l rank=17
  |\ \ \
  | o | |  k rank=10
  | : | |
  | o | |  j rank=4
  | | | |
  o | | |    i rank=9
  |\ \ \ \
  | o | | |  h rank=5
  | | | | |
  | o | | |  g rank=4
  | |/ / /
  | o | |  f rank=3
  | | | |
  | o | |  e rank=2
  | | | |
  o-----+  d rank=4
   / / /
  | | o  c rank=3
  | |/
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "r":

  $ hg test-sts r
  r,o,l,i,d,h,g,k,j,f,e,n,m,q,p,c,b,a, (no-eol)

Stable-tail sort of "o" for reference:

  $ hg test-sts o
  o,l,i,d,c,h,g,k,j,f,e,n,m,b,a, (no-eol)

Check the associated leaps:

  $ hg test-splits r
  o length: 4
  h length: 2
  k length: 9
  n length: 16

  $ hg test-splits o
  l length: 4
  h length: 2
  k length: 9

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  e7bd5218ca1581c6fbe5aca38649e8a36d742881
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  3a367db1fabcd39958917c3b3b30303517ca4ddf
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  a2f58e9c1e565f2a51d679bcf3ab36665748a686
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  d423bbba4459fb604f6b021d8837e0a13143fc8b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  c3252e853aa816577d1ab44250b52a91aefa2b3e
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   2dc09a01254db841290af0538aa52f6f52c776e3
        length: 3
  - tail-part:
    - parent: d423bbba4459fb604f6b021d8837e0a13143fc8b
      - rank: 5
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  bf25d38df0d7447cddaecc5f2fbdb77d404a9882
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  5e9928831c58cf0f077cc6d24def95d3f4832a0b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  e1c6ca038f7bae68bcdc9776adc4f187c74b6536
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  a5deaec860a631b1590e7a678db8bda0a8424894
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  1d3b25a78a443b16c7597c8d7ea0cbb183666821
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: a5deaec860a631b1590e7a678db8bda0a8424894
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  d032f07834c917b519268dd6efaeab78cdcb55c1
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: c3252e853aa816577d1ab44250b52a91aefa2b3e
      - rank: 9
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   c3252e853aa816577d1ab44250b52a91aefa2b3e
        length: 6
  - tail-part:
    - parent: c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
      - rank: 10
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     17
    - min-rank: 1
  a9f4c1272461fc49aa8b40a4be92335d952d370b
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  841fe954a309cdab6b1ce437a5ceeab2b29355c4
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: a9f4c1272461fc49aa8b40a4be92335d952d370b
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  a74bcc3b651bf62ba42b71c9bc78199a2715c284
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  eb927cb6c12750bcc620c84e859b287471adc0f3
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  6ba567ae287ff00744cb0194e64513601087e172
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: eb927cb6c12750bcc620c84e859b287471adc0f3
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  07ef4b04e71f91570af50232485b1f6f95ef5621
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 6ba567ae287ff00744cb0194e64513601087e172
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 6ba567ae287ff00744cb0194e64513601087e172
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11
  d60db0c3c409b32295b6cf551020ecb8e5231b1a
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank: 11
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank:   11
      - pow2:   3
    - size:     1
    - min-rank: 12
  94a5e8b61b1c844565b51f54868f3f1e8628a154
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank: 12
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank:   12
      - pow2:   3
    - size:     1
    - min-rank: 13
  407efd248a7a1b0f91a194668b9f2646487e80de
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14
  d4134bfcd915ee0300e5ffd06914341de3f37d6b
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15
  725b85ced0f1dbc37ed068c8e9589a5dafdd3301
  - rank: 16
  - pow2: 4
  - tail-part:
    - parent: d4134bfcd915ee0300e5ffd06914341de3f37d6b
      - rank: 15
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     16
    - min-rank: 1
  4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
  - rank: 17
  - pow2: 4
  - tail-part:
    - parent: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank: 16
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank:   16
      - pow2:   4
    - size:     1
    - min-rank: 17
  41a25b4c6272d70e21ded9e984117c93be642867
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank: 17
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank:   17
      - pow2:   4
    - size:     1
    - min-rank: 18
  973c306833a5c789251bfb53428783fa6ab4eb5f
  - rank: 34
  - pow2: 5
  - exclusive-part:
    - parent: d032f07834c917b519268dd6efaeab78cdcb55c1
      - rank: 17
      - pow2: 4
      - pidx: p2
    - size: 15
    - splits:
      - head:   d032f07834c917b519268dd6efaeab78cdcb55c1
        length: 4
      - head:   d423bbba4459fb604f6b021d8837e0a13143fc8b
        length: 2
      - head:   c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
        length: 9
  - tail-part:
    - parent: 41a25b4c6272d70e21ded9e984117c93be642867
      - rank: 18
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     34
    - min-rank: 1
  6e8d1823e1b501e426f5cda6e200c03de57f70ec
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  555d0050541e149313ad76d4ee0ecb02a8d93b3e
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 6e8d1823e1b501e426f5cda6e200c03de57f70ec
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 6e8d1823e1b501e426f5cda6e200c03de57f70ec
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  bfcc330ba67ea2ed5100a97ca26873c2e3bbc142
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 555d0050541e149313ad76d4ee0ecb02a8d93b3e
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 555d0050541e149313ad76d4ee0ecb02a8d93b3e
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  58b20133ca9e2dc76e74d94e00eca3e4f712cfa5
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: bfcc330ba67ea2ed5100a97ca26873c2e3bbc142
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: bfcc330ba67ea2ed5100a97ca26873c2e3bbc142
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  66701e2a7184d0d280a7ba3495386f02f6b3ed71
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: 58b20133ca9e2dc76e74d94e00eca3e4f712cfa5
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  753eacde8256591348c56f2b3d440f3e0c872def
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 66701e2a7184d0d280a7ba3495386f02f6b3ed71
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 66701e2a7184d0d280a7ba3495386f02f6b3ed71
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  4f9ca793918ccd97ed4d54cce3d7d3acc7affb9c
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 753eacde8256591348c56f2b3d440f3e0c872def
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 753eacde8256591348c56f2b3d440f3e0c872def
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  ba6d4ed1ef84b641ca9e57d946664ee8b413d6a7
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 4f9ca793918ccd97ed4d54cce3d7d3acc7affb9c
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 4f9ca793918ccd97ed4d54cce3d7d3acc7affb9c
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11
  61ad9d14f83a71934e86357b216e82626801db25
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: ba6d4ed1ef84b641ca9e57d946664ee8b413d6a7
      - rank: 11
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: ba6d4ed1ef84b641ca9e57d946664ee8b413d6a7
      - rank:   11
      - pow2:   3
    - size:     1
    - min-rank: 12
  21cc8dd84e0f29547b0762e72b4a8f1490fe555e
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 61ad9d14f83a71934e86357b216e82626801db25
      - rank: 12
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 61ad9d14f83a71934e86357b216e82626801db25
      - rank:   12
      - pow2:   3
    - size:     1
    - min-rank: 13
  059b2cdb449c2ecf67a46c2f5d2697058d6287eb
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: 21cc8dd84e0f29547b0762e72b4a8f1490fe555e
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 21cc8dd84e0f29547b0762e72b4a8f1490fe555e
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14
  406ff67af8bbabd08043d220d25aad53d2c1093e
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 059b2cdb449c2ecf67a46c2f5d2697058d6287eb
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 059b2cdb449c2ecf67a46c2f5d2697058d6287eb
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15
  3d86995d80991ce8a75cdb4a94a65d51aa4562da
  - rank: 16
  - pow2: 4
  - tail-part:
    - parent: 406ff67af8bbabd08043d220d25aad53d2c1093e
      - rank: 15
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     16
    - min-rank: 1
  37f6432242b79b7a8f584a413ace225300ffb6f3
  - rank: 17
  - pow2: 4
  - tail-part:
    - parent: 3d86995d80991ce8a75cdb4a94a65d51aa4562da
      - rank: 16
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 3d86995d80991ce8a75cdb4a94a65d51aa4562da
      - rank:   16
      - pow2:   4
    - size:     1
    - min-rank: 17
  5ba626f02644872bf1eec5fe44c00e08c30429f6
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 37f6432242b79b7a8f584a413ace225300ffb6f3
      - rank: 17
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 37f6432242b79b7a8f584a413ace225300ffb6f3
      - rank:   17
      - pow2:   4
    - size:     1
    - min-rank: 18
  eb21634be293f6694293d7fe3adb7c6d7aa1c882
  - rank: 19
  - pow2: 4
  - tail-part:
    - parent: 5ba626f02644872bf1eec5fe44c00e08c30429f6
      - rank: 18
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 5ba626f02644872bf1eec5fe44c00e08c30429f6
      - rank:   18
      - pow2:   4
    - size:     1
    - min-rank: 19
  6264446be8a901dd2ffb85aaec76e38104cd4994
  - rank: 20
  - pow2: 4
  - tail-part:
    - parent: eb21634be293f6694293d7fe3adb7c6d7aa1c882
      - rank: 19
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: eb21634be293f6694293d7fe3adb7c6d7aa1c882
      - rank:   19
      - pow2:   4
    - size:     1
    - min-rank: 20
  92ecce09a369c82550b76520d3c9e4cbb9859b1c
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: 6264446be8a901dd2ffb85aaec76e38104cd4994
      - rank: 20
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 6264446be8a901dd2ffb85aaec76e38104cd4994
      - rank:   20
      - pow2:   4
    - size:     1
    - min-rank: 21
  290b545762ee4527bd5f8f724e46c98f6797cb0a
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: 92ecce09a369c82550b76520d3c9e4cbb9859b1c
      - rank: 21
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 92ecce09a369c82550b76520d3c9e4cbb9859b1c
      - rank:   21
      - pow2:   4
    - size:     1
    - min-rank: 22
  834ce057b62cd68b0a9d0fb2a835c01dbdd515dd
  - rank: 23
  - pow2: 4
  - tail-part:
    - parent: 290b545762ee4527bd5f8f724e46c98f6797cb0a
      - rank: 22
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 290b545762ee4527bd5f8f724e46c98f6797cb0a
      - rank:   22
      - pow2:   4
    - size:     1
    - min-rank: 23
  08ad5d144da74f23fda2bb55580b4d25240ee6fd
  - rank: 24
  - pow2: 4
  - tail-part:
    - parent: 834ce057b62cd68b0a9d0fb2a835c01dbdd515dd
      - rank: 23
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 834ce057b62cd68b0a9d0fb2a835c01dbdd515dd
      - rank:   23
      - pow2:   4
    - size:     1
    - min-rank: 24
  fb4bef9b5b6244c023efa5578f8d733e0e81035f
  - rank: 25
  - pow2: 4
  - tail-part:
    - parent: 08ad5d144da74f23fda2bb55580b4d25240ee6fd
      - rank: 24
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 08ad5d144da74f23fda2bb55580b4d25240ee6fd
      - rank:   24
      - pow2:   4
    - size:     1
    - min-rank: 25
  10efb8911eebe7ad25c0fc3df07e53f82ee92f7d
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: fb4bef9b5b6244c023efa5578f8d733e0e81035f
      - rank: 25
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: fb4bef9b5b6244c023efa5578f8d733e0e81035f
      - rank:   25
      - pow2:   4
    - size:     1
    - min-rank: 26
  97c7e9d28ba5140cea0a4179d808e38786b3aa2b
  - rank: 27
  - pow2: 4
  - tail-part:
    - parent: 10efb8911eebe7ad25c0fc3df07e53f82ee92f7d
      - rank: 26
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 10efb8911eebe7ad25c0fc3df07e53f82ee92f7d
      - rank:   26
      - pow2:   4
    - size:     1
    - min-rank: 27
  6b62edfbe857528d68597a74fafc9961dfec94a5
  - rank: 28
  - pow2: 4
  - tail-part:
    - parent: 97c7e9d28ba5140cea0a4179d808e38786b3aa2b
      - rank: 27
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 97c7e9d28ba5140cea0a4179d808e38786b3aa2b
      - rank:   27
      - pow2:   4
    - size:     1
    - min-rank: 28
  d40bc6decf9cec0d67781d8e062a49152abb862e
  - rank: 29
  - pow2: 4
  - tail-part:
    - parent: 6b62edfbe857528d68597a74fafc9961dfec94a5
      - rank: 28
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 6b62edfbe857528d68597a74fafc9961dfec94a5
      - rank:   28
      - pow2:   4
    - size:     1
    - min-rank: 29
  c37315d1a08a2ae7ed78a9d9f9bafc0368b75bc4
  - rank: 30
  - pow2: 4
  - tail-part:
    - parent: d40bc6decf9cec0d67781d8e062a49152abb862e
      - rank: 29
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: d40bc6decf9cec0d67781d8e062a49152abb862e
      - rank:   29
      - pow2:   4
    - size:     1
    - min-rank: 30
  f9663f85ad74420f8de8d6ce8786637f485ed7d3
  - rank: 31
  - pow2: 4
  - tail-part:
    - parent: c37315d1a08a2ae7ed78a9d9f9bafc0368b75bc4
      - rank: 30
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: c37315d1a08a2ae7ed78a9d9f9bafc0368b75bc4
      - rank:   30
      - pow2:   4
    - size:     1
    - min-rank: 31
  a316dba09147d535d5c2c1bcf4da81395a3e73d6
  - rank: 32
  - pow2: 5
  - tail-part:
    - parent: f9663f85ad74420f8de8d6ce8786637f485ed7d3
      - rank: 31
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     32
    - min-rank: 1
  b90e99bbac80418d9ead6e9df75fa27e93d1158e
  - rank: 33
  - pow2: 5
  - tail-part:
    - parent: a316dba09147d535d5c2c1bcf4da81395a3e73d6
      - rank: 32
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: a316dba09147d535d5c2c1bcf4da81395a3e73d6
      - rank:   32
      - pow2:   5
    - size:     1
    - min-rank: 33
  14610e66dd097e788e9bfaa24fa0b064b5fe0a58
  - rank: 34
  - pow2: 5
  - tail-part:
    - parent: b90e99bbac80418d9ead6e9df75fa27e93d1158e
      - rank: 33
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: b90e99bbac80418d9ead6e9df75fa27e93d1158e
      - rank:   33
      - pow2:   5
    - size:     1
    - min-rank: 34
  f70cd21befc34a59957c4e025debe71917842228
  - rank: 35
  - pow2: 5
  - tail-part:
    - parent: 14610e66dd097e788e9bfaa24fa0b064b5fe0a58
      - rank: 34
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: 14610e66dd097e788e9bfaa24fa0b064b5fe0a58
      - rank:   34
      - pow2:   5
    - size:     1
    - min-rank: 35
  94c331d2ded0a543412447a128f753fbe8cc89aa
  - rank: 67
  - pow2: 6
  - exclusive-part:
    - parent: 973c306833a5c789251bfb53428783fa6ab4eb5f
      - rank: 34
      - pow2: 5
      - pidx: p1
    - size: 31
    - splits:
      - head:   973c306833a5c789251bfb53428783fa6ab4eb5f
        length: 4
      - head:   d423bbba4459fb604f6b021d8837e0a13143fc8b
        length: 2
      - head:   c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
        length: 9
      - head:   41a25b4c6272d70e21ded9e984117c93be642867
        length: 16
  - tail-part:
    - parent: f70cd21befc34a59957c4e025debe71917842228
      - rank: 35
      - pow2: 5
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     67
    - min-rank: 1
  3e53cd89655db8c9f3d8a4a46a31e91fc611ccd3
  - rank: 68
  - pow2: 6
  - tail-part:
    - parent: 94c331d2ded0a543412447a128f753fbe8cc89aa
      - rank: 67
      - pow2: 6
      - pidx: p1
  - canonical-part:
    - ancestor: 94c331d2ded0a543412447a128f753fbe8cc89aa
      - rank:   67
      - pow2:   6
    - size:     1
    - min-rank: 68

  $ cd ..


Example 12
==========

This is a variant of the previous test, checking the adjustments of leaps
in the open merge stack having a lower destination (which should appear only
later in the stable-tail sort of the head).

#            t
#            |
#      ------>------
#      |           |
#      |           o
#      s           |
#      |     ------>------
#      |     |           |
#      |     n           l
#      r     |           |
#      |     |       ----<----
#      |     |       |       |
#    --<--   |       i       k
#    |   |   m       |       |
#    p   q   |    ---<---    |
#    |   |   |    |     |    |
#    |   ---]|[--]|[----+    |
#    |       |    |     |    |
#    |       |    d     h    |
#    |       |    |     |    j
#    -------]|[---+     |    |   <- d->k is sts(t)
#            |    |     g    |
#            |    c     |    |
#            |    |     +-----
#            -----+     |        <- c->h in sts(o), not applying in sts(t)
#                 |     f
#                 b     |
#                 |     e
#                 |     |
#                 ---+---
#                    |
#                    a

  $ hg init example-12
  $ cd example-12
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o
  >          *c:p
  >               *h:q
  >               *p/q:r+25:s
  >                       *o/s:t.
  > '
  $ hg test-log
  o    t rank=63
  |\
  | o  s rank=35
  | :
  | o    r rank=10
  | |\
  | | o  q rank=6
  | | |
  | o |  p rank=4
  | | |
  o | |    o rank=34
  |\ \ \
  | o | |  n rank=18
  | : | |
  | o | |  m rank=3
  | | | |
  o | | |    l rank=17
  |\ \ \ \
  | o | | |  k rank=10
  | : | | |
  | o | | |  j rank=4
  | | | | |
  o-------+  i rank=9
  | | | | |
  | | | | o  h rank=5
  | | | | |
  | +-----o  g rank=4
  | | | |
  | o | |  f rank=3
  | | | |
  | o | |  e rank=2
  | | | |
  o-----+  d rank=4
   / / /
  | | o  c rank=3
  | |/
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "t":

  $ hg test-sts t
  t,o,l,i,d,k,j,n,m,s,r,p,c,b,q,h,g,f,e,a, (no-eol)

Stable-tail sort of "o" for reference:

  $ hg test-sts o
  o,l,i,d,c,h,g,k,j,f,e,n,m,b,a, (no-eol)

Check the associated leaps:

  $ hg test-splits t
  o length: 4
  k length: 7
  n length: 16

  $ hg test-splits o
  l length: 4
  h length: 2
  k length: 9

Validate overall information

  $ hg debug::stable-tail-info 'all()'
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  - rank: 1
  - pow2: 0
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     1
    - min-rank: 1
  66f7d451a68b85ed82ff5fcc254daf50c74144bd
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  01241442b3c2bf3211e593b549c655ea65b295e3
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  2dc09a01254db841290af0538aa52f6f52c776e3
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  e7bd5218ca1581c6fbe5aca38649e8a36d742881
  - rank: 2
  - pow2: 1
  - tail-part:
    - parent: 1ea73414a91b0920940797d8fc6a11e447f8ea1e
      - rank: 1
      - pow2: 0
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     2
    - min-rank: 1
  3a367db1fabcd39958917c3b3b30303517ca4ddf
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: e7bd5218ca1581c6fbe5aca38649e8a36d742881
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  a2f58e9c1e565f2a51d679bcf3ab36665748a686
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  d423bbba4459fb604f6b021d8837e0a13143fc8b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a2f58e9c1e565f2a51d679bcf3ab36665748a686
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  c3252e853aa816577d1ab44250b52a91aefa2b3e
  - rank: 9
  - pow2: 3
  - exclusive-part:
    - parent: 2dc09a01254db841290af0538aa52f6f52c776e3
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   2dc09a01254db841290af0538aa52f6f52c776e3
        length: 3
  - tail-part:
    - parent: d423bbba4459fb604f6b021d8837e0a13143fc8b
      - rank: 5
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     9
    - min-rank: 1
  bf25d38df0d7447cddaecc5f2fbdb77d404a9882
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 3a367db1fabcd39958917c3b3b30303517ca4ddf
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  5e9928831c58cf0f077cc6d24def95d3f4832a0b
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: bf25d38df0d7447cddaecc5f2fbdb77d404a9882
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  e1c6ca038f7bae68bcdc9776adc4f187c74b6536
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 5e9928831c58cf0f077cc6d24def95d3f4832a0b
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  a5deaec860a631b1590e7a678db8bda0a8424894
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: e1c6ca038f7bae68bcdc9776adc4f187c74b6536
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  1d3b25a78a443b16c7597c8d7ea0cbb183666821
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: a5deaec860a631b1590e7a678db8bda0a8424894
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 1d3b25a78a443b16c7597c8d7ea0cbb183666821
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 4efe0eb40d0cd6add556490f66bf25b5ed4c4a2a
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  d032f07834c917b519268dd6efaeab78cdcb55c1
  - rank: 17
  - pow2: 4
  - exclusive-part:
    - parent: c3252e853aa816577d1ab44250b52a91aefa2b3e
      - rank: 9
      - pow2: 3
      - pidx: p1
    - size: 6
    - splits:
      - head:   c3252e853aa816577d1ab44250b52a91aefa2b3e
        length: 6
  - tail-part:
    - parent: c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
      - rank: 10
      - pow2: 3
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     17
    - min-rank: 1
  a9f4c1272461fc49aa8b40a4be92335d952d370b
  - rank: 3
  - pow2: 1
  - tail-part:
    - parent: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank: 2
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 66f7d451a68b85ed82ff5fcc254daf50c74144bd
      - rank:   2
      - pow2:   1
    - size:     1
    - min-rank: 3
  841fe954a309cdab6b1ce437a5ceeab2b29355c4
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: a9f4c1272461fc49aa8b40a4be92335d952d370b
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
  - rank: 5
  - pow2: 2
  - tail-part:
    - parent: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank: 4
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 841fe954a309cdab6b1ce437a5ceeab2b29355c4
      - rank:   4
      - pow2:   2
    - size:     1
    - min-rank: 5
  a74bcc3b651bf62ba42b71c9bc78199a2715c284
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 3b3921d9fcb4f2d0d39b021ca1c426b9012ed8ae
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  eb927cb6c12750bcc620c84e859b287471adc0f3
  - rank: 7
  - pow2: 2
  - tail-part:
    - parent: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank: 6
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: a74bcc3b651bf62ba42b71c9bc78199a2715c284
      - rank:   6
      - pow2:   2
    - size:     1
    - min-rank: 7
  6ba567ae287ff00744cb0194e64513601087e172
  - rank: 8
  - pow2: 3
  - tail-part:
    - parent: eb927cb6c12750bcc620c84e859b287471adc0f3
      - rank: 7
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     8
    - min-rank: 1
  07ef4b04e71f91570af50232485b1f6f95ef5621
  - rank: 9
  - pow2: 3
  - tail-part:
    - parent: 6ba567ae287ff00744cb0194e64513601087e172
      - rank: 8
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 6ba567ae287ff00744cb0194e64513601087e172
      - rank:   8
      - pow2:   3
    - size:     1
    - min-rank: 9
  5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
  - rank: 10
  - pow2: 3
  - tail-part:
    - parent: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank: 9
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 07ef4b04e71f91570af50232485b1f6f95ef5621
      - rank:   9
      - pow2:   3
    - size:     1
    - min-rank: 10
  ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 5a25b6f5bb32d65f264ff0ce7ed303a9ae73036f
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11
  d60db0c3c409b32295b6cf551020ecb8e5231b1a
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank: 11
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: ac22f6f842adc6d793c0b8a7e205878f0a4c0f71
      - rank:   11
      - pow2:   3
    - size:     1
    - min-rank: 12
  94a5e8b61b1c844565b51f54868f3f1e8628a154
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank: 12
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: d60db0c3c409b32295b6cf551020ecb8e5231b1a
      - rank:   12
      - pow2:   3
    - size:     1
    - min-rank: 13
  407efd248a7a1b0f91a194668b9f2646487e80de
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 94a5e8b61b1c844565b51f54868f3f1e8628a154
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14
  d4134bfcd915ee0300e5ffd06914341de3f37d6b
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 407efd248a7a1b0f91a194668b9f2646487e80de
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15
  725b85ced0f1dbc37ed068c8e9589a5dafdd3301
  - rank: 16
  - pow2: 4
  - tail-part:
    - parent: d4134bfcd915ee0300e5ffd06914341de3f37d6b
      - rank: 15
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     16
    - min-rank: 1
  4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
  - rank: 17
  - pow2: 4
  - tail-part:
    - parent: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank: 16
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 725b85ced0f1dbc37ed068c8e9589a5dafdd3301
      - rank:   16
      - pow2:   4
    - size:     1
    - min-rank: 17
  41a25b4c6272d70e21ded9e984117c93be642867
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank: 17
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 4d491a6dcea5918270ee0c90a0307a6c78bb4f8f
      - rank:   17
      - pow2:   4
    - size:     1
    - min-rank: 18
  973c306833a5c789251bfb53428783fa6ab4eb5f
  - rank: 34
  - pow2: 5
  - exclusive-part:
    - parent: d032f07834c917b519268dd6efaeab78cdcb55c1
      - rank: 17
      - pow2: 4
      - pidx: p2
    - size: 15
    - splits:
      - head:   d032f07834c917b519268dd6efaeab78cdcb55c1
        length: 4
      - head:   d423bbba4459fb604f6b021d8837e0a13143fc8b
        length: 2
      - head:   c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
        length: 9
  - tail-part:
    - parent: 41a25b4c6272d70e21ded9e984117c93be642867
      - rank: 18
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     34
    - min-rank: 1
  6e8d1823e1b501e426f5cda6e200c03de57f70ec
  - rank: 4
  - pow2: 2
  - tail-part:
    - parent: 01241442b3c2bf3211e593b549c655ea65b295e3
      - rank: 3
      - pow2: 1
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     4
    - min-rank: 1
  4751439f0d9879ff49715bf7e49053aab5fc1aab
  - rank: 6
  - pow2: 2
  - tail-part:
    - parent: d423bbba4459fb604f6b021d8837e0a13143fc8b
      - rank: 5
      - pow2: 2
      - pidx: p1
  - canonical-part:
    - ancestor: d423bbba4459fb604f6b021d8837e0a13143fc8b
      - rank:   5
      - pow2:   2
    - size:     1
    - min-rank: 6
  31536213ba5ea944dd75b82a888026d3a5df4491
  - rank: 10
  - pow2: 3
  - exclusive-part:
    - parent: 6e8d1823e1b501e426f5cda6e200c03de57f70ec
      - rank: 4
      - pow2: 2
      - pidx: p1
    - size: 3
    - splits:
      - head:   6e8d1823e1b501e426f5cda6e200c03de57f70ec
        length: 3
  - tail-part:
    - parent: 4751439f0d9879ff49715bf7e49053aab5fc1aab
      - rank: 6
      - pow2: 2
      - pidx: p2
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     10
    - min-rank: 1
  af8325e32dc83bd8aa7bc9c8b5fe26ea47d7e31b
  - rank: 11
  - pow2: 3
  - tail-part:
    - parent: 31536213ba5ea944dd75b82a888026d3a5df4491
      - rank: 10
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 31536213ba5ea944dd75b82a888026d3a5df4491
      - rank:   10
      - pow2:   3
    - size:     1
    - min-rank: 11
  7b760dfbd1f37cff8c8e6d9cd6aa778ab29ccafc
  - rank: 12
  - pow2: 3
  - tail-part:
    - parent: af8325e32dc83bd8aa7bc9c8b5fe26ea47d7e31b
      - rank: 11
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: af8325e32dc83bd8aa7bc9c8b5fe26ea47d7e31b
      - rank:   11
      - pow2:   3
    - size:     1
    - min-rank: 12
  928e2b10a2af5a0c9699d1ce8b49333c9542bdb8
  - rank: 13
  - pow2: 3
  - tail-part:
    - parent: 7b760dfbd1f37cff8c8e6d9cd6aa778ab29ccafc
      - rank: 12
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 7b760dfbd1f37cff8c8e6d9cd6aa778ab29ccafc
      - rank:   12
      - pow2:   3
    - size:     1
    - min-rank: 13
  db741a5294a8fdef5605a368fff43e7856c91fc5
  - rank: 14
  - pow2: 3
  - tail-part:
    - parent: 928e2b10a2af5a0c9699d1ce8b49333c9542bdb8
      - rank: 13
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 928e2b10a2af5a0c9699d1ce8b49333c9542bdb8
      - rank:   13
      - pow2:   3
    - size:     1
    - min-rank: 14
  f622f1f0b93f474a41835cfb4d0368d9d15c6251
  - rank: 15
  - pow2: 3
  - tail-part:
    - parent: db741a5294a8fdef5605a368fff43e7856c91fc5
      - rank: 14
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: db741a5294a8fdef5605a368fff43e7856c91fc5
      - rank:   14
      - pow2:   3
    - size:     1
    - min-rank: 15
  e51e30541bf98cc61f53cf32e35eeb3b3ba29bfc
  - rank: 16
  - pow2: 4
  - tail-part:
    - parent: f622f1f0b93f474a41835cfb4d0368d9d15c6251
      - rank: 15
      - pow2: 3
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     16
    - min-rank: 1
  75c9fed5434c7fd2756fd23fabacf4a95491c1c2
  - rank: 17
  - pow2: 4
  - tail-part:
    - parent: e51e30541bf98cc61f53cf32e35eeb3b3ba29bfc
      - rank: 16
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: e51e30541bf98cc61f53cf32e35eeb3b3ba29bfc
      - rank:   16
      - pow2:   4
    - size:     1
    - min-rank: 17
  050500fffe2c40e68a31751871e54894665d5246
  - rank: 18
  - pow2: 4
  - tail-part:
    - parent: 75c9fed5434c7fd2756fd23fabacf4a95491c1c2
      - rank: 17
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 75c9fed5434c7fd2756fd23fabacf4a95491c1c2
      - rank:   17
      - pow2:   4
    - size:     1
    - min-rank: 18
  0a407d122eb2bc0c7813f667ef200eb85bdf2aaa
  - rank: 19
  - pow2: 4
  - tail-part:
    - parent: 050500fffe2c40e68a31751871e54894665d5246
      - rank: 18
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 050500fffe2c40e68a31751871e54894665d5246
      - rank:   18
      - pow2:   4
    - size:     1
    - min-rank: 19
  4d2fff67dcaadb5157a1f8706a521942d6995a21
  - rank: 20
  - pow2: 4
  - tail-part:
    - parent: 0a407d122eb2bc0c7813f667ef200eb85bdf2aaa
      - rank: 19
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0a407d122eb2bc0c7813f667ef200eb85bdf2aaa
      - rank:   19
      - pow2:   4
    - size:     1
    - min-rank: 20
  b0da2e5def93963afca89422cb8da022c7c4862b
  - rank: 21
  - pow2: 4
  - tail-part:
    - parent: 4d2fff67dcaadb5157a1f8706a521942d6995a21
      - rank: 20
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 4d2fff67dcaadb5157a1f8706a521942d6995a21
      - rank:   20
      - pow2:   4
    - size:     1
    - min-rank: 21
  cc0a45fefdcf06bee77223a449de16d966c7c21c
  - rank: 22
  - pow2: 4
  - tail-part:
    - parent: b0da2e5def93963afca89422cb8da022c7c4862b
      - rank: 21
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: b0da2e5def93963afca89422cb8da022c7c4862b
      - rank:   21
      - pow2:   4
    - size:     1
    - min-rank: 22
  da839d2d74d4222be3f5f91fec8d16e7d60ef7c9
  - rank: 23
  - pow2: 4
  - tail-part:
    - parent: cc0a45fefdcf06bee77223a449de16d966c7c21c
      - rank: 22
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: cc0a45fefdcf06bee77223a449de16d966c7c21c
      - rank:   22
      - pow2:   4
    - size:     1
    - min-rank: 23
  1428e4757abcd20c75b99852b6bb8ea4cb35f4b4
  - rank: 24
  - pow2: 4
  - tail-part:
    - parent: da839d2d74d4222be3f5f91fec8d16e7d60ef7c9
      - rank: 23
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: da839d2d74d4222be3f5f91fec8d16e7d60ef7c9
      - rank:   23
      - pow2:   4
    - size:     1
    - min-rank: 24
  f38a6729432221aa8b40ca83156c276ee1ae2f40
  - rank: 25
  - pow2: 4
  - tail-part:
    - parent: 1428e4757abcd20c75b99852b6bb8ea4cb35f4b4
      - rank: 24
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 1428e4757abcd20c75b99852b6bb8ea4cb35f4b4
      - rank:   24
      - pow2:   4
    - size:     1
    - min-rank: 25
  d8095d52ea634c8a62fa0546bab3a6fb92658a72
  - rank: 26
  - pow2: 4
  - tail-part:
    - parent: f38a6729432221aa8b40ca83156c276ee1ae2f40
      - rank: 25
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: f38a6729432221aa8b40ca83156c276ee1ae2f40
      - rank:   25
      - pow2:   4
    - size:     1
    - min-rank: 26
  fbcd9661325bda5844f9992ff23d2a97e1a8ce7b
  - rank: 27
  - pow2: 4
  - tail-part:
    - parent: d8095d52ea634c8a62fa0546bab3a6fb92658a72
      - rank: 26
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: d8095d52ea634c8a62fa0546bab3a6fb92658a72
      - rank:   26
      - pow2:   4
    - size:     1
    - min-rank: 27
  7f96560d53a5d252af5862fc264628c72c84fd67
  - rank: 28
  - pow2: 4
  - tail-part:
    - parent: fbcd9661325bda5844f9992ff23d2a97e1a8ce7b
      - rank: 27
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: fbcd9661325bda5844f9992ff23d2a97e1a8ce7b
      - rank:   27
      - pow2:   4
    - size:     1
    - min-rank: 28
  153942671331e165d8ca18a573bf1dbf53a48860
  - rank: 29
  - pow2: 4
  - tail-part:
    - parent: 7f96560d53a5d252af5862fc264628c72c84fd67
      - rank: 28
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 7f96560d53a5d252af5862fc264628c72c84fd67
      - rank:   28
      - pow2:   4
    - size:     1
    - min-rank: 29
  d9d2eab1da91562a054631b8a3c8c7d7256ec589
  - rank: 30
  - pow2: 4
  - tail-part:
    - parent: 153942671331e165d8ca18a573bf1dbf53a48860
      - rank: 29
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 153942671331e165d8ca18a573bf1dbf53a48860
      - rank:   29
      - pow2:   4
    - size:     1
    - min-rank: 30
  cceadba7a2cba010878ffe1cc4b6ae0bb1643e98
  - rank: 31
  - pow2: 4
  - tail-part:
    - parent: d9d2eab1da91562a054631b8a3c8c7d7256ec589
      - rank: 30
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: d9d2eab1da91562a054631b8a3c8c7d7256ec589
      - rank:   30
      - pow2:   4
    - size:     1
    - min-rank: 31
  b48c31cfc5420eea1406101b7d2d25cbe251ae82
  - rank: 32
  - pow2: 5
  - tail-part:
    - parent: cceadba7a2cba010878ffe1cc4b6ae0bb1643e98
      - rank: 31
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     32
    - min-rank: 1
  7725290ba0926459b52b7d0c0f633b3f80888ab1
  - rank: 33
  - pow2: 5
  - tail-part:
    - parent: b48c31cfc5420eea1406101b7d2d25cbe251ae82
      - rank: 32
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: b48c31cfc5420eea1406101b7d2d25cbe251ae82
      - rank:   32
      - pow2:   5
    - size:     1
    - min-rank: 33
  310b633df9021b1e82ea719de116edf269a68bf4
  - rank: 34
  - pow2: 5
  - tail-part:
    - parent: 7725290ba0926459b52b7d0c0f633b3f80888ab1
      - rank: 33
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: 7725290ba0926459b52b7d0c0f633b3f80888ab1
      - rank:   33
      - pow2:   5
    - size:     1
    - min-rank: 34
  b610db345c8126867e4acbeead8768e87b16a236
  - rank: 35
  - pow2: 5
  - tail-part:
    - parent: 310b633df9021b1e82ea719de116edf269a68bf4
      - rank: 34
      - pow2: 5
      - pidx: p1
  - canonical-part:
    - ancestor: 310b633df9021b1e82ea719de116edf269a68bf4
      - rank:   34
      - pow2:   5
    - size:     1
    - min-rank: 35
  2ae05f31d34c7df554dafb1ec53acfe8bc9dcf67
  - rank: 63
  - pow2: 4
  - exclusive-part:
    - parent: 973c306833a5c789251bfb53428783fa6ab4eb5f
      - rank: 34
      - pow2: 5
      - pidx: p1
    - size: 27
    - splits:
      - head:   973c306833a5c789251bfb53428783fa6ab4eb5f
        length: 4
      - head:   c7a710c8dbc77cdbdab486e19f405fd1c3dbde37
        length: 7
      - head:   41a25b4c6272d70e21ded9e984117c93be642867
        length: 16
  - tail-part:
    - parent: b610db345c8126867e4acbeead8768e87b16a236
      - rank: 35
      - pow2: 5
      - pidx: p2
  - canonical-part:
    - ancestor: b610db345c8126867e4acbeead8768e87b16a236
      - rank:   35
      - pow2:   5
    - size:     28
    - min-rank: 3
  b0dfc7fead25654af2320bff92fba054b933625d
  - rank: 64
  - pow2: 6
  - tail-part:
    - parent: 2ae05f31d34c7df554dafb1ec53acfe8bc9dcf67
      - rank: 63
      - pow2: 4
      - pidx: p1
  - canonical-part:
    - ancestor: 0000000000000000000000000000000000000000
    - size:     64
    - min-rank: 1

  $ cd ..
