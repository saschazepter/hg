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
  .hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
  $ cmp ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt | diff -u ../revlog-stats-reference.txt ../revlog-stats-pre-upgrade.txt
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

  $ cd ..
