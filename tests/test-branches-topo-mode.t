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
  D
  b6d05de170f1652bb1cd95314cda67f7febeacc7 c D
  $ hg branches 2>&1 | grep AssertionError
  AssertionError
