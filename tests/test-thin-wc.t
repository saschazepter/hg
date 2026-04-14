==========================
Test the "thin" extensions
==========================

The "thin" extensions provides "thin" working copy, that don't have a full
store locally, but are just a simple working copy attached to a "remote"
repository.

For testing purpose, the "remote" repository is a local backend, but it is
still accessed through a dedicated API.

The "thin" extensions is still at a early stage of development, assume that
anything not tested here is unsupported and likely to be broken.


  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > thin=
  > EOF

  $ hg init repo
  $ cd repo
  $ echo a > babar
  $ echo bb > zephir
  $ echo ccc > celeste
  $ echo dddd > arthur
  $ hg commit -Am base
  adding arthur
  adding babar
  adding celeste
  adding zephir
  $ cd ..

  $ hg -R repo devel::create-thin-wc thin

  $ ls -1 thin
  arthur
  babar
  celeste
  zephir

  $ (cd repo; f --sha1 * > ../repo-content)
  $ (cd thin; f --sha1 * > ../thin-content)
  $ diff repo-content thin-content

  $ ls thin/.hg
  dirstate
  dirstate-tracked-hint
  requires
  thin-backend
  $ cat thin/.hg/requires
  dirstate-v2
  dirstate-tracked-key-v1
  share-safe
  exp-v0-thin (no-eol)
  $ cat thin/.hg/thin-backend
  local://$TESTTMP/repo

# do a commit with nothing to commit

  $ hg -R thin commit -m 'empty-foo' --traceback

  $ hg -R repo log -G
  o  changeset:   1:9f76d2d87e9f
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     empty-foo
  |
  @  changeset:   0:a27d7651a8de
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  


# do a commit with things to commit

  $ echo b > thin/babar
  $ echo zzz > thin/zephir
  $ hg -R thin commit -m 'foo'

  $ hg -R repo log -G
  o  changeset:   2:6a3dd2470982
  |  tag:         tip
  |  parent:      0:a27d7651a8de
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     foo
  |
  | o  changeset:   1:9f76d2d87e9f
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     empty-foo
  |
  @  changeset:   0:a27d7651a8de
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
