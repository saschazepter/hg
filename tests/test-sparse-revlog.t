====================================
Test delta choice with sparse revlog
====================================

Sparse-revlog usually shows the most gain on Manifest. However, it is simpler
to general an appropriate file, so we test with a single file instead. The
goal is to observe intermediate snapshot being created.

We need a large enough file. Part of the content needs to be replaced
repeatedly while some of it changes rarely.

  $ bundlepath="$TESTDIR/artifacts/cache/big-file-churn.hg"

  $ expectedhash=`cat "$bundlepath".md5`

#if slow

  $ if [ ! -f "$bundlepath" ]; then
  >     "$TESTDIR"/artifacts/scripts/generate-churning-bundle.py > /dev/null
  > fi

#else

  $ if [ ! -f "$bundlepath" ]; then
  >     echo 'skipped: missing artifact, run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"'
  >     exit 80
  > fi

#endif

  $ currenthash=`f -M "$bundlepath" | cut -d = -f 2`
  $ if [ "$currenthash" != "$expectedhash" ]; then
  >     echo 'skipped: outdated artifact, md5 "'"$currenthash"'" expected "'"$expectedhash"'" run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"'
  >     exit 80
  > fi

  $ cat >> $HGRCPATH << EOF
  > [format]
  > sparse-revlog = yes
  > maxchainlen = 15
  > revlog-compression=zlib
  > [storage]
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta = no
  > EOF
  $ hg init sparse-repo
  $ cd sparse-repo
  $ hg unbundle $bundlepath
  adding changesets
  adding manifests
  adding file changes
  added 5001 changesets with 5001 changes to 1 files (+89 heads)
  new changesets 9706f5af64f4:d9032adc8114 (5001 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "d9032adc8114: commit #5000"
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
  
  changeset:   1:724907deaa5e
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #1
  
   SPARSE-REVLOG-TEST-FILE |  1068 +++++++++++++++++++++++-----------------------
   1 files changed, 534 insertions(+), 534 deletions(-)
  
  changeset:   2:62c41bce3e5d
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #2
  
   SPARSE-REVLOG-TEST-FILE |  1068 +++++++++++++++++++++++-----------------------
   1 files changed, 534 insertions(+), 534 deletions(-)
  
  changeset:   3:348a9cbd6959
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     commit #3
  
   SPARSE-REVLOG-TEST-FILE |  1068 +++++++++++++++++++++++-----------------------
   1 files changed, 534 insertions(+), 534 deletions(-)
  

  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=63327412
  $ hg debugrevlog *
  format : 1
  flags  : generaldelta
  
  revisions     :     5001
      merges    :      625 (12.50%)
      normal    :     4376 (87.50%)
  revisions     :     5001
      empty     :        0 ( 0.00%)
                     text  :        0 (100.00%)
                     delta :        0 (100.00%)
      snapshot  :      383 ( 7.66%)
        lvl-0   :              3 ( 0.06%)
        lvl-1   :             20 ( 0.40%)  non-ancestor-bases:       13 (65.00%)
        lvl-2   :             68 ( 1.36%)  non-ancestor-bases:       64 (94.12%)
        lvl-3   :            112 ( 2.24%)  non-ancestor-bases:      112 (100.00%)
        lvl-4   :            180 ( 3.60%)  non-ancestor-bases:      180 (100.00%)
      deltas    :     4618 (92.34%)
  revision size : 63327412
      snapshot  :  9886710 (15.61%)
        lvl-0   :         603104 ( 0.95%)
        lvl-1   :        1559991 ( 2.46%)
        lvl-2   :        2295592 ( 3.62%)
        lvl-3   :        2531199 ( 4.00%)
        lvl-4   :        2896824 ( 4.57%)
      deltas    : 53440702 (84.39%)
  
  chunks        :     5001
      0x78 (x)  :     5001 (100.00%)
  chunks size   : 63327412
      0x78 (x)  : 63327412 (100.00%)
  
  
  total-stored-content: 1 732 705 361 bytes
  
  avg chain length  :        9
  max chain length  :       15
  max chain reach   : 28248745
  compression ratio :       27
  
  uncompressed data size (min/max/avg) : 346468 / 346472 / 346471
  full revision size (min/max/avg)     : 201008 / 201050 / 201034
  inter-snapshot size (min/max/avg)    : 11596 / 168150 / 24430
      level-1   (min/max/avg)          : 16653 / 168150 / 77999
      level-2   (min/max/avg)          : 12951 / 85595 / 33758
      level-3   (min/max/avg)          : 11608 / 43029 / 22599
      level-4   (min/max/avg)          : 11596 / 21632 / 16093
  delta size (min/max/avg)             : 10649 / 107163 / 11572
  
  deltas against prev  : 3910 (84.67%)
      where prev = p1  : 3910     (100.00%)
      where prev = p2  :    0     ( 0.00%)
      other-ancestor   :    0     ( 0.00%)
      unrelated        :    0     ( 0.00%)
  deltas against p1    :  648 (14.03%)
  deltas against p2    :   60 ( 1.30%)
  deltas against ancs  :    0 ( 0.00%)
  deltas against other :    0 ( 0.00%)


Test `debug-delta-find`
-----------------------

  $ ls -1
  SPARSE-REVLOG-TEST-FILE
  $ hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1
     4999    4998      -1       3        5     4982    snap
  $ LAST_SNAP=`hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1| sed 's/^ \+//'| cut -d ' ' -f 1`
  $ echo Last Snapshot: $LAST_SNAP
  Last Snapshot: 4999
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4989
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18293
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=24239
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=14602 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4993
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18588
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=21665
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12983 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4951
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=14295
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=33050
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=20146 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4982 - length=18912
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4939
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=85389
  DBG-DELTAS-SEARCH:     base=4591
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=40376
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=24686 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)

  $ cat << EOF >>.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = no
  > revlog.reuse-external-delta = yes
  > EOF

  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --quiet
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source full
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4989
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18293
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=24239
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=14602 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4993
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18588
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=21665
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12983 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4951
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=14295
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=33050
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=20146 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4982 - length=18912
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4939
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=85389
  DBG-DELTAS-SEARCH:     base=4591
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=40376
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=24686 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source storage
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - cached-delta
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=1 - search-rounds=1 try-count=1 - delta-type=delta  snap-depth=-1 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p1
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4989
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18293
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=24239
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=14602 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4993
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18588
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=21665
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12983 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4951
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=14295
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=33050
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=20146 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4982 - length=18912
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4939
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=85389
  DBG-DELTAS-SEARCH:     base=4591
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=40376
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=24686 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p2
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4989
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18293
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=24239
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=14602 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4993
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18588
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=21665
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12983 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4951
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=14295
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=33050
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=20146 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4982 - length=18912
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4939
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=85389
  DBG-DELTAS-SEARCH:     base=4591
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=40376
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=24686 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source prev
  DBG-DELTAS-SEARCH: SEARCH rev=4999
  DBG-DELTAS-SEARCH: ROUND #1 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4989
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18293
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=24239
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=14602 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4993
  DBG-DELTAS-SEARCH:     type=snapshot-4
  DBG-DELTAS-SEARCH:     size=18588
  DBG-DELTAS-SEARCH:     base=4982
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=21665
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=12983 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 2 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4951
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=14295
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=33050
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=20146 (BAD)
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4982
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=24115
  DBG-DELTAS-SEARCH:     base=4939
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=31169
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=18912 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4982 - length=18912
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4939
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=85389
  DBG-DELTAS-SEARCH:     base=4591
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=40376
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=24686 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4999: delta-base=4982 is-cached=0 - search-rounds=3 try-count=5 - delta-type=snapshot snap-depth=4 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)

  $ cd ..
