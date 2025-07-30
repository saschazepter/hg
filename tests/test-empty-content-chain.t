############################################
Test delta chain involving "zero size" delta
############################################

Codes dealing with delta (delta-search, changegroup, etc) tend to have special
case around delta with zero size, and this tend to create bugs. This module is
an attempt to catch them. Creating some delta chain with such deltas's and
running operation that might trigger such bug.

See da1d1ee5bc2b for an example of such bug.


Create a repository with delta chain with empty delta and empty file revisions
==============================================================================


  $ hg init base-repo
  $ cd base-repo
  $ touch a
  $ hg add a
  $ hg commit -m 'empty base'
  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo other > a
  $ hg add a
  $ hg commit -m 'non-empty base'
  created new head
  $ rm a
  $ touch a
  $ hg commit -m  'empty now'
  $ hg merge
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m 'empty merge'
  $ echo foo > a
  $ hg commit -m 'foo'
  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo toto > a
  $ hg add a
  $ hg commit -m 'base with content'
  created new head
  $ hg up "desc(\"empty merge\")" --quiet
  $ hg merge tip
  merging a
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ rm a
  $ touch a
  $ hg commit -m 'merge new content with one empty'
  $ echo titi > a
  $ hg commit -m "add \"titi\" content"
  $ hg up 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge "desc(\"base with content\")"
  merging a
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ rm a
  $ touch a
  $ hg commit -m 'merge new content with empty root'
  created new head
  $ echo tutu > a
  $ hg commit -m "add \"tutu\" content"

  $ hg log -G
  @  changeset:   9:c562755b641e
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     add "tutu" content
  |
  o    changeset:   8:5a552a3446e2
  |\   parent:      0:b4da7db3066c
  | |  parent:      5:e2d5978dcd14
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     merge new content with empty root
  | |
  | | o  changeset:   7:03064da59860
  | | |  user:        test
  | | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | | |  summary:     add "titi" content
  | | |
  | | o  changeset:   6:b0cf3d38f29d
  | |/|  parent:      3:6012960dc8f7
  | | |  parent:      5:e2d5978dcd14
  | | |  user:        test
  | | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | | |  summary:     merge new content with one empty
  | | |
  | o |  changeset:   5:e2d5978dcd14
  |  /   parent:      -1:000000000000
  | |    user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    summary:     base with content
  | |
  | | o  changeset:   4:5ab5e491174d
  | |/   user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    summary:     foo
  | |
  | o  changeset:   3:6012960dc8f7
  |/|  parent:      2:bb6ac66a97de
  | |  parent:      0:b4da7db3066c
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     empty merge
  | |
  | o  changeset:   2:bb6ac66a97de
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     empty now
  | |
  | o  changeset:   1:1015cf71ddf2
  |    parent:      -1:000000000000
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     non-empty base
  |
  o  changeset:   0:b4da7db3066c
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     empty base
  
  $ hg debugindex a -v
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 b80de5d13875     -1 000000000000     -1 000000000000                    0          0     0         2                    0          0       inline                    0             0
       1     -1       1 48f0daf20d9d     -1 000000000000     -1 000000000000                    6          1     0         2                    0          7       inline                    0             0
       2     -1       2 a77634414f69      1 48f0daf20d9d     -1 000000000000                    0          2     0         2                    7          0       inline                    0             0
       3     -1       3 e44c370a738f      2 a77634414f69      0 b80de5d13875                    0          3     0         2                    7          0       inline                    0             0
       4     -1       4 a1680305cb3f      3 e44c370a738f     -1 000000000000                    4          4     0         2                    7          5       inline                    0             0
       5     -1       5 17ffe06fa8d7     -1 000000000000     -1 000000000000                    5          5     0         2                   12          6       inline                    0             0
       6     -1       6 472c4e87fcf4      3 e44c370a738f      5 17ffe06fa8d7                    0          6     0         2                   18          0       inline                    0             0
       7     -1       7 609fb9854b7e      6 472c4e87fcf4     -1 000000000000                    5          7     0         2                   18          6       inline                    0             0
       8     -1       8 b0fc748a0c2f      0 b80de5d13875      5 17ffe06fa8d7                    0          8     0         2                   24          0       inline                    0             0
       9     -1       9 9f0450b584a8      8 b0fc748a0c2f     -1 000000000000                    5          9     0         2                   24          6       inline                    0             0

  $ cd ..


Test operations on it
=====================

Clone with a bundle containing delta's against weird bases
----------------------------------------------------------


  $ echo "[devel]" >> base-repo/.hg/hgrc
  $ echo "bundle.delta=prev" >> base-repo/.hg/hgrc


  $ hg clone --pull ssh://user@dummy/base-repo cloned-repo
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 10 changesets with 10 changes to 1 files (+2 heads)
  new changesets b4da7db3066c:c562755b641e
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg debugindex a -v -R cloned-repo
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 b80de5d13875     -1 000000000000     -1 000000000000                    0          0     0         2                    0          0       inline                    0             0
       1     -1       1 48f0daf20d9d     -1 000000000000     -1 000000000000                    6          1     0         2                    0          7       inline                    0             0
       2     -1       2 a77634414f69      1 48f0daf20d9d     -1 000000000000                    0          2     0         2                    7          0       inline                    0             0
       3     -1       3 e44c370a738f      2 a77634414f69      0 b80de5d13875                    0          3     0         2                    7          0       inline                    0             0
       4     -1       4 a1680305cb3f      3 e44c370a738f     -1 000000000000                    4          4     0         2                    7          5       inline                    0             0
       5     -1       5 17ffe06fa8d7     -1 000000000000     -1 000000000000                    5          5     0         2                   12          6       inline                    0             0
       6     -1       6 472c4e87fcf4      3 e44c370a738f      5 17ffe06fa8d7                    0          6     0         2                   18          0       inline                    0             0
       7     -1       7 609fb9854b7e      6 472c4e87fcf4     -1 000000000000                    5          7     0         2                   18          6       inline                    0             0
       8     -1       8 b0fc748a0c2f      0 b80de5d13875      5 17ffe06fa8d7                    0          8     0         2                   24          0       inline                    0             0
       9     -1       9 9f0450b584a8      8 b0fc748a0c2f     -1 000000000000                    5          9     0         2                   24          6       inline                    0             0


pull forcing the creation of delta against a weird base
-------------------------------------------------------

Case 1

  $ hg clone --pull ssh://user@dummy/base-repo pull-repo-1 --rev 4
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 1 files
  new changesets b4da7db3066c:5ab5e491174d
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R pull-repo-1 pull
  pulling from ssh://user@dummy/base-repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 1 files (+2 heads)
  new changesets e2d5978dcd14:c562755b641e
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R pull-repo-1 debugindex a -v
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 b80de5d13875     -1 000000000000     -1 000000000000                    0          0     0         2                    0          0       inline                    0             0
       1     -1       1 48f0daf20d9d     -1 000000000000     -1 000000000000                    6          1     0         2                    0          7       inline                    0             0
       2     -1       2 a77634414f69      1 48f0daf20d9d     -1 000000000000                    0          2     0         2                    7          0       inline                    0             0
       3     -1       3 e44c370a738f      2 a77634414f69      0 b80de5d13875                    0          3     0         2                    7          0       inline                    0             0
       4     -1       4 a1680305cb3f      3 e44c370a738f     -1 000000000000                    4          4     0         2                    7          5       inline                    0             0
       5     -1       5 17ffe06fa8d7     -1 000000000000     -1 000000000000                    5          5     0         2                   12          6       inline                    0             0
       6     -1       6 472c4e87fcf4      3 e44c370a738f      5 17ffe06fa8d7                    0          6     0         2                   18          0       inline                    0             0
       7     -1       7 609fb9854b7e      6 472c4e87fcf4     -1 000000000000                    5          7     0         2                   18          6       inline                    0             0
       8     -1       8 b0fc748a0c2f      0 b80de5d13875      5 17ffe06fa8d7                    0          8     0         2                   24          0       inline                    0             0
       9     -1       9 9f0450b584a8      8 b0fc748a0c2f     -1 000000000000                    5          9     0         2                   24          6       inline                    0             0

case 2

  $ hg clone --pull ssh://user@dummy/base-repo pull-repo-2 --rev 4
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 1 files
  new changesets b4da7db3066c:5ab5e491174d
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg -R pull-repo-2 pull -r 8 -r 6
  pulling from ssh://user@dummy/base-repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files (+2 heads)
  new changesets e2d5978dcd14:5a552a3446e2
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R pull-repo-2 pull
  pulling from ssh://user@dummy/base-repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets 03064da59860:c562755b641e
  (run 'hg update' to get a working copy)
  $ hg -R pull-repo-2 debugindex a -v
     rev   rank linkrev       nodeid p1-rev    p1-nodeid p2-rev    p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 b80de5d13875     -1 000000000000     -1 000000000000                    0          0     0         2                    0          0       inline                    0             0
       1     -1       1 48f0daf20d9d     -1 000000000000     -1 000000000000                    6          1     0         2                    0          7       inline                    0             0
       2     -1       2 a77634414f69      1 48f0daf20d9d     -1 000000000000                    0          2     0         2                    7          0       inline                    0             0
       3     -1       3 e44c370a738f      2 a77634414f69      0 b80de5d13875                    0          3     0         2                    7          0       inline                    0             0
       4     -1       4 a1680305cb3f      3 e44c370a738f     -1 000000000000                    4          4     0         2                    7          5       inline                    0             0
       5     -1       5 17ffe06fa8d7     -1 000000000000     -1 000000000000                    5          5     0         2                   12          6       inline                    0             0
       6     -1       6 472c4e87fcf4      3 e44c370a738f      5 17ffe06fa8d7                    0          6     0         2                   18          0       inline                    0             0
       7     -1       7 b0fc748a0c2f      0 b80de5d13875      5 17ffe06fa8d7                    0          7     0         2                   18          0       inline                    0             0
       8     -1       8 609fb9854b7e      6 472c4e87fcf4     -1 000000000000                    5          8     0         2                   18          6       inline                    0             0
       9     -1       9 9f0450b584a8      7 b0fc748a0c2f     -1 000000000000                    5          9     0         2                   24          6       inline                    0             0


Recompute all its deltas
------------------------

  $ hg -R base-repo debugupgraderepo -o re-delta-all --run --quiet
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
  
  optimisations: re-delta-all
  
  processed revlogs:
    - all-filelogs
    - changelog
    - manifest
  
