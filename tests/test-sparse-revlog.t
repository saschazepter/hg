====================================
Test delta choice with sparse revlog
====================================

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
  > EOF
  $ hg init sparse-repo
  $ cd sparse-repo
  $ hg unbundle $bundlepath
  adding changesets
  adding manifests
  adding file changes
  added 5001 changesets with 5001 changes to 1 files (+89 heads)
  new changesets 9706f5af64f4:e4eee5e41c37 (5001 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "e4eee5e41c37: commit #5000"
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
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=81370673
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
      snapshot  :      360 ( 7.20%)
        lvl-0   :             11 ( 0.22%)
        lvl-1   :             50 ( 1.00%)  non-ancestor-bases:       41 (82.00%)
        lvl-2   :            128 ( 2.56%)  non-ancestor-bases:      119 (92.97%)
        lvl-3   :            122 ( 2.44%)  non-ancestor-bases:      111 (90.98%)
        lvl-4   :             49 ( 0.98%)  non-ancestor-bases:       46 (93.88%)
      deltas    :     4641 (92.80%)
  revision size : 81370673
      snapshot  : 16282100 (20.01%)
        lvl-0   :        2188012 ( 2.69%)
        lvl-1   :        4848143 ( 5.96%)
        lvl-2   :        5366175 ( 6.59%)
        lvl-3   :        3085157 ( 3.79%)
        lvl-4   :         794613 ( 0.98%)
      deltas    : 65088573 (79.99%)
  
  chunks        :     5001
      0x78 (x)  :     5001 (100.00%)
  chunks size   : 81370673
      0x78 (x)  : 81370673 (100.00%)
  
  
  total-stored-content: 1 717 863 086 bytes
  
  avg chain length  :        8
  max chain length  :       15
  max chain reach   : 18326506
  compression ratio :       21
  
  uncompressed data size (min/max/avg) : 339930 / 346471 / 343503
  full revision size (min/max/avg)     : 196682 / 201129 / 198910
  inter-snapshot size (min/max/avg)    : 11620 / 172223 / 40384
      level-1   (min/max/avg)          : 14329 / 172223 / 96962
      level-2   (min/max/avg)          : 11664 / 86421 / 41923
      level-3   (min/max/avg)          : 11620 / 42674 / 25288
      level-4   (min/max/avg)          : 11631 / 21209 / 16216
  delta size (min/max/avg)             : 10610 / 190651 / 14024
  
  deltas against prev  : 3916 (84.38%)
      where prev = p1  : 3916     (100.00%)
      where prev = p2  :    0     ( 0.00%)
      other-ancestor   :    0     ( 0.00%)
      unrelated        :    0     ( 0.00%)
  deltas against p1    :  667 (14.37%)
  deltas against p2    :   58 ( 1.25%)
  deltas against ancs  :    0 ( 0.00%)
  deltas against other :    0 ( 0.00%)


Test `debug-delta-find`
-----------------------

  $ ls -1
  SPARSE-REVLOG-TEST-FILE
  $ hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1
     4996    4995      -1      11        3     4947    snap
  $ LAST_SNAP=`hg debugdeltachain SPARSE-REVLOG-TEST-FILE | grep snap | tail -1| sed 's/^ *//'| cut -d ' ' -f 1`
  $ echo Last Snapshot: $LAST_SNAP
  Last Snapshot: 4996
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4964
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=15153
  DBG-DELTAS-SEARCH:     base=4958
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36297 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=30977
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36578 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4667
  DBG-DELTAS-SEARCH:     type=snapshot-0
  DBG-DELTAS-SEARCH:     size=196699
  DBG-DELTAS-SEARCH:     base=-1
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=281309
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=165408 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #5 - 1 candidates - refine-up
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4954
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=58198
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=92195
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=54601 (BAD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)

  $ cat << EOF >>.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = no
  > revlog.reuse-external-delta = yes
  > EOF

  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --quiet
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source full
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4964
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=15153
  DBG-DELTAS-SEARCH:     base=4958
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36297 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=30977
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36578 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4667
  DBG-DELTAS-SEARCH:     type=snapshot-0
  DBG-DELTAS-SEARCH:     size=196699
  DBG-DELTAS-SEARCH:     base=-1
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=281309
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=165408 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #5 - 1 candidates - refine-up
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4954
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=58198
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=92195
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=54601 (BAD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source storage
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - cached-delta
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=1 - search-rounds=1 try-count=1 - delta-type=delta  snap-depth=-1 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p1
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4964
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=15153
  DBG-DELTAS-SEARCH:     base=4958
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36297 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=30977
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36578 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4667
  DBG-DELTAS-SEARCH:     type=snapshot-0
  DBG-DELTAS-SEARCH:     size=196699
  DBG-DELTAS-SEARCH:     base=-1
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=281309
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=165408 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #5 - 1 candidates - refine-up
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4954
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=58198
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=92195
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=54601 (BAD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source p2
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4964
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=15153
  DBG-DELTAS-SEARCH:     base=4958
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36297 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=30977
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36578 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4667
  DBG-DELTAS-SEARCH:     type=snapshot-0
  DBG-DELTAS-SEARCH:     size=196699
  DBG-DELTAS-SEARCH:     base=-1
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=281309
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=165408 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #5 - 1 candidates - refine-up
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4954
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=58198
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=92195
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=54601 (BAD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)
  $ hg debug-delta-find SPARSE-REVLOG-TEST-FILE $LAST_SNAP --source prev
  DBG-DELTAS-SEARCH: SEARCH rev=4996
  DBG-DELTAS-SEARCH: ROUND #1 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4964
  DBG-DELTAS-SEARCH:     type=snapshot-3
  DBG-DELTAS-SEARCH:     size=15153
  DBG-DELTAS-SEARCH:     base=4958
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36297 (BAD)
  DBG-DELTAS-SEARCH: ROUND #2 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4958
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=30977
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=61571
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=36578 (BAD)
  DBG-DELTAS-SEARCH: ROUND #3 - 1 candidates - search-down
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4947
  DBG-DELTAS-SEARCH:     type=snapshot-1
  DBG-DELTAS-SEARCH:     size=164878
  DBG-DELTAS-SEARCH:     base=4667
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=87938
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=52101 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #4 - 1 candidates - refine-down
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4667
  DBG-DELTAS-SEARCH:     type=snapshot-0
  DBG-DELTAS-SEARCH:     size=196699
  DBG-DELTAS-SEARCH:     base=-1
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=281309
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=165408 (GOOD)
  DBG-DELTAS-SEARCH: ROUND #5 - 1 candidates - refine-up
  DBG-DELTAS-SEARCH:   CONTENDER: rev=4947 - length=52101
  DBG-DELTAS-SEARCH:   CANDIDATE: rev=4954
  DBG-DELTAS-SEARCH:     type=snapshot-2
  DBG-DELTAS-SEARCH:     size=58198
  DBG-DELTAS-SEARCH:     base=4947
  DBG-DELTAS-SEARCH:     uncompressed-delta-size=92195
  DBG-DELTAS-SEARCH:     delta-search-time=* (glob)
  DBG-DELTAS-SEARCH:     DELTA: length=54601 (BAD)
  DBG-DELTAS: FILELOG:SPARSE-REVLOG-TEST-FILE: rev=4996: delta-base=4947 is-cached=0 - search-rounds=5 try-count=5 - delta-type=snapshot snap-depth=2 - p1-chain-length=15 p2-chain-length=-1 - duration=*.?????? (glob)

  $ cd ..
