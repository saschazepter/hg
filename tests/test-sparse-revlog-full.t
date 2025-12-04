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

  $ cat << EOF >>.hg/hgrc
  > [storage]
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta = no
  > EOF


Testing exchange through full bundle
====================================

Pull of everything and check the quality of the result,

Doing a full pull should give use the same result as the pull source as the
server should be able to encode his chain as is.

  $ hg init ../full-pull
  $ cd ../full-pull

Here we go ove the default and trust parent choice from the bundle. Since all
revision are bundled, all delta base should be valid and the server should be
able to stream its delta as is.

  $ cat << EOF >> .hg/hgrc
  > [path]
  > *:pulled-delta-reuse-policy = try-base
  > EOF

XXX - disabling the delta-parent reuse for now as it seems to get confuse about snapshot status.
#if delta-info-flags
  $ cat << EOF >> $HGRCPATH
  > [path]
  > *:pulled-delta-reuse-policy = default
  > EOF
#endif

pull everything

  $ hg pull ../sparse-repo
  pulling from ../sparse-repo
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 5001 changesets with 5001 changes to 1 files (+89 heads)
  new changesets 9706f5af64f4:3bb1647e55b4
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../
#if delta-info-flags
  $ f -s */.hg/store/data/*.d
  full-pull/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
  sparse-repo/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=24793761
#else
  $ f -s */.hg/store/data/*.d
  full-pull/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
  sparse-repo/.hg/store/data/_s_p_a_r_s_e-_r_e_v_l_o_g-_t_e_s_t-_f_i_l_e.d: size=28502223
#endif
  $ hg debugrevlog --cwd full-pull SPARSE-REVLOG-TEST-FILE > ./revlog-stats-post-pull.txt
  $ cmp ./revlog-stats-reference.txt ./revlog-stats-post-pull.txt | diff -u ./revlog-stats-reference.txt ./revlog-stats-post-pull.txt

  $ cd ..
