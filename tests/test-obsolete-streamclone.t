Test exchanging obsolescence marker with stream clone

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution.createmarkers=yes
  > evolution.exchange=yes
  > EOF

Simple setup
============

Create a DAG where a changeset reuses a revision from a file first used in an
extinct changeset.

  $ hg init server
  $ cd server
  $ echo 'base' > base
  $ echo 'foo' > foo
  $ hg commit -Am base
  adding base
  adding foo
  $ echo 'A0' > A
  $ hg commit -Am c_A0_
  adding A
  $ echo 'A1' > A
  $ hg commit --amend -m c_A1_
  $ cd ..

Test direct stream cloning
==========================

  $ hg clone --stream ssh://user@dummy/server clone --traceback
  streaming all changes
  ?? files to transfer, * of data (glob)
  stream-cloned ?? files / * in * seconds (*/sec) (glob)
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R clone debugobsolete
  cb2c2c150e2c3c5cc6bb2a653934509055e4d8be ec5198de3061ff8f07ac42311977b7db2f9d729e 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '9', 'operation': 'amend', 'user': 'test'}

Bundling
========

without marker

  $ hg -R server bundle -t 'none-streamv2;obsolescence=false' --all all.stream-hg
  abort: server has obsolescence markers, but client cannot receive them via stream clone
  [255]
  $ f --size all.stream-hg
  all.stream-hg: file not found

with marker

  $ hg -R server bundle -t 'none-streamv2;obsolescence=true' --all all.stream-hg
  abort: server has obsolescence markers, but client cannot receive them via stream clone (known-bad-output !)
  [255]
  $ f --size all.stream-hg
  all.stream-hg: size=???? (glob) (missing-correct-output !)
  all.stream-hg: file not found (known-bad-output !)
