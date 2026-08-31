==================================
Testing branchmap topological mode
==================================

  $ cat <<EOF >> $HGRCPATH
  > [experimental]
  > branch-cache-v3=yes
  > EOF
  $ CACHE_PREFIX=branch3



Catch a case were the topo-mode=pure select the wrong branch
------------------------------------------------------------

A non-topological head on lexicographical higher branch should not confuse the
topological detection.

  $ hg init branchmap-testing1
  $ cd branchmap-testing1
  $ hg debugbuild '@C . $ @D .'
  $ hg update D
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --close-branch -m _
  $ hg update C
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge D
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m ab

  $ touch x
  $ hg commit -A x -m_
  $ hg log -G -T '{branch} {if(closesbranch, "X", " ")} {node|short}\n'
  @  C   64bc6c1bbbcf
  |
  o    C   922c771bcc9c
  |\
  | _  D X b6d05de170f1
  | |
  | o  D   9fb9610dce33
  |
  o  C   266067de9702
  

  $ cat .hg/cache/branch3*
  tip-node=64bc6c1bbbcf5d74d77ed6549e50580838293bee tip-rev=4 topo-mode=pure
  C
  b6d05de170f1652bb1cd95314cda67f7febeacc7 c D
  $ rm .hg/cache/branch3*
  $ hg debugupdatecache
  $ cat .hg/cache/branch3*
  tip-node=64bc6c1bbbcf5d74d77ed6549e50580838293bee tip-rev=4 topo-mode=pure
  C
  b6d05de170f1652bb1cd95314cda67f7febeacc7 c D
  $ hg branches
  C                              4:64bc6c1bbbcf
  $ cd ..

Destroying revisions should not lose the topo-mode
--------------------------------------------------

This section tests that rollback rebuilds the branch cache, and doesn't lose the
"pure" topo-mode while doing so.

  $ hg init branchmap-testing2
  $ cd branchmap-testing2
  $ hg branch -q C
  $ echo a > a
  $ hg commit -Aqm a
  $ echo b > b
  $ hg commit -Aqm b
  $ hg update -q 0
  $ echo c > c
  $ hg commit -Aqm c
  $ hg commit --close-branch -m _
  $ hg update -q 1
  $ hg merge -q 3
  $ hg commit -m reopen
  reopening closed branch head 3
  $ hg log -G -T '{branch} {if(closesbranch, "X", " ")} {node|short}\n'
  @    C   0593ba3b8b2f
  |\
  | _  C X 3a4b69c060ee
  | |
  | o  C   73b113d8433d
  | |
  o |  C   ea66cc27ac3e
  |/
  o  C   e643aee6d833
  
  $ hg debugupdatecache
  $ cat .hg/cache/branch3-served
  tip-node=0593ba3b8b2f33f0525304eecffd673e2b665a9b tip-rev=4 topo-mode=pure
  C

adding and removing a revision should not lose the topo-mode

  $ touch x
  $ hg commit -A x -m _
  $ hg rollback
  repository tip rolled back to revision 4 (undo commit)
  working directory now based on revision 4
  $ cat .hg/cache/branch3-served
  tip-node=0593ba3b8b2f33f0525304eecffd673e2b665a9b tip-rev=4 topo-mode=mixed (known-bad-output !)
  tip-node=0593ba3b8b2f33f0525304eecffd673e2b665a9b tip-rev=4 topo-mode=pure (missing-correct-output !)
  C
  
  $ cd ..
