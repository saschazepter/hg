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

  $ cat << EOF >>sparse-repo/.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta = no
  > EOF

Testing incremental pull
========================

pulling every revision ten by ten

  $ hg init incremental-10-pull
  $ cd incremental-10-pull

Here we go ove the default and trust parent choice from the bundle. Since all
revision are bundled, all delta base should be valid and the server should be
able to stream its delta as is.

  $ cat << EOF >> .hg/hgrc
  > [path]
  > *:pulled-delta-reuse-policy = try-base
  > EOF


pull changeset 10 by 10

  $ $TESTDIR/seq.py 0 `hg log -R ../sparse-repo --rev tip --template '{rev}'` | while
  >   read rev0;
  >   read rev1;
  >   read rev2;
  >   read rev3;
  >   read rev4;
  >   read rev5;
  >   read rev6;
  >   read rev7;
  >   read rev8;
  >   read rev9;
  >   do
  >     hg pull --quiet ../sparse-repo --rev $rev0 --rev $rev1 --rev $rev2 --rev $rev3 --rev $rev4 --rev $rev5 --rev $rev6 --rev $rev7 --rev $rev8 --rev $rev9 || break
  > done
  $ hg pull ../sparse-repo
  pulling from ../sparse-repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (-1 heads)
  new changesets 3bb1647e55b4
  (run 'hg update' to get a working copy)
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../
#if delta-info-flags
  $ f -s */.hg/store/data/*.d
  incremental-10-pull/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
  sparse-repo/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
#else
  $ f -s */.hg/store/data/*.d
  incremental-10-pull/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
  sparse-repo/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
#endif
  $ hg debugrevlog --cwd incremental-10-pull SPARSE-REVLOG-TEST-FILE > ./revlog-stats-post-inc-pull.txt
  $ cmp ./revlog-stats-reference.txt ./revlog-stats-post-inc-pull.txt | diff -u ./revlog-stats-reference.txt ./revlog-stats-post-inc-pull.txt
