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
  > 
  > [clone-bundles]
  > auto-generate.formats = gzip-v2
  > auto-generate.serve-inline=yes
  > EOF

  $ touch foo
  $ hg -q commit -A -m 'add foo'
  $ touch bar
  $ hg -q commit -A -m 'add bar'
  $ cd ..
  $ hg -R server admin::clone-bundles-refresh
  2 changesets found

clone remote without extension

  $ hg clone ssh://user@dummy/server test
  applying clone bundle from peer-bundle-cache://full-gzip-v2-2_revs-000000000000_tip-*_acbr.hg (glob)
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
  default = ssh://user@dummy/server
  
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
  $ hg --config extensions.write_hgrc=./write_hgrc.py clone ssh://user@dummy/server test-extended
  applying clone bundle from peer-bundle-cache://full-gzip-v2-2_revs-000000000000_tip-*_acbr.hg (glob)
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
  default = ssh://user@dummy/server
  
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
