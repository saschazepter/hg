====================================
Test delta choice with sparse revlog
====================================

#testcases delta-info-flags flagless


Common Setup
============

#if pure
  $ PURE="1"
#else
  $ PURE="0"
#endif
#if slow
  $ SLOW="1"
#else
  $ SLOW="0"
#endif
#if delta-info-flags
  $ DELTA_INFO="yes"
#else
  $ DELTA_INFO="no"
#endif
  $ export SLOW
  $ export PURE
  $ export DELTA_INFO
  $ bash $TESTDIR/testlib/setup-sparse-churning-bundle.sh
  adding changesets
  adding manifests
  adding file changes
  added 5001 changesets with 5001 changes to 1 files (+89 heads)
  new changesets 9706f5af64f4:3bb1647e55b4 (5001 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "3bb1647e55b4: commit #5000"
  89 other heads for branch "default"
  $ if [ -f SKIPPED ]; then
  >     cat SKIPPED
  >     exit 80
  > fi
  $ cd sparse-repo


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
  >   --config format.use-delta-info-flags=$UPGRADE_TO
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: delta-info-revlog (delta-info-flags !)
     added: delta-info-revlog (flagless !)
  
  optimisations: re-delta-all
  
  processed revlogs:
    - all-filelogs
    - changelog
    - manifest
  
  $ hg verify --quiet
  $ hg debugrevlog * > ../revlog-stats-post-upgrade.txt

#if delta-info-flags
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=(28502223|27288785) (re)
#if zlib-ng
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta, hasmeta, delta-info
  +flags  : generaldelta
   
   revisions     :     5001
       merges    :      625 (12.50%)
  @@ -8,56 +8,59 @@
       empty     :        0 ( 0.00%)
                      text  :        0 (100.00%)
                      delta :        0 (100.00%)
  -    snapshot  :      189 ( 3.78%)
  +    snapshot  :      416 ( 8.32%)
         lvl-0   :              3 ( 0.06%)
  -      lvl-1   :             19 ( 0.38%)  non-ancestor-bases:        8 (42.11%)
  -      lvl-2   :             51 ( 1.02%)  non-ancestor-bases:       45 (88.24%)
  -      lvl-3   :             64 ( 1.28%)  non-ancestor-bases:       61 (95.31%)
  -      lvl-4   :             37 ( 0.74%)  non-ancestor-bases:       33 (89.19%)
  -      lvl-5   :             13 ( 0.26%)  non-ancestor-bases:       12 (92.31%)
  -      lvl-6   :              2 ( 0.04%)  non-ancestor-bases:        2 (100.00%)
  -    deltas    :     4812 (96.22%)
  -revision size : 23671272
  -    snapshot  :  5243811 (22.15%)
  -      lvl-0   :         561948 ( 2.37%)
  -      lvl-1   :        1785647 ( 7.54%)
  -      lvl-2   :        1538726 ( 6.50%)
  -      lvl-3   :        1019994 ( 4.31%)
  -      lvl-4   :         278655 ( 1.18%)
  -      lvl-5   :          53181 ( 0.22%)
  -      lvl-6   :           5660 ( 0.02%)
  -    deltas    : 18427461 (77.85%)
  +      lvl-1   :             26 ( 0.52%)  non-ancestor-bases:       10 (38.46%)
  +      lvl-2   :             76 ( 1.52%)  non-ancestor-bases:       69 (90.79%)
  +      lvl-3   :            114 ( 2.28%)  non-ancestor-bases:      111 (97.37%)
  +      lvl-4   :            111 ( 2.22%)  non-ancestor-bases:      106 (95.50%)
  +      lvl-5   :             67 ( 1.34%)  non-ancestor-bases:       64 (95.52%)
  +      lvl-6   :             17 ( 0.34%)  non-ancestor-bases:       17 (100.00%)
  +      lvl-7   :              2 ( 0.04%)  non-ancestor-bases:        2 (100.00%)
  +    deltas    :     4585 (91.68%)
  +revision size : 27288785
  +    snapshot  :  8059104 (29.53%)
  +      lvl-0   :         562012 ( 2.06%)
  +      lvl-1   :        2019509 ( 7.40%)
  +      lvl-2   :        2032944 ( 7.45%)
  +      lvl-3   :        1988765 ( 7.29%)
  +      lvl-4   :        1028243 ( 3.77%)
  +      lvl-5   :         361599 ( 1.33%)
  +      lvl-6   :          60733 ( 0.22%)
  +      lvl-7   :           5299 ( 0.02%)
  +    deltas    : 19229681 (70.47%)
   
   chunks        :     5001
       0x78 (x)  :     5001 (100.00%)
  -chunks size   : 23671272
  -    0x78 (x)  : 23671272 (100.00%)
  +chunks size   : 27288785
  +    0x78 (x)  : 27288785 (100.00%)
   
   
   total-stored-content: 1 714 759 864 bytes
   
   avg chain length  :        9
   max chain length  :       15
  -max chain reach   : 16995912
  -compression ratio :       72
  +max chain reach   : 19798279
  +compression ratio :       62
   
   uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  -full revision size (min/max/avg)     : 185798 / 189681 / 187316
  -inter-snapshot size (min/max/avg)    : 2282 / 169783 / 25171
  -    level-1   (min/max/avg)          : 8332 / 169783 / 93981
  -    level-2   (min/max/avg)          : 3011 / 77429 / 30171
  -    level-3   (min/max/avg)          : 2282 / 42232 / 15937
  -    level-4   (min/max/avg)          : 2515 / 21377 / 7531
  -    level-5   (min/max/avg)          : 2608 / 9749 / 4090
  -    level-6   (min/max/avg)          : 2591 / 3069 / 2830
  -delta size (min/max/avg)             : 1572 / 167593 / 3829
  +full revision size (min/max/avg)     : 185876 / 189681 / 187337
  +inter-snapshot size (min/max/avg)    : 2097 / 170379 / 18152
  +    level-1   (min/max/avg)          : 3128 / 170379 / 77673
  +    level-2   (min/max/avg)          : 2279 / 83491 / 26749
  +    level-3   (min/max/avg)          : 2259 / 42376 / 17445
  +    level-4   (min/max/avg)          : 2097 / 21529 / 9263
  +    level-5   (min/max/avg)          : 2262 / 10652 / 5397
  +    level-6   (min/max/avg)          : 2424 / 5123 / 3572
  +    level-7   (min/max/avg)          : 2605 / 2694 / 2649
  +delta size (min/max/avg)             : 1572 / 166547 / 4194
   
  -deltas against prev  : 1968 (40.90%)
  -    where prev = p1  : 1968     (100.00%)
  +deltas against prev  : 3871 (84.43%)
  +    where prev = p1  : 3871     (100.00%)
       where prev = p2  :    0     ( 0.00%)
       other-ancestor   :    0     ( 0.00%)
       unrelated        :    0     ( 0.00%)
  -deltas against p1    :  655 (13.61%)
  -deltas against p2    :   11 ( 0.23%)
  +deltas against p1    :  644 (14.05%)
  +deltas against p2    :   70 ( 1.53%)
   deltas against ancs  :    0 ( 0.00%)
  -deltas against other : 2178 (45.26%)
  +deltas against other :    0 ( 0.00%)
  [1]
#else
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta, hasmeta, delta-info
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
#endif
#else
  $ f -s .hg/store/data/*.d
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=(24793761|23671272) (re)
  $ cmp ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt | diff -u ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt
#if zlib-ng
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta
  +flags  : generaldelta, hasmeta, delta-info
   
   revisions     :     5001
       merges    :      625 (12.50%)
  @@ -8,59 +8,56 @@
       empty     :        0 ( 0.00%)
                      text  :        0 (100.00%)
                      delta :        0 (100.00%)
  -    snapshot  :      416 ( 8.32%)
  +    snapshot  :      189 ( 3.78%)
         lvl-0   :              3 ( 0.06%)
  -      lvl-1   :             26 ( 0.52%)  non-ancestor-bases:       10 (38.46%)
  -      lvl-2   :             76 ( 1.52%)  non-ancestor-bases:       69 (90.79%)
  -      lvl-3   :            114 ( 2.28%)  non-ancestor-bases:      111 (97.37%)
  -      lvl-4   :            111 ( 2.22%)  non-ancestor-bases:      106 (95.50%)
  -      lvl-5   :             67 ( 1.34%)  non-ancestor-bases:       64 (95.52%)
  -      lvl-6   :             17 ( 0.34%)  non-ancestor-bases:       17 (100.00%)
  -      lvl-7   :              2 ( 0.04%)  non-ancestor-bases:        2 (100.00%)
  -    deltas    :     4585 (91.68%)
  -revision size : 27288785
  -    snapshot  :  8059104 (29.53%)
  -      lvl-0   :         562012 ( 2.06%)
  -      lvl-1   :        2019509 ( 7.40%)
  -      lvl-2   :        2032944 ( 7.45%)
  -      lvl-3   :        1988765 ( 7.29%)
  -      lvl-4   :        1028243 ( 3.77%)
  -      lvl-5   :         361599 ( 1.33%)
  -      lvl-6   :          60733 ( 0.22%)
  -      lvl-7   :           5299 ( 0.02%)
  -    deltas    : 19229681 (70.47%)
  +      lvl-1   :             19 ( 0.38%)  non-ancestor-bases:        8 (42.11%)
  +      lvl-2   :             51 ( 1.02%)  non-ancestor-bases:       45 (88.24%)
  +      lvl-3   :             64 ( 1.28%)  non-ancestor-bases:       61 (95.31%)
  +      lvl-4   :             37 ( 0.74%)  non-ancestor-bases:       33 (89.19%)
  +      lvl-5   :             13 ( 0.26%)  non-ancestor-bases:       12 (92.31%)
  +      lvl-6   :              2 ( 0.04%)  non-ancestor-bases:        2 (100.00%)
  +    deltas    :     4812 (96.22%)
  +revision size : 23671272
  +    snapshot  :  5243811 (22.15%)
  +      lvl-0   :         561948 ( 2.37%)
  +      lvl-1   :        1785647 ( 7.54%)
  +      lvl-2   :        1538726 ( 6.50%)
  +      lvl-3   :        1019994 ( 4.31%)
  +      lvl-4   :         278655 ( 1.18%)
  +      lvl-5   :          53181 ( 0.22%)
  +      lvl-6   :           5660 ( 0.02%)
  +    deltas    : 18427461 (77.85%)
   
   chunks        :     5001
       0x78 (x)  :     5001 (100.00%)
  -chunks size   : 27288785
  -    0x78 (x)  : 27288785 (100.00%)
  +chunks size   : 23671272
  +    0x78 (x)  : 23671272 (100.00%)
   
   
   total-stored-content: 1 714 759 864 bytes
   
   avg chain length  :        9
   max chain length  :       15
  -max chain reach   : 19798279
  -compression ratio :       62
  +max chain reach   : 16995912
  +compression ratio :       72
   
   uncompressed data size (min/max/avg) : 340425 / 346470 / 342883
  -full revision size (min/max/avg)     : 185876 / 189681 / 187337
  -inter-snapshot size (min/max/avg)    : 2097 / 170379 / 18152
  -    level-1   (min/max/avg)          : 3128 / 170379 / 77673
  -    level-2   (min/max/avg)          : 2279 / 83491 / 26749
  -    level-3   (min/max/avg)          : 2259 / 42376 / 17445
  -    level-4   (min/max/avg)          : 2097 / 21529 / 9263
  -    level-5   (min/max/avg)          : 2262 / 10652 / 5397
  -    level-6   (min/max/avg)          : 2424 / 5123 / 3572
  -    level-7   (min/max/avg)          : 2605 / 2694 / 2649
  -delta size (min/max/avg)             : 1572 / 166547 / 4194
  +full revision size (min/max/avg)     : 185798 / 189681 / 187316
  +inter-snapshot size (min/max/avg)    : 2282 / 169783 / 25171
  +    level-1   (min/max/avg)          : 8332 / 169783 / 93981
  +    level-2   (min/max/avg)          : 3011 / 77429 / 30171
  +    level-3   (min/max/avg)          : 2282 / 42232 / 15937
  +    level-4   (min/max/avg)          : 2515 / 21377 / 7531
  +    level-5   (min/max/avg)          : 2608 / 9749 / 4090
  +    level-6   (min/max/avg)          : 2591 / 3069 / 2830
  +delta size (min/max/avg)             : 1572 / 167593 / 3829
   
  -deltas against prev  : 3871 (84.43%)
  -    where prev = p1  : 3871     (100.00%)
  +deltas against prev  : 1968 (40.90%)
  +    where prev = p1  : 1968     (100.00%)
       where prev = p2  :    0     ( 0.00%)
       other-ancestor   :    0     ( 0.00%)
       unrelated        :    0     ( 0.00%)
  -deltas against p1    :  644 (14.05%)
  -deltas against p2    :   70 ( 1.53%)
  +deltas against p1    :  655 (13.61%)
  +deltas against p2    :   11 ( 0.23%)
   deltas against ancs  :    0 ( 0.00%)
  -deltas against other :    0 ( 0.00%)
  +deltas against other : 2178 (45.26%)
  [1]
#else
  $ cmp ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt | diff -u ../revlog-stats-pre-upgrade.txt ../revlog-stats-post-upgrade.txt
  --- ../revlog-stats-pre-upgrade.txt* (glob)
  +++ ../revlog-stats-post-upgrade.txt* (glob)
  @@ -1,5 +1,5 @@
   format : 1
  -flags  : generaldelta
  +flags  : generaldelta, hasmeta, delta-info
   
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
#endif

  $ cd ..
