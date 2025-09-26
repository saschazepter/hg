===============
test clone hgrc
===============

Verify that extension can alter the content of a hgrc during clone using clone
bundles.  Motivated by issue #10019


Set up a server

  $ hg init server
  $ cd server
  $ cat >> .hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > EOF

  $ touch foo
  $ hg -q commit -A -m 'add foo'
  $ touch bar
  $ hg -q commit -A -m 'add bar'

  $ hg serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ cd ..
  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS
  $ hg -R server bundle --type gzip-v2 --base null -r tip full.hg
  2 changesets found
  $ echo "http://localhost:$HGPORT1/full.hg" > server/.hg/clonebundles.manifest

clone remote without extension

  $ hg clone http://localhost:$HGPORT test
  applying clone bundle from http://localhost:$HGPORT1/full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat test/.hg/hgrc
  # example repository config (see 'hg help config' for more info)
  [paths]
  default = http://localhost:$HGPORT/
  
  # path aliases to other clones of this repo in URLs or filesystem paths
  # (see 'hg help config.paths' for more info)
  #
  # default:pushurl = ssh://jdoe@example.net/hg/jdoes-fork
  # my-fork         = ssh://jdoe@example.net/hg/jdoes-fork
  # my-clone        = /home/jdoe/jdoes-clone
  
  [ui]
  # name and email (local to this repository, optional), e.g.
  # username = Jane Doe <jdoe@example.com>

add extension

  $ cat > write_hgrc.py << EOF
  > from mercurial import bundle2, extensions, util
  > from mercurial import registrar
  > configtable = {}
  > configitem = registrar.configitem(configtable)
  > def _write_hgrc(orig, repo, *args, **kwargs):
  >   with repo.wlock():
  >     op = orig(repo, *args, **kwargs)
  >     with op.repo.vfs(b'hgrc', b'w') as hgrc:
  >       hgrc.write(util.tonativeeol(b'# written by extension!\n'))
  > def uisetup(ui):
  >   extensions.wrapfunction(bundle2, 'processbundle', _write_hgrc)
  > EOF
  $ hg --config extensions.write_hgrc=./write_hgrc.py clone http://localhost:$HGPORT test-extended
  applying clone bundle from http://localhost:$HGPORT1/full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat ./test-extended/.hg/hgrc
  # example repository config (see 'hg help config' for more info)
  [paths]
  default = http://localhost:$HGPORT/
  
  # path aliases to other clones of this repo in URLs or filesystem paths
  # (see 'hg help config.paths' for more info)
  #
  # default:pushurl = ssh://jdoe@example.net/hg/jdoes-fork
  # my-fork         = ssh://jdoe@example.net/hg/jdoes-fork
  # my-clone        = /home/jdoe/jdoes-clone
  
  [ui]
  # name and email (local to this repository, optional), e.g.
  # username = Jane Doe <jdoe@example.com>
  # written by extension!
