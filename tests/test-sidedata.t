==========================================================
Test file dedicated to checking side-data related behavior
==========================================================

Check data can be written/read from sidedata
============================================

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > testsidedata=$TESTDIR/testlib/ext-sidedata.py
  > [storage]
  > fileindex.slow-path=allow
  > EOF

  $ hg init test-sidedata --config experimental.revlogv2=enable-unstable-format-and-corrupt-my-data
  $ cd test-sidedata
  $ echo aaa > a
  $ hg add a
  $ hg commit -m a --traceback
  $ echo aaa > b
  $ hg add b
  $ hg commit -m b
  $ echo xxx >> a
  $ hg commit -m aa

  $ hg debugsidedata -m 0
  2 sidedata entries
   entry-0001 size 4
   entry-0002 size 32
  $ hg debugsidedata -m 1 -v
  2 sidedata entries
   entry-0001 size 4
    '\x00\x00\x00V'
   entry-0002 size 32
    '\xf6\xe9\xb0\xb1\xad\x01\xdc\x89\xc2uR\x7f\xb5E\t\x92\xee\xe3\'\xdfRN<.\x10\xe6*&\xd3\\\xe7S'
  $ hg debugsidedata -m 2
  2 sidedata entries
   entry-0001 size 4
   entry-0002 size 32
  $ hg debugsidedata a  1

  $ hg debug-revlog-index --verbose -m
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size   child-p1   child-p2 sibling-p1 sibling-p2
       0     -1       0 b85d294330e3     -1 000000000000     -1 000000000000                   43          0     0         0                    0         43        plain                    0            90                    0                  0          -          -          -          -
       1     -1       1 1a0aec305c63      0 b85d294330e3     -1 000000000000                   86          0     0         0                   43         55        plain                   90            90                    0                  0          -          -          -          -
       2     -1       2 104258a4f75f      1 1a0aec305c63     -1 000000000000                   86          1     0         0                   98         55        plain                  180            90                    0                  0          -          -          -          -

  $ hg debug-revlog-index --verbose -m
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size changed-files-offset changed-files-size   child-p1   child-p2 sibling-p1 sibling-p2
       0     -1       0 b85d294330e3     -1 000000000000     -1 000000000000                   43          0     0         0                    0         43        plain                    0            90                    0                  0          -          -          -          -
       1     -1       1 1a0aec305c63      0 b85d294330e3     -1 000000000000                   86          0     0         0                   43         55        plain                   90            90                    0                  0          -          -          -          -
       2     -1       2 104258a4f75f      1 1a0aec305c63     -1 000000000000                   86          1     0         0                   98         55        plain                  180            90                    0                  0          -          -          -          -

Check upgrade behavior
======================

Right now, sidedata has not upgrade support

Check that we can upgrade to sidedata
-------------------------------------

  $ hg init up-no-side-data --config experimental.revlogv2=no
  $ hg debugformat -v -R up-no-side-data changelog-v2 revlog-v2
  format-variant                 repo config default
  revlog-v2:                       no     no      no
  changelog-v2:                    no     no      no
  $ hg debugformat -v -R up-no-side-data --config experimental.revlogv2=enable-unstable-format-and-corrupt-my-data changelog-v2 revlog-v2
  format-variant                 repo config default
  revlog-v2:                       no    yes      no
  changelog-v2:                    no    yes      no
  $ hg debugupgraderepo -R up-no-side-data --config experimental.revlogv2=enable-unstable-format-and-corrupt-my-data > /dev/null

Check that we can downgrade from sidedata
-----------------------------------------

  $ hg init up-side-data --config experimental.revlogv2=enable-unstable-format-and-corrupt-my-data
  $ hg debugformat -v -R up-side-data changelog-v2 revlog-v2
  format-variant                 repo config default
  revlog-v2:                      yes     no      no
  changelog-v2:                   yes     no      no
  $ hg debugformat -v -R up-side-data --config experimental.revlogv2=no changelog-v2 revlog-v2
  format-variant                 repo config default
  revlog-v2:                      yes     no      no
  changelog-v2:                   yes     no      no
  $ hg debugupgraderepo -R up-side-data --config experimental.revlogv2=no > /dev/null
