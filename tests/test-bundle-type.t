bundle w/o type option

  $ hg init t1
  $ hg init t2
  $ cd t1
  $ echo blablablablabla > file.txt
  $ hg ci -A -m commit_root
  adding file.txt
  $ echo kapoue > file.txt
  $ hg ci -m commit_1
  $ echo scrabageul > file.txt
  $ hg ci -m commit_2
  $ hg up 'desc("commit_root")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo flagabalagla > file.txt
  $ hg ci -m commit_3
  created new head
  $ echo aliofia > file.txt
  $ hg ci -m commit_4
  $ echo alklqo > file.txt
  $ hg ci -m commit_5
  $ echo peakfeo > file.txt
  $ hg ci -m commit_6 --secret
  $ hg phase --public --rev 'desc(commit_3)'
  $ hg log -GT '[{phase}] {desc|firstline}\n'
  @  [secret] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [public] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [public] commit_root
  

XXX the bundle generation is defined by a discovery round here. So the secret
changeset should be excluded.

  $ hg bundle ../b1.hg ../t2
  searching for changes
  7 changesets found (known-bad-output !)
  6 changesets found (missing-correct-output !)
  $ cd ..

  $ hg -R t2 unbundle ./b1.hg
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads) (known-bad-output !)
  added 6 changesets with 6 changes to 1 files (+1 heads) (missing-correct-output !)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg -R t2 up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "b9f5f740a8cd: commit_6"
  1 other heads for branch "default"
  $ hg -R t2 log -GT '[{phase}] {desc|firstline}\n'
  @  [draft] commit_6 (known-bad-output !)
  | (known-bad-output !)
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  

Unknown compression type is rejected

  $ hg init t3
  $ hg -R t3 -q unbundle ./b1.hg
  $ hg -R t3 bundle -a -t unknown out.hg
  abort: unknown is not a recognized bundle specification
  (see 'hg help bundlespec' for supported values for --type)
  [10]

  $ hg -R t3 bundle -a -t unknown-v2 out.hg
  abort: unknown compression is not supported
  (see 'hg help bundlespec' for supported values for --type)
  [10]

test bundle types
=================

since we use --all, it is okay to include the secret changeset here. It is
unfortunate that the phase information for the secret one is lost.

  $ testbundle() {
  >   echo % test bundle type $1
  >   echo '==================================='
  >   hg -R t1 bundle --all --type $1 ./b-$1.hg
  >   f -q -B6 -D ./b-$1.hg; echo
  >   hg debugbundle ./b-$1.hg
  >   hg debugbundle --spec ./b-$1.hg
  >   echo
  >   hg init repo-from-type-$1
  >   hg unbundle -R repo-from-type-$1 ./b-$1.hg
  >   hg -R repo-from-type-$1 log -GT '[{phase}] {desc|firstline}\n'
  >   echo
  > }

  $ for t in "None" "bzip2" "gzip" "none-v2" "v2" "v1" "gzip-v1" "v3"; do
  >   testbundle $t
  > done
  % test bundle type None
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  none-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type bzip2
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  bzip2-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type gzip
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: GZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  gzip-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type none-v2
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  none-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type v2
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  bzip2-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type v1
  ===================================
  7 changesets found
  HG10BZ
  ac39af4a9f7d2aaa7d244720e57838be9bf63b03
  901e97fadc587978ec52f2fa76af4aefc2d191e8
  a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
  66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
  624e609639853fe22c88d42a8fd1f53a0e9b7ebe
  2ea90778052ba7558fab36e3fd5d149512ff986b
  b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  bzip2-v1
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type gzip-v1
  ===================================
  7 changesets found
  HG10GZ
  ac39af4a9f7d2aaa7d244720e57838be9bf63b03
  901e97fadc587978ec52f2fa76af4aefc2d191e8
  a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
  66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
  624e609639853fe22c88d42a8fd1f53a0e9b7ebe
  2ea90778052ba7558fab36e3fd5d149512ff986b
  b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  gzip-v1
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type v3
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, targetphase: 2, version: 03} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d public
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55 draft
      2ea90778052ba7558fab36e3fd5d149512ff986b draft
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5 secret
  bzip2-v2;cg.version=03
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (4 drafts, 1 secrets)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [secret] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [public] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [public] commit_root
  
  

Compression level can be adjusted for bundle2 bundles

  $ hg init test-complevel
  $ cd test-complevel

  $ cat > file0 << EOF
  > this is a file
  > with some text
  > and some more text
  > and other content
  > EOF
  $ cat > file1 << EOF
  > this is another file
  > with some other content
  > and repeated, repeated, repeated, repeated content
  > EOF
  $ hg -q commit -A -m initial

  $ hg bundle -a -t gzip-v2 gzip-v2.hg
  1 changesets found
  $ f --size gzip-v2.hg
  gzip-v2.hg: size=468

  $ hg --config experimental.bundlecomplevel=1 bundle -a -t gzip-v2 gzip-v2-level1.hg
  1 changesets found
  $ f --size gzip-v2-level1.hg
  gzip-v2-level1.hg: size=475

  $ hg --config experimental.bundlecomplevel.gzip=1 --config experimental.bundlelevel=9 bundle -a -t gzip-v2 gzip-v2-level1.hg
  1 changesets found
  $ f --size gzip-v2-level1.hg
  gzip-v2-level1.hg: size=475

  $ cd ..

#if zstd

  $ for t in "zstd" "zstd-v2"; do
  >   testbundle $t
  > done
  % test bundle type zstd
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: ZS}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  zstd-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  
  % test bundle type zstd-v2
  ===================================
  7 changesets found
  HG20\x00\x00 (esc)
  Stream params: {Compression: ZS}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  cache:rev-branch-cache -- {} (mandatory: False)
  zstd-v2
  
  adding changesets
  adding manifests
  adding file changes
  added 7 changesets with 7 changes to 1 files (+1 heads)
  new changesets ac39af4a9f7d:b9f5f740a8cd (7 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  o  [draft] commit_6
  |
  o  [draft] commit_5
  |
  o  [draft] commit_4
  |
  o  [draft] commit_3
  |
  | o  [draft] commit_2
  | |
  | o  [draft] commit_1
  |/
  o  [draft] commit_root
  
  

Explicit request for zstd on non-generaldelta repos

  $ hg --config format.usegeneraldelta=false init nogd
  $ hg -q -R nogd pull t1
  $ hg -R nogd bundle -a -t zstd nogd-zstd
  6 changesets found

zstd-v1 always fails

  $ hg -R t1 bundle -a -t zstd-v1 zstd-v1
  abort: compression engine zstd is not supported on v1 bundles
  (see 'hg help bundlespec' for supported values for --type)
  [10]

zstd supports threading

  $ hg init test-compthreads
  $ cd test-compthreads
  $ hg debugbuilddag +3
  $ hg --config experimental.bundlecompthreads=1 bundle -a -t zstd-v2 zstd-v2-threaded.hg
  3 changesets found
  $ cd ..

#else

zstd is a valid engine but isn't available

  $ hg -R t1 bundle -a -t zstd irrelevant.hg
  abort: compression engine zstd could not be loaded
  [255]

#endif

test garbage file

  $ echo garbage > bgarbage
  $ hg init tgarbage
  $ cd tgarbage
  $ hg pull ../bgarbage
  pulling from ../bgarbage
  abort: ../bgarbage: not a Mercurial bundle
  [255]
  $ cd ..

test invalid bundle type

  $ cd t1
  $ hg bundle -a -t garbage ../bgarbage
  abort: garbage is not a recognized bundle specification
  (see 'hg help bundlespec' for supported values for --type)
  [10]
  $ cd ..

Test controlling the changegroup version

  $ hg -R t1 bundle --config experimental.changegroup3=yes -a -t v2 ./v2-cg-default.hg
  7 changesets found
  $ hg debugbundle ./v2-cg-default.hg --part-type changegroup
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  $ hg debugbundle ./v2-cg-default.hg --spec
  bzip2-v2
  $ hg -R t1 bundle --config experimental.changegroup3=yes -a -t 'v2;cg.version=02' ./v2-cg-02.hg
  7 changesets found
  $ hg debugbundle ./v2-cg-02.hg --part-type changegroup
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  $ hg debugbundle ./v2-cg-02.hg --spec
  bzip2-v2
  $ hg -R t1 bundle --config experimental.changegroup3=yes -a -t 'v2;cg.version=03' ./v2-cg-03.hg
  7 changesets found
  $ hg debugbundle ./v2-cg-03.hg --part-type changegroup
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 03} (mandatory: True)
      ac39af4a9f7d2aaa7d244720e57838be9bf63b03
      901e97fadc587978ec52f2fa76af4aefc2d191e8
      a8c3a1ed30eb71f03f476c5fa7ead831ef991a55
      66e2c4b43e0cf8f0bdff0733a0b97ce57874e35d
      624e609639853fe22c88d42a8fd1f53a0e9b7ebe
      2ea90778052ba7558fab36e3fd5d149512ff986b
      b9f5f740a8cd76700020e3903ee55ecff78bd3e5
  $ hg debugbundle ./v2-cg-03.hg --spec
  bzip2-v2;cg.version=03

tests controlling bundle contents
=================================

  $ hg debugupdatecache -R t1

default content
---------------

  $ hg -R t1 bundle --all --quiet --type 'v2' ./v2.hg
  $ hg debugbundle ./v2.hg --spec
  bzip2-v2
  $ hg debugbundle ./v2.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)

  $ hg -R t1 bundle --all --quiet --type 'v3' ./v3.hg
  $ hg debugbundle ./v3.hg --spec
  bzip2-v2;cg.version=03
  $ hg debugbundle ./v3.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, targetphase: 2, version: 03} (mandatory: True)
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)

adding extra parts
------------------

We should have a "phase-heads" part here that we did not had in the default content

  $ hg -R t1 bundle --all --quiet --type 'v2;phases=1' ./v2-phases.hg
  $ hg debugbundle ./v2-phases.hg --spec
  bzip2-v2
  $ hg debugbundle ./v2-phases.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, targetphase: 2, version: 02} (mandatory: True)
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)

skipping default inclusion
--------------------------

  $ hg -R t1 bundle --all --quiet --type 'v2;tagsfnodescache=false' ./v2-no-tfc.hg
  $ hg debugbundle ./v2-no-tfc.hg --spec
  bzip2-v2
  $ hg debugbundle ./v2-no-tfc.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 02} (mandatory: True)
  cache:rev-branch-cache -- {} (mandatory: False)

  $ hg -R t1 bundle --all --quiet --type 'v3;phases=0' ./v3-no-phases.hg
  $ hg debugbundle ./v3-no-phases.hg --spec
  bzip2-v2;cg.version=03
  $ hg debugbundle ./v3-no-phases.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 03} (mandatory: True)
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)

  $ hg -R t1 bundle --all --quiet --type 'v3;phases=no;tagsfnodescache=0' ./v3-multi-no.hg
  $ hg debugbundle ./v3-multi-no.hg --spec
  bzip2-v2;cg.version=03
  $ hg debugbundle ./v3-multi-no.hg --quiet
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 7, version: 03} (mandatory: True)
  cache:rev-branch-cache -- {} (mandatory: False)

skipping changegroup
--------------------

  $ hg -R t1 bundle --all --quiet --type 'v2;changegroup=no' ./v2-no-cg.hg
  $ hg debugbundle ./v2-no-cg.hg --spec
  bzip2-v2;changegroup=no
  $ hg debugbundle ./v2-no-cg.hg --quiet
  Stream params: {Compression: BZ}
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)

  $ hg -R t1 bundle --all --quiet --type 'v3;changegroup=0' ./v3-no-cg.hg
  $ hg debugbundle ./v3-no-cg.hg --spec
  bzip2-v2;changegroup=no
  $ hg debugbundle ./v3-no-cg.hg --quiet
  Stream params: {Compression: BZ}
  hgtagsfnodes -- {} (mandatory: False)
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
