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
  $ printf bb > zephir
  $ echo ccc > celeste
  $ echo dddd > arthur
  $ ln -s arthur cousin
  $ hg commit -Am base
  adding arthur
  adding babar
  adding celeste
  adding cousin
  adding zephir
  $ cd ..

  $ hg -R repo devel::create-thin-wc thin

  $ ls -1 thin
  arthur
  babar
  celeste
  cousin
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

  $ hg -R thin status
  $ hg -R thin commit -m 'empty-foo' --traceback
  nothing changed
  [1]

  $ hg -R repo log -G
  @  changeset:   0:a94414d00384
     tag:         tip
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  

Run an ambiguous status

  $ touch -c -t 200001010000 thin/arthur
  $ touch -c -t 200001010000 thin/celeste
  $ touch -c -t 200001010000 -h thin/cousin
  $ hg -R thin status

# do a commit with things to commit

  $ echo b > thin/babar
  $ echo zzz > thin/zephir
  $ hg -R thin status
  M babar
  M zephir
  $ hg -R thin commit -m 'foo'

  $ hg -R repo log -G
  o  changeset:   1:a2ab6f280788
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     foo
  |
  @  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  

Running `hg add` before the commit
----------------------------------

  $ hg -R repo devel::create-thin-wc thin-add
  $ echo fou > thin-add/rataxes
  $ hg --cwd thin-add add rataxes
  $ hg -R thin-add status
  A rataxes
  $ hg -R thin-add commit -m 'rataxes'
  $ hg -R repo log -G
  o  changeset:   2:6f0ec60a93aa
  |  tag:         tip
  |  parent:      0:a94414d00384
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  | o  changeset:   1:a2ab6f280788
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     foo
  |
  @  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("rataxes")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID 6f0ec60a93aa3c4e8cd850fd82749ceb1666d190
  # Parent  a94414d0038471bf85012354507f5a705eb8a897
  rataxes
  
  diff --git a/rataxes b/rataxes
  new file mode 100644
  --- /dev/null
  +++ b/rataxes
  @@ -0,0 +1,1 @@
  +fou

Running `hg rm` before the commit
----------------------------------

  $ hg -R repo update 'desc("rataxes")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo devel::create-thin-wc thin-rm
  $ hg --cwd thin-rm rm rataxes
  $ hg -R thin-rm status
  R rataxes
  $ hg -R thin-rm commit -m 'battle'
  $ hg -R repo log -G
  o  changeset:   3:d09c36033361
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     battle
  |
  @  changeset:   2:6f0ec60a93aa
  |  parent:      0:a94414d00384
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  | o  changeset:   1:a2ab6f280788
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     foo
  |
  o  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("battle")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID d09c36033361c98f480e9621e73def20b00ced17
  # Parent  6f0ec60a93aa3c4e8cd850fd82749ceb1666d190
  battle
  
  diff --git a/rataxes b/rataxes
  deleted file mode 100644
  --- a/rataxes
  +++ /dev/null
  @@ -1,1 +0,0 @@
  -fou

symlink work
------------

  $ hg -R repo devel::create-thin-wc thin-symlink

demote a symlink to normal file (no content change)

  $ cd thin-symlink
  $ rm cousin
  $ printf arthur > cousin
  $ hg status
  M cousin

Add a new symlink
  $ ln -s celeste cousine
  $ hg add cousine
  $ hg status
  M cousin
  A cousine

Promote a file to symlink

  $ echo Zephir > bb
  $ hg add bb
  $ rm zephir
  $ ln -s bb zephir
  $ hg status
  M cousin
  M zephir
  A bb
  A cousine
  $ cd ..

Finally commit

  $ hg -R thin-symlink commit -m 'symlink'
  $ hg -R repo log -G
  o  changeset:   4:2cae21a5d237
  |  tag:         tip
  |  parent:      2:6f0ec60a93aa
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     symlink
  |
  | o  changeset:   3:d09c36033361
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     battle
  |
  @  changeset:   2:6f0ec60a93aa
  |  parent:      0:a94414d00384
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  | o  changeset:   1:a2ab6f280788
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     foo
  |
  o  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("symlink")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID 2cae21a5d237d058911134fe3fed581a552f5208
  # Parent  6f0ec60a93aa3c4e8cd850fd82749ceb1666d190
  symlink
  
  diff --git a/bb b/bb
  new file mode 100644
  --- /dev/null
  +++ b/bb
  @@ -0,0 +1,1 @@
  +Zephir
  diff --git a/cousin b/cousin
  old mode 120000
  new mode 100644
  diff --git a/cousine b/cousine
  new file mode 120000
  --- /dev/null
  +++ b/cousine
  @@ -0,0 +1,1 @@
  +celeste
  \ No newline at end of file
  diff --git a/zephir b/zephir
  old mode 100644
  new mode 120000

Test committing copy info
-------------------------

  $ hg -R repo devel::create-thin-wc thin-copies
  $ cd thin-copies
  $ hg status --copies
  $ hg move babar King
  $ hg status --copies
  A King
    babar
  R babar
  $ hg copy celeste Queen
  $ hg status --copies
  A King
    babar
  A Queen
    celeste
  R babar
  $ cd ..
#if execbit

Test that adding exec bytes works
---------------------------------

  $ hg -R repo devel::create-thin-wc thin-exec-add
  $ cd thin-exec-add
  $ chmod +x celeste
  $ echo rhino > victor
  $ chmod +x victor
  $ hg add victor
  $ hg status
  M celeste
  A victor
  $ hg commit -m 'exec-add'
  $ cd ..
  $ hg -R repo log -G --rev '::desc("exec-add")'
  o  changeset:   5:2f59e5e739ea
  |  tag:         tip
  |  parent:      2:6f0ec60a93aa
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     exec-add
  |
  @  changeset:   2:6f0ec60a93aa
  |  parent:      0:a94414d00384
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  o  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("exec-add")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID 2f59e5e739ea8552cbbc99f46a58175392dc08b2
  # Parent  6f0ec60a93aa3c4e8cd850fd82749ceb1666d190
  exec-add
  
  diff --git a/celeste b/celeste
  old mode 100644
  new mode 100755
  diff --git a/victor b/victor
  new file mode 100755
  --- /dev/null
  +++ b/victor
  @@ -0,0 +1,1 @@
  +rhino

Test that removing exec bytes works
-----------------------------------

  $ hg -R repo update 'desc("exec-add")'
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo devel::create-thin-wc thin-exec-remove
  $ cd thin-exec-remove
  $ chmod -x victor
  $ hg status
  M victor
  $ hg commit -m 'exec-remove'
  $ cd ..
  $ hg -R repo log -G --rev '::desc("exec-remove")'
  o  changeset:   6:e7560d4bcf09
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     exec-remove
  |
  @  changeset:   5:2f59e5e739ea
  |  parent:      2:6f0ec60a93aa
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     exec-add
  |
  o  changeset:   2:6f0ec60a93aa
  |  parent:      0:a94414d00384
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     rataxes
  |
  o  changeset:   0:a94414d00384
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     base
  
  $ hg -R repo export --rev 'desc("exec-remove")'
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID e7560d4bcf09b2d31caaff450b92e4e3191222c8
  # Parent  2f59e5e739ea8552cbbc99f46a58175392dc08b2
  exec-remove
  
  diff --git a/victor b/victor
  old mode 100755
  new mode 100644

#endif
