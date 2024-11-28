#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > EOF
  $ echo x > x
  $ hg commit -qAm x
  $ echo y >> x
  $ hg commit -qAm y
  $ echo z >> x
  $ hg commit -qAm z
  $ hg update 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo w >> x
  $ hg commit -qAm w

  $ cd ..

Shallow clone and activate getflogheads testing extension

  $ hgcloneshallow ssh://user@dummy/master shallow --noupdate
  streaming all changes
  3 files to transfer, 908 bytes of data (no-rust !)
  stream-cloned 3 files / 908 bytes in * seconds (*/sec) (glob) (no-rust !)
  5 files to transfer, 1.01 KB of data (rust !)
  stream-cloned 5 files / 1.01 KB in * seconds (* */sec) (glob) (rust !)
  searching for changes
  no changes found
  $ cd shallow

  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > getflogheads=$TESTDIR/remotefilelog-getflogheads.py
  > EOF

Get heads of a remotefilelog

  $ hg getflogheads x
  2797809ca5e9c2f307d82b1345e832f655fb99a2
  ca758b402ddc91e37e3113e1a97791b537e1b7bb

Get heads of a non-existing remotefilelog

  $ hg getflogheads y
  EMPTY
