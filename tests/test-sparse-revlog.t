====================================
Test delta choice with sparse revlog
====================================

#testcases delta-info-flags flagless

Sparse-revlog usually shows the most gain on Manifest. However, it is simpler
to general an appropriate file, so we test with a single file instead. The
goal is to observe intermediate snapshot being created.

We need a large enough file. Part of the content needs to be replaced
repeatedly while some of it changes rarely.

  $ bundlepath="$TESTDIR/artifacts/cache/big-file-churn.hg"

#if pure
  $ expectedhash=`cat "$bundlepath".md5`
  $ if [ ! -f "$bundlepath" ]; then
  >     echo 'skipped: missing artifact, run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"'
  >     exit 80
  > fi
  $ currenthash=`f -M "$bundlepath" | cut -d = -f 2`
  $ if [ "$currenthash" != "$expectedhash" ]; then
  >     echo 'skipped: outdated artifact, md5 "'"$currenthash"'" expected "'"$expectedhash"'" run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"'
  >     exit 80
  > fi
#else

#if slow
  $ LAZY_GEN=""

#else
  $ LAZY_GEN="--lazy"
#endif

#endif

If the validation fails, either something is broken or the expected md5 need updating.
To update the md5, invoke the script without --validate

  $ "$TESTDIR"/artifacts/scripts/generate-churning-bundle.py --validate $LAZY_GEN > /dev/null

  $ cat >> $HGRCPATH << EOF
  > [format]
  > sparse-revlog = yes
  > maxchainlen = 15
  > revlog-compression=zlib
  > [storage]
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta-parent = no
  > revlog.reuse-external-delta = no
  > delta-fold-estimate = always
  > EOF

#if delta-info-flags

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-delta-info-flags=yes
  > EOF

#else

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-delta-info-flags=no
  > EOF

#endif

  $ hg init sparse-repo
  $ cd sparse-repo
  $ hg unbundle $bundlepath
  adding changesets
  adding manifests
  adding file changes
  added 5001 changesets with 5001 changes to 1 files (+89 heads)
  new changesets 9706f5af64f4:3bb1647e55b4 (5001 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "3bb1647e55b4: commit #5000"
  89 other heads for branch "default"

Sanity check the graph shape

  $ hg log -T '{rev} {p1rev} {p2rev}\n' --rev '0:100'
  0 -1 -1
  1 0 -1
  2 1 -1
  3 2 -1
  4 3 -1
  5 4 -1
  6 5 -1
  7 1 -1
  8 7 6
  9 8 -1
  10 9 -1
  11 10 -1
  12 11 -1
  13 12 -1
  14 1 -1
  15 14 -1
  16 15 13
  17 16 -1
  18 17 -1
  19 18 -1
  20 19 -1
  21 16 -1
  22 21 -1
  23 22 -1
  24 23 20
  25 24 -1
  26 25 -1
  27 26 -1
  28 21 -1
  29 28 -1
  30 29 -1
  31 30 -1
  32 31 27
  33 32 -1
  34 33 -1
  35 31 -1
  36 35 -1
  37 36 -1
  38 37 -1
  39 38 -1
  40 39 34
  41 40 -1
  42 36 -1
  43 42 -1
  44 43 -1
  45 44 -1
  46 45 -1
  47 46 -1
  48 47 41
  49 36 -1
  50 49 -1
  51 50 -1
  52 51 -1
  53 52 -1
  54 53 -1
  55 54 -1
  56 51 48
  57 56 -1
  58 57 -1
  59 58 -1
  60 59 -1
  61 60 -1
  62 61 -1
  63 56 -1
  64 63 55
  65 64 -1
  66 65 -1
  67 66 -1
  68 67 -1
  69 68 -1
  70 66 -1
  71 70 -1
  72 71 62
  73 72 -1
  74 73 -1
  75 74 -1
  76 75 -1
  77 71 -1
  78 77 -1
  79 78 -1
  80 79 69
  81 80 -1
  82 81 -1
  83 82 -1
  84 71 -1
  85 84 -1
  86 85 -1
  87 86 -1
  88 87 76
  89 88 -1
  90 89 -1
  91 86 -1
  92 91 -1
  93 92 -1
  94 93 -1
  95 94 -1
  96 95 83
  97 96 -1
  98 91 -1
  99 98 -1
  100 99 -1

sanity check the change pattern

  $ hg log --stat -r 0:3
  changeset:   0:9706f5af64f4
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     initial commit
  
   SPARSE-REVLOG-TEST-FILE |  10500 ++++++++++++++++++++++++++++++++++++++++++++++
   1 files changed, 10500 insertions(+), 0 deletions(-)
  
  changeset:   1:dd93784fb9b5
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #1
  
   SPARSE-REVLOG-TEST-FILE |  170 ++++++++++++++++++++++++------------------------
   1 files changed, 85 insertions(+), 85 deletions(-)
  
  changeset:   2:b808ccb26932
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #2
  
   SPARSE-REVLOG-TEST-FILE |  170 ++++++++++++++++++++++++------------------------
   1 files changed, 85 insertions(+), 85 deletions(-)
  
  changeset:   3:84a5dee52b0e
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #3
  
   SPARSE-REVLOG-TEST-FILE |  164 ++++++++++++++++++++++++------------------------
   1 files changed, 82 insertions(+), 82 deletions(-)
  

#if delta-info-flags
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
#else
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
#endif

  $ hg debugrevlog * > ../revlog-stats-reference.txt

#if delta-info-flags
  $ cat ../revlog-stats-reference.txt
  format : 1
  flags  : generaldelta (flagless !)
  flags  : generaldelta, delta-info (delta-info-flags !)
  
  revisions     :     5001
      merges    :      625 (12.50%)
      normal    :     4376 (87.50%)
  revisions     :     5001
      empty     :        0 ( 0.00%)
                     text  :        0 (100.00%)
                     delta :        0 (100.00%)
      snapshot  :      181 ( 3.62%)
        lvl-0   :              4 ( 0.08%)
        lvl-1   :             20 ( 0.40%)  non-ancestor-bases:        6 (30.00%)
        lvl-2   :             48 ( 0.96%)  non-ancestor-bases:       40 (83.33%)
        lvl-3   :             62 ( 1.24%)  non-ancestor-bases:       58 (93.55%)
        lvl-4   :             35 ( 0.70%)  non-ancestor-bases:       32 (91.43%)
        lvl-5   :              9 ( 0.18%)  non-ancestor-bases:        8 (88.89%)
        lvl-6   :              3 ( 0.06%)  non-ancestor-bases:        3 (100.00%)
      deltas    :     4820 (96.38%)
  revision size : 24793761
      snapshot  :  5239441 (21.13%)
        lvl-0   :         792487 ( 3.20%)
        lvl-1   :        1732118 ( 6.99%)
        lvl-2   :        1534065 ( 6.19%)
        lvl-3   :         869262 ( 3.51%)
        lvl-4   :         267022 ( 1.08%)
        lvl-5   :          35903 ( 0.14%)
        lvl-6   :           8584 ( 0.03%)
      deltas    : 19554320 (78.87%)
  
  chunks        :     5001
      0x78 (x)  :     5001 (100.00%)
  chunks size   : 24793761
      0x78 (x)  : 24793761 (100.00%)
  
  
  total-stored-content: 1 714 759 864 bytes
  
  avg chain length  :        8
  max chain length  :       15
  max chain reach   : 15610952
  compression ratio :       69
  
  uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  full revision size (min/max/avg)     : 196798 / 201050 / 198121
  inter-snapshot size (min/max/avg)    : 2315 / 170286 / 25124
      level-1   (min/max/avg)          : 8696 / 170286 / 86605
      level-2   (min/max/avg)          : 3130 / 83837 / 31959
      level-3   (min/max/avg)          : 2315 / 40986 / 14020
      level-4   (min/max/avg)          : 2573 / 20787 / 7629
      level-5   (min/max/avg)          : 2645 / 9784 / 3989
      level-6   (min/max/avg)          : 2632 / 3095 / 2861
  delta size (min/max/avg)             : 1650 / 178066 / 4056
  
  deltas against prev  : 1972 (40.91%)
      where prev = p1  : 1972     (100.00%)
      where prev = p2  :    0     ( 0.00%)
      other-ancestor   :    0     ( 0.00%)
      unrelated        :    0     ( 0.00%)
  deltas against p1    :  661 (13.71%)
  deltas against p2    :   11 ( 0.23%)
  deltas against ancs  :    0 ( 0.00%)
  deltas against other : 2176 (45.15%)
#else
  $ cat ../revlog-stats-reference.txt
  format : 1
  flags  : generaldelta (flagless !)
  flags  : generaldelta, delta-info (delta-info-flags !)
  
  revisions     :     5001
      merges    :      625 (12.50%)
      normal    :     4376 (87.50%)
  revisions     :     5001
      empty     :        0 ( 0.00%)
                     text  :        0 (100.00%)
                     delta :        0 (100.00%)
      snapshot  :      409 ( 8.18%)
        lvl-0   :              4 ( 0.08%)
        lvl-1   :             26 ( 0.52%)  non-ancestor-bases:       10 (38.46%)
        lvl-2   :             63 ( 1.26%)  non-ancestor-bases:       55 (87.30%)
        lvl-3   :            108 ( 2.16%)  non-ancestor-bases:       99 (91.67%)
        lvl-4   :            112 ( 2.24%)  non-ancestor-bases:      108 (96.43%)
        lvl-5   :             73 ( 1.46%)  non-ancestor-bases:       70 (95.89%)
        lvl-6   :             23 ( 0.46%)  non-ancestor-bases:       23 (100.00%)
      deltas    :     4592 (91.82%)
  revision size : 28502223
      snapshot  :  7714756 (27.07%)
        lvl-0   :         792946 ( 2.78%)
        lvl-1   :        1766164 ( 6.20%)
        lvl-2   :        1883372 ( 6.61%)
        lvl-3   :        1811191 ( 6.35%)
        lvl-4   :         973815 ( 3.42%)
        lvl-5   :         407078 ( 1.43%)
        lvl-6   :          80190 ( 0.28%)
      deltas    : 20787467 (72.93%)
  
  chunks        :     5001
      0x78 (x)  :     5001 (100.00%)
  chunks size   : 28502223
      0x78 (x)  : 28502223 (100.00%)
  
  
  total-stored-content: 1 714 759 864 bytes
  
  avg chain length  :        9
  max chain length  :       15
  max chain reach   : 16988366
  compression ratio :       60
  
  uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  full revision size (min/max/avg)     : 196940 / 201050 / 198236
  inter-snapshot size (min/max/avg)    : 2297 / 164378 / 17090
      level-1   (min/max/avg)          : 2836 / 164378 / 67929
      level-2   (min/max/avg)          : 2336 / 84403 / 29894
      level-3   (min/max/avg)          : 2306 / 42184 / 16770
      level-4   (min/max/avg)          : 2450 / 21280 / 8694
      level-5   (min/max/avg)          : 2305 / 10590 / 5576
      level-6   (min/max/avg)          : 2297 / 5208 / 3486
  delta size (min/max/avg)             : 1650 / 173247 / 4526
  
  deltas against prev  : 3865 (84.17%)
      where prev = p1  : 3865     (100.00%)
      where prev = p2  :    0     ( 0.00%)
      other-ancestor   :    0     ( 0.00%)
      unrelated        :    0     ( 0.00%)
  deltas against p1    :  645 (14.05%)
  deltas against p2    :   82 ( 1.79%)
  deltas against ancs  :    0 ( 0.00%)
  deltas against other :    0 ( 0.00%)
#endif


Test `debug-delta-find`
-----------------------

  $ ls -1
  SPARSE-REVLOG-TEST-FILE
#if delta-info-flags
  $ hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1
     4964    4963      -1       4        4     4958    snap
  $ LAST_SNAP=`hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1| sed 's/^ *//'| cut -d ' ' -f 1`
  $ echo Last Snapshot: $LAST_SNAP
  Last Snapshot: 4964
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP
  DBG-DELTAS-SEARCH: SEARCH rev=4964
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
#else
  $ hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1
     4966    4965      -1       4        4     4962    snap
  $ LAST_SNAP=`hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1| sed 's/^ *//'| cut -d ' ' -f 1`
  $ echo Last Snapshot: $LAST_SNAP
  Last Snapshot: 4966
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP
  DBG-DELTAS-SEARCH: SEARCH rev=4966
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4929
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=7805
  DBG-DELTAS-SEARCH:     base=4919
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=46750
  DBG-DELTAS-SEARCH:     projected-lower-size=4675
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=28543 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4919
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=42127
  DBG-DELTAS-SEARCH:     base=4833
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=52885
  DBG-DELTAS-SEARCH:     projected-lower-size=5288
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=32239 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4833
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=53375
  DBG-DELTAS-SEARCH:     base=4738
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=103267
  DBG-DELTAS-SEARCH:     projected-lower-size=10326
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=62267 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4962 - length=7918
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4913
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=112050
  DBG-DELTAS-SEARCH:     base=4651
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=73877
  DBG-DELTAS-SEARCH:     projected-lower-size=7387
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=69566
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=42257 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
#endif

  $ cat << EOF >>.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = no
  > revlog.reuse-external-delta = yes
  > EOF

#if delta-info-flags
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --quiet
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source full
  DBG-DELTAS-SEARCH: SEARCH rev=4964
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source storage
  DBG-DELTAS-SEARCH: SEARCH rev=4964 (cached=4958)
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - cached-delta
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=1 - search-rounds=1 try-count=1 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p1
  DBG-DELTAS-SEARCH: SEARCH rev=4964 (cached=4963)
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p1
  DBG-DELTAS-SEARCH: SEARCH rev=4964 (cached=4963)
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p2
  DBG-DELTAS-SEARCH: SEARCH rev=4964
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source prev
  DBG-DELTAS-SEARCH: SEARCH rev=4964 (cached=4963)
  DBG-DELTAS-SEARCH: ROUND #1 - 3 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4243
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=3666
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304723
  DBG-DELTAS-SEARCH:     projected-lower-size=30472
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4250
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=4849
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=303892
  DBG-DELTAS-SEARCH:     projected-lower-size=30389
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4303
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=26270
  DBG-DELTAS-SEARCH:     base=4238
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=297409
  DBG-DELTAS-SEARCH:     projected-lower-size=29740
  DBG-DELTAS-SEARCH:     DISCARDED (snapshot limit)
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     NO-DELTA
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4238
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=33685
  DBG-DELTAS-SEARCH:     base=4171
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=304942
  DBG-DELTAS-SEARCH:     projected-lower-size=30494
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=180439 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=10488
  DBG-DELTAS-SEARCH:     base=4948
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=8672
  DBG-DELTAS-SEARCH:     projected-lower-size=867
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=5312 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4958 - length=5312
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4948
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=83136
  DBG-DELTAS-SEARCH:     base=4769
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     projected-lower-size=2069
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=20696
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12621 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4964: delta-base=4958 is-cached=0 - search-rounds=3 try-count=6 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
#else
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --quiet
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source full
  DBG-DELTAS-SEARCH: SEARCH rev=4966
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4929
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=7805
  DBG-DELTAS-SEARCH:     base=4919
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=46750
  DBG-DELTAS-SEARCH:     projected-lower-size=4675
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=28543 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4919
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=42127
  DBG-DELTAS-SEARCH:     base=4833
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=52885
  DBG-DELTAS-SEARCH:     projected-lower-size=5288
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=32239 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4833
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=53375
  DBG-DELTAS-SEARCH:     base=4738
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=103267
  DBG-DELTAS-SEARCH:     projected-lower-size=10326
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=62267 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4962 - length=7918
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4913
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=112050
  DBG-DELTAS-SEARCH:     base=4651
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=73877
  DBG-DELTAS-SEARCH:     projected-lower-size=7387
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=69566
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=42257 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source storage
  DBG-DELTAS-SEARCH: SEARCH rev=4966 (cached=4962)
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - cached-delta
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=1 - search-rounds=1 try-count=1 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p1
  DBG-DELTAS-SEARCH: SEARCH rev=4966 (cached=4965)
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4929
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=7805
  DBG-DELTAS-SEARCH:     base=4919
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=46750
  DBG-DELTAS-SEARCH:     projected-lower-size=4675
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=28543 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4919
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=42127
  DBG-DELTAS-SEARCH:     base=4833
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=52885
  DBG-DELTAS-SEARCH:     projected-lower-size=5288
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=32239 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4833
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=53375
  DBG-DELTAS-SEARCH:     base=4738
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=103267
  DBG-DELTAS-SEARCH:     projected-lower-size=10326
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=62267 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4962 - length=7918
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4913
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=112050
  DBG-DELTAS-SEARCH:     base=4651
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=73877
  DBG-DELTAS-SEARCH:     projected-lower-size=7387
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=69566
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=42257 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p2
  DBG-DELTAS-SEARCH: SEARCH rev=4966
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4929
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=7805
  DBG-DELTAS-SEARCH:     base=4919
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=46750
  DBG-DELTAS-SEARCH:     projected-lower-size=4675
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=28543 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4919
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=42127
  DBG-DELTAS-SEARCH:     base=4833
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=52885
  DBG-DELTAS-SEARCH:     projected-lower-size=5288
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=32239 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4833
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=53375
  DBG-DELTAS-SEARCH:     base=4738
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=103267
  DBG-DELTAS-SEARCH:     projected-lower-size=10326
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=62267 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4962 - length=7918
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4913
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=112050
  DBG-DELTAS-SEARCH:     base=4651
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=73877
  DBG-DELTAS-SEARCH:     projected-lower-size=7387
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=69566
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=42257 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source prev
  DBG-DELTAS-SEARCH: SEARCH rev=4966 (cached=4965)
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4929
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=7805
  DBG-DELTAS-SEARCH:     base=4919
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=46750
  DBG-DELTAS-SEARCH:     projected-lower-size=4675
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=28543 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4919
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=42127
  DBG-DELTAS-SEARCH:     base=4833
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=52885
  DBG-DELTAS-SEARCH:     projected-lower-size=5288
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=32239 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 2 candidates - search-down (snapshot)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4833
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=53375
  DBG-DELTAS-SEARCH:     base=4738
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=103267
  DBG-DELTAS-SEARCH:     projected-lower-size=10326
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=62267 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4962
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=44069
  DBG-DELTAS-SEARCH:     base=4913
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=13015
  DBG-DELTAS-SEARCH:     projected-lower-size=1301
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=7918 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down (snapshot)
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4962 - length=7918
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4913
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=112050
  DBG-DELTAS-SEARCH:     base=4651
  DBG-DELTAS-SEARCH:     estimated-uncompressed-delta-size=73877
  DBG-DELTAS-SEARCH:     projected-lower-size=7387
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=69566
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=42257 (BIGGER)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4966: delta-base=4962 is-cached=0 - search-rounds=4 try-count=5 - delta-type=snapshot snap-depth=3 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
#endif

  $ cat << EOF >>.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta = no
  > EOF

Upgrading to/from delta-info-flags
==================================

#if delta-info-flags
  $ UPGRADE_TO=no
#else
  $ UPGRADE_TO=yes
#endif

  $ hg debugrevlog * > ../revlog-stats-pre-upgrade.txt
  $ hg debugupgraderepo --quiet --run \
  >   --optimize re-delta-all \
  >   --config format.exp-use-delta-info-flags=$UPGRADE_TO
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: exp-delta-info-revlog (delta-info-flags !)
     added: exp-delta-info-revlog (flagless !)
  
  optimisations: re-delta-all
  
  processed revlogs:
    - all-filelogs
    - changelog
    - manifest
  
  $ hg verify --quiet
  $ hg debugrevlog * > ../revlog-stats-post-upgrade.txt

#if delta-info-flags
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
  $ cmp ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt | diff -u ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta, delta-info
  +flags  : generaldelta
   
   revisions     :     5001
       merges    :      625 (12.50%)
  @@ -8,56 +8,56 @@
       empty     :        0 ( 0.00%)
                      text  :        0 (100.00%)
                      delta :        0 (100.00%)
  -    snapshot  :      181 ( 3.62%)
  +    snapshot  :      409 ( 8.18%)
         lvl-0   :              4 ( 0.08%)
  -      lvl-1   :             20 ( 0.40%)  non-ancestor-bases:        6 (30.00%)
  -      lvl-2   :             48 ( 0.96%)  non-ancestor-bases:       40 (83.33%)
  -      lvl-3   :             62 ( 1.24%)  non-ancestor-bases:       58 (93.55%)
  -      lvl-4   :             35 ( 0.70%)  non-ancestor-bases:       32 (91.43%)
  -      lvl-5   :              9 ( 0.18%)  non-ancestor-bases:        8 (88.89%)
  -      lvl-6   :              3 ( 0.06%)  non-ancestor-bases:        3 (100.00%)
  -    deltas    :     4820 (96.38%)
  -revision size : 24793761
  -    snapshot  :  5239441 (21.13%)
  -      lvl-0   :         792487 ( 3.20%)
  -      lvl-1   :        1732118 ( 6.99%)
  -      lvl-2   :        1534065 ( 6.19%)
  -      lvl-3   :         869262 ( 3.51%)
  -      lvl-4   :         267022 ( 1.08%)
  -      lvl-5   :          35903 ( 0.14%)
  -      lvl-6   :           8584 ( 0.03%)
  -    deltas    : 19554320 (78.87%)
  +      lvl-1   :             26 ( 0.52%)  non-ancestor-bases:       10 (38.46%)
  +      lvl-2   :             63 ( 1.26%)  non-ancestor-bases:       55 (87.30%)
  +      lvl-3   :            108 ( 2.16%)  non-ancestor-bases:       99 (91.67%)
  +      lvl-4   :            112 ( 2.24%)  non-ancestor-bases:      108 (96.43%)
  +      lvl-5   :             73 ( 1.46%)  non-ancestor-bases:       70 (95.89%)
  +      lvl-6   :             23 ( 0.46%)  non-ancestor-bases:       23 (100.00%)
  +    deltas    :     4592 (91.82%)
  +revision size : 28502223
  +    snapshot  :  7714756 (27.07%)
  +      lvl-0   :         792946 ( 2.78%)
  +      lvl-1   :        1766164 ( 6.20%)
  +      lvl-2   :        1883372 ( 6.61%)
  +      lvl-3   :        1811191 ( 6.35%)
  +      lvl-4   :         973815 ( 3.42%)
  +      lvl-5   :         407078 ( 1.43%)
  +      lvl-6   :          80190 ( 0.28%)
  +    deltas    : 20787467 (72.93%)
   
   chunks        :     5001
       0x78 (x)  :     5001 (100.00%)
  -chunks size   : 24793761
  -    0x78 (x)  : 24793761 (100.00%)
  +chunks size   : 28502223
  +    0x78 (x)  : 28502223 (100.00%)
   
   
   total-stored-content: 1 714 759 864 bytes
   
  -avg chain length  :        8
  +avg chain length  :        9
   max chain length  :       15
  -max chain reach   : 15610952
  -compression ratio :       69
  +max chain reach   : 16988366
  +compression ratio :       60
   
   uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  -full revision size (min/max/avg)     : 196798 / 201050 / 198121
  -inter-snapshot size (min/max/avg)    : 2315 / 170286 / 25124
  -    level-1   (min/max/avg)          : 8696 / 170286 / 86605
  -    level-2   (min/max/avg)          : 3130 / 83837 / 31959
  -    level-3   (min/max/avg)          : 2315 / 40986 / 14020
  -    level-4   (min/max/avg)          : 2573 / 20787 / 7629
  -    level-5   (min/max/avg)          : 2645 / 9784 / 3989
  -    level-6   (min/max/avg)          : 2632 / 3095 / 2861
  -delta size (min/max/avg)             : 1650 / 178066 / 4056
  +full revision size (min/max/avg)     : 196940 / 201050 / 198236
  +inter-snapshot size (min/max/avg)    : 2297 / 164378 / 17090
  +    level-1   (min/max/avg)          : 2836 / 164378 / 67929
  +    level-2   (min/max/avg)          : 2336 / 84403 / 29894
  +    level-3   (min/max/avg)          : 2306 / 42184 / 16770
  +    level-4   (min/max/avg)          : 2450 / 21280 / 8694
  +    level-5   (min/max/avg)          : 2305 / 10590 / 5576
  +    level-6   (min/max/avg)          : 2297 / 5208 / 3486
  +delta size (min/max/avg)             : 1650 / 173247 / 4526
   
  -deltas against prev  : 1972 (40.91%)
  -    where prev = p1  : 1972     (100.00%)
  +deltas against prev  : 3865 (84.17%)
  +    where prev = p1  : 3865     (100.00%)
       where prev = p2  :    0     ( 0.00%)
       other-ancestor   :    0     ( 0.00%)
       unrelated        :    0     ( 0.00%)
  -deltas against p1    :  661 (13.71%)
  -deltas against p2    :   11 ( 0.23%)
  +deltas against p1    :  645 (14.05%)
  +deltas against p2    :   82 ( 1.79%)
   deltas against ancs  :    0 ( 0.00%)
  -deltas against other : 2176 (45.15%)
  +deltas against other :    0 ( 0.00%)
  [1]
#else
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
  $ cmp ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt | diff -u ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta
  +flags  : generaldelta, delta-info
   
   revisions     :     5001
       merges    :      625 (12.50%)
  @@ -8,56 +8,56 @@
       empty     :        0 ( 0.00%)
                      text  :        0 (100.00%)
                      delta :        0 (100.00%)
  -    snapshot  :      409 ( 8.18%)
  +    snapshot  :      181 ( 3.62%)
         lvl-0   :              4 ( 0.08%)
  -      lvl-1   :             26 ( 0.52%)  non-ancestor-bases:       10 (38.46%)
  -      lvl-2   :             63 ( 1.26%)  non-ancestor-bases:       55 (87.30%)
  -      lvl-3   :            108 ( 2.16%)  non-ancestor-bases:       99 (91.67%)
  -      lvl-4   :            112 ( 2.24%)  non-ancestor-bases:      108 (96.43%)
  -      lvl-5   :             73 ( 1.46%)  non-ancestor-bases:       70 (95.89%)
  -      lvl-6   :             23 ( 0.46%)  non-ancestor-bases:       23 (100.00%)
  -    deltas    :     4592 (91.82%)
  -revision size : 28502223
  -    snapshot  :  7714756 (27.07%)
  -      lvl-0   :         792946 ( 2.78%)
  -      lvl-1   :        1766164 ( 6.20%)
  -      lvl-2   :        1883372 ( 6.61%)
  -      lvl-3   :        1811191 ( 6.35%)
  -      lvl-4   :         973815 ( 3.42%)
  -      lvl-5   :         407078 ( 1.43%)
  -      lvl-6   :          80190 ( 0.28%)
  -    deltas    : 20787467 (72.93%)
  +      lvl-1   :             20 ( 0.40%)  non-ancestor-bases:        6 (30.00%)
  +      lvl-2   :             48 ( 0.96%)  non-ancestor-bases:       40 (83.33%)
  +      lvl-3   :             62 ( 1.24%)  non-ancestor-bases:       58 (93.55%)
  +      lvl-4   :             35 ( 0.70%)  non-ancestor-bases:       32 (91.43%)
  +      lvl-5   :              9 ( 0.18%)  non-ancestor-bases:        8 (88.89%)
  +      lvl-6   :              3 ( 0.06%)  non-ancestor-bases:        3 (100.00%)
  +    deltas    :     4820 (96.38%)
  +revision size : 24793761
  +    snapshot  :  5239441 (21.13%)
  +      lvl-0   :         792487 ( 3.20%)
  +      lvl-1   :        1732118 ( 6.99%)
  +      lvl-2   :        1534065 ( 6.19%)
  +      lvl-3   :         869262 ( 3.51%)
  +      lvl-4   :         267022 ( 1.08%)
  +      lvl-5   :          35903 ( 0.14%)
  +      lvl-6   :           8584 ( 0.03%)
  +    deltas    : 19554320 (78.87%)
   
   chunks        :     5001
       0x78 (x)  :     5001 (100.00%)
  -chunks size   : 28502223
  -    0x78 (x)  : 28502223 (100.00%)
  +chunks size   : 24793761
  +    0x78 (x)  : 24793761 (100.00%)
   
   
   total-stored-content: 1 714 759 864 bytes
   
  -avg chain length  :        9
  +avg chain length  :        8
   max chain length  :       15
  -max chain reach   : 16988366
  -compression ratio :       60
  +max chain reach   : 15610952
  +compression ratio :       69
   
   uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  -full revision size (min/max/avg)     : 196940 / 201050 / 198236
  -inter-snapshot size (min/max/avg)    : 2297 / 164378 / 17090
  -    level-1   (min/max/avg)          : 2836 / 164378 / 67929
  -    level-2   (min/max/avg)          : 2336 / 84403 / 29894
  -    level-3   (min/max/avg)          : 2306 / 42184 / 16770
  -    level-4   (min/max/avg)          : 2450 / 21280 / 8694
  -    level-5   (min/max/avg)          : 2305 / 10590 / 5576
  -    level-6   (min/max/avg)          : 2297 / 5208 / 3486
  -delta size (min/max/avg)             : 1650 / 173247 / 4526
  +full revision size (min/max/avg)     : 196798 / 201050 / 198121
  +inter-snapshot size (min/max/avg)    : 2315 / 170286 / 25124
  +    level-1   (min/max/avg)          : 8696 / 170286 / 86605
  +    level-2   (min/max/avg)          : 3130 / 83837 / 31959
  +    level-3   (min/max/avg)          : 2315 / 40986 / 14020
  +    level-4   (min/max/avg)          : 2573 / 20787 / 7629
  +    level-5   (min/max/avg)          : 2645 / 9784 / 3989
  +    level-6   (min/max/avg)          : 2632 / 3095 / 2861
  +delta size (min/max/avg)             : 1650 / 178066 / 4056
   
  -deltas against prev  : 3865 (84.17%)
  -    where prev = p1  : 3865     (100.00%)
  +deltas against prev  : 1972 (40.91%)
  +    where prev = p1  : 1972     (100.00%)
       where prev = p2  :    0     ( 0.00%)
       other-ancestor   :    0     ( 0.00%)
       unrelated        :    0     ( 0.00%)
  -deltas against p1    :  645 (14.05%)
  -deltas against p2    :   82 ( 1.79%)
  +deltas against p1    :  661 (13.71%)
  +deltas against p2    :   11 ( 0.23%)
   deltas against ancs  :    0 ( 0.00%)
  -deltas against other :    0 ( 0.00%)
  +deltas against other : 2176 (45.15%)
  [1]
#endif

  $ cd ..
