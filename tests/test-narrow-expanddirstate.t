  $ . "$TESTDIR/narrow-library.sh"

  $ hg init master
  $ cd master

  $ mkdir inside
  $ echo inside > inside/f1
  $ mkdir outside
  $ echo outside > outside/f2
  $ mkdir patchdir
  $ echo patch_this > patchdir/f3
  $ hg ci -Aqm 'initial'

  $ cd ..

  $ hg clone --narrow ssh://user@dummy/master narrow --include inside
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets dff6a2a6d433
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cd narrow

  $ mkdir outside
  $ echo other_contents > outside/f2
  $ grep outside .hg/narrowspec
  [1]
  $ grep outside .hg/dirstate
  [1]
  $ hg status

`hg status` did not add outside.
  $ grep outside .hg/narrowspec
  [1]
  $ grep outside .hg/dirstate
  [1]

Unfortunately this is not really a candidate for adding to narrowhg proper,
since it depends on some other source for providing the manifests (when using
treemanifests) and file contents. Something like a virtual filesystem and/or
remotefilelog. We want to be useful when not using those systems, so we do not
have this method available in narrowhg proper at the moment.
  $ cat > "$TESTTMP/expand_extension.py" <<EOF
  > import os
  > import sys
  > 
  > from mercurial import extensions
  > from mercurial import localrepo
  > from mercurial import match as matchmod
  > from mercurial import patch
  > from mercurial import util as hgutil
  > 
  > def expandnarrowspec(ui, repo, newincludes=None):
  >   if not newincludes:
  >     return
  >   import sys
  >   newincludes = set([newincludes])
  >   narrowhg = extensions.find('narrow')
  >   includes, excludes = repo.narrowpats
  >   currentmatcher = narrowhg.narrowspec.match(repo.root, includes, excludes)
  >   includes = includes | newincludes
  >   if not repo.currenttransaction():
  >     ui.develwarn('expandnarrowspec called outside of transaction!')
  >   repo.setnarrowpats(includes, excludes)
  >   newmatcher = narrowhg.narrowspec.match(repo.root, includes, excludes)
  >   added = matchmod.differencematcher(newmatcher, currentmatcher)
  >   for f in repo['.'].manifest().walk(added):
  >     repo.dirstate.normallookup(f)
  > 
  > def makeds(ui, repo):
  >   def wrapds(orig, self):
  >     ds = orig(self)
  >     class expandingdirstate(ds.__class__):
  >       # Mercurial 4.4 uses this version.
  >       @hgutil.propertycache
  >       def _map(self):
  >         ret = super(expandingdirstate, self)._map
  >         with repo.wlock(), repo.lock(), repo.transaction(
  >             'expandnarrowspec'):
  >           expandnarrowspec(ui, repo, os.environ.get('DIRSTATEINCLUDES'))
  >         return ret
  >       # Mercurial 4.3.3 and earlier uses this version. It seems that
  >       # narrowhg does not currently support this version, but we include
  >       # it just in case backwards compatibility is restored.
  >       def _read(self):
  >         ret = super(expandingdirstate, self)._read()
  >         with repo.wlock(), repo.lock(), repo.transaction(
  >             'expandnarrowspec'):
  >           expandnarrowspec(ui, repo, os.environ.get('DIRSTATEINCLUDES'))
  >         return ret
  >     ds.__class__ = expandingdirstate
  >     return ds
  >   return wrapds
  > 
  > def reposetup(ui, repo):
  >   extensions.wrapfilecache(localrepo.localrepository, 'dirstate',
  >                            makeds(ui, repo))
  >   def overridepatch(orig, *args, **kwargs):
  >     with repo.wlock():
  >       expandnarrowspec(ui, repo, os.environ.get('PATCHINCLUDES'))
  >       return orig(*args, **kwargs)
  > 
  >   extensions.wrapfunction(patch, 'patch', overridepatch)
  > EOF
  $ cat >> ".hg/hgrc" <<EOF
  > [extensions]
  > expand_extension = $TESTTMP/expand_extension.py
  > EOF

Since we do not have the ability to rely on a virtual filesystem or
remotefilelog in the test, we just fake it by copying the data from the 'master'
repo.
  $ cp -a ../master/.hg/store/data/* .hg/store/data
Do that for patchdir as well.
  $ cp -a ../master/patchdir .

`hg status` will now add outside, but not patchdir.
  $ DIRSTATEINCLUDES=path:outside hg status
  M outside/f2
  $ grep outside .hg/narrowspec
  path:outside
  $ grep outside .hg/dirstate > /dev/null
  $ grep patchdir .hg/narrowspec
  [1]
  $ grep patchdir .hg/dirstate
  [1]

Get rid of the modification to outside/f2.
  $ hg update -C .
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

This patch will not apply cleanly at the moment, so `hg import` will break
  $ cat > "$TESTTMP/foo.patch" <<EOF
  > --- patchdir/f3
  > +++ patchdir/f3
  > @@ -1,1 +1,1 @@
  > -this should be "patch_this", but its not, so patch fails
  > +this text is irrelevant
  > EOF
  $ PATCHINCLUDES=path:patchdir hg import -p0 -e "$TESTTMP/foo.patch" -m ignored
  applying $TESTTMP/foo.patch
  patching file patchdir/f3
  Hunk #1 FAILED at 0
  1 out of 1 hunks FAILED -- saving rejects to file patchdir/f3.rej
  abort: patch failed to apply
  [255]
  $ grep patchdir .hg/narrowspec
  [1]
  $ grep patchdir .hg/dirstate > /dev/null
  [1]

Let's make it apply cleanly and see that it *did* expand properly
  $ cat > "$TESTTMP/foo.patch" <<EOF
  > --- patchdir/f3
  > +++ patchdir/f3
  > @@ -1,1 +1,1 @@
  > -patch_this
  > +patched_this
  > EOF
  $ PATCHINCLUDES=path:patchdir hg import -p0 -e "$TESTTMP/foo.patch" -m message
  applying $TESTTMP/foo.patch
  $ cat patchdir/f3
  patched_this
  $ grep patchdir .hg/narrowspec
  path:patchdir
  $ grep patchdir .hg/dirstate > /dev/null
