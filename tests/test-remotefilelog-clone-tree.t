#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ cd master
  $ echo treemanifest >> .hg/requires
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > EOF
# uppercase directory name to test encoding
  $ mkdir -p A/B
  $ echo x > A/B/x
  $ hg commit -qAm x

  $ cd ..

# shallow clone from full

  $ hgcloneshallow ssh://user@dummy/master shallow --noupdate
  streaming all changes
  5 files to transfer, 449 bytes of data (no-rust !)
  stream-cloned 5 files / 449 bytes in * seconds (*/sec) (glob) (no-rust !)
  7 files to transfer, 575 bytes of data (rust !)
  stream-cloned 7 files / 575 bytes in *.* seconds (*) (glob) (rust !)
  searching for changes
  no changes found
  $ cd shallow
  $ hg debugrequires
  dotencode
  dirstate-v2 (dirstate-v2 !)
  exp-remotefilelog-repo-req-1
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  treemanifest
  $ find .hg/store/meta | sort
  .hg/store/meta
  .hg/store/meta/_a
  .hg/store/meta/_a/00manifest.i
  .hg/store/meta/_a/_b
  .hg/store/meta/_a/_b/00manifest.i

  $ hg update
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)

  $ cat A/B/x
  x

  $ ls .hg/store/data
  $ echo foo > A/B/F
  $ hg add A/B/F
  $ hg ci -m 'local content'
  $ ls .hg/store/data
  ca31988f085bfb945cb8115b78fabdee40f741aa

  $ cd ..

# shallow clone from shallow

  $ hgcloneshallow ssh://user@dummy/shallow shallow2  --noupdate
  streaming all changes
  6 files to transfer, 1008 bytes of data (no-rust !)
  stream-cloned 6 files / 1008 bytes in * seconds (*/sec) (glob) (no-rust !)
  8 files to transfer, 1.11 KB of data (rust !)
  stream-cloned 8 files / 1.11 KB in * seconds (* */sec) (glob) (rust !)
  searching for changes
  no changes found
  $ cd shallow2
  $ hg debugrequires
  dotencode
  dirstate-v2 (dirstate-v2 !)
  exp-remotefilelog-repo-req-1
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  treemanifest
  $ ls .hg/store/data
  ca31988f085bfb945cb8115b78fabdee40f741aa

  $ hg update
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cat A/B/x
  x

  $ cd ..

# full clone from shallow
# - send stderr to /dev/null because the order of stdout/err causes
#   flakiness here
  $ hg clone --noupdate ssh://user@dummy/shallow full 2>/dev/null
  streaming all changes
  [100]

# getbundle full clone

  $ printf '[server]\npreferuncompressed=False\n' >> master/.hg/hgrc
  $ hgcloneshallow ssh://user@dummy/master shallow3
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 18d955ee7ba0
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ ls shallow3/.hg/store/data
  $ hg debugrequires -R shallow3/
  dotencode
  dirstate-v2 (dirstate-v2 !)
  exp-remotefilelog-repo-req-1
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  treemanifest
