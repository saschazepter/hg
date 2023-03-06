Create an empty repo:

  $ hg init a
  $ cd a

Try some commands:

  $ hg log
  $ hg grep wah
  [1]
  $ hg manifest
  $ hg verify -q

Check the basic files created:

  $ ls .hg
  00changelog.i
  cache
  requires
  store
  wcache

Should be empty (except for the "basic" requires):

  $ ls .hg/store
  requires

Poke at a clone:

  $ cd ..
  $ hg clone a b
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd b
  $ hg verify -q
  $ ls .hg
  00changelog.i
  branch
  cache
  hgrc
  requires
  store
  wcache

Should be empty (except for the "basic" requires):

  $ ls .hg/store
  requires

  $ cd ..
