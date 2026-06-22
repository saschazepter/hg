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
  > [diff]
  > git=yes
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
  nothing changed
  [1]

  $ hg -R repo log -G
  @  changeset:   0:a27d7651a8de
     tag:         tip
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  


# do a commit with things to commit

  $ echo b > thin/babar
  $ echo zzz > thin/zephir
  $ hg -R thin commit -m 'foo'

  $ hg -R repo log -G
  o  changeset:   1:6a3dd2470982
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     foo
  |
  @  changeset:   0:a27d7651a8de
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  

Running `hg add` before the commit
----------------------------------

  $ hg -R repo devel::create-thin-wc thin-add
  $ echo fou > thin-add/rataxes
  $ hg --cwd thin-add add rataxes
  $ hg -R thin-add commit -m 'rataxes'
  $ hg -R repo log -G
  o  changeset:   2:70c3e1e28bd7
  |  tag:         tip
  |  parent:      0:a27d7651a8de
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  | o  changeset:   1:6a3dd2470982
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     foo
  |
  @  changeset:   0:a27d7651a8de
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("rataxes")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID 70c3e1e28bd7e4442d949730a3584ceba4f91615
  # Parent  a27d7651a8de9e060a1f1e839dc7c2039fb9a843
  rataxes
  
  diff --git a/rataxes b/rataxes
  new file mode 100644
  --- /dev/null
  +++ b/rataxes
  @@ -0,0 +1,1 @@
  +fou

