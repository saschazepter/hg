#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > EOF
  $ echo x > foo
  $ echo y > bar
  $ hg commit -qAm one

  $ cd ..

# partial shallow clone

  $ hg clone --shallow ssh://user@dummy/master shallow --noupdate --config remotefilelog.includepattern=foo
  streaming all changes
  4 files to transfer, 336 bytes of data (no-zstd !)
  stream-cloned 4 files / 336 bytes in * seconds (* */sec) (glob) (no-zstd !)
  4 files to transfer, 338 bytes of data (zstd no-rust !)
  stream-cloned 4 files / 338 bytes in * seconds (* */sec) (glob) (zstd no-rust !)
  6 files to transfer, 464 bytes of data (zstd rust !)
  stream-cloned 6 files / 464 bytes in * seconds (*/sec) (glob) (zstd rust !)
  searching for changes
  no changes found
  $ cat >> shallow/.hg/hgrc <<EOF
  > [remotefilelog]
  > cachepath=$PWD/hgcache
  > debug=True
  > includepattern=foo
  > reponame = master
  > [extensions]
  > remotefilelog=
  > EOF
  $ ls shallow/.hg/store/data
  bar.i

# update partial clone

  $ cd shallow
  $ hg update
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
  $ cat foo
  x
  $ cat bar
  y
  $ cd ..

# pull partial clone

  $ cd master
  $ echo a >> foo
  $ echo b >> bar
  $ hg commit -qm two
  $ cd ../shallow
  $ hg pull
  pulling from ssh://user@dummy/master
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets a9688f18cb91
  (run 'hg update' to get a working copy)
  $ hg update
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
  $ cat foo
  x
  a
  $ cat bar
  y
  b

  $ cd ..
