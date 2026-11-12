#require rhg

  $ NO_FALLBACK="env RHG_ON_UNSUPPORTED=abort"

Rhg works well when sparse working copy is enabled.

  $ cd "$TESTTMP"
  $ hg init repo-sparse
  $ cd repo-sparse
  $ cat > .hg/hgrc <<EOF
  > [extensions]
  > sparse=
  > EOF

  $ echo a > show
  $ echo x > hide
  $ mkdir dir1 dir2
  $ echo x > dir1/x
  $ echo y > dir1/y
  $ echo z > dir2/z

  $ hg ci -Aqm 'initial'
  $ hg debugsparse --include 'show'
  $ ls -A
  .hg
  show

  $ tip=$(hg log -r . --template '{node}')
  $ $NO_FALLBACK rhg files -r "$tip"
  dir1/x
  dir1/y
  dir2/z
  hide
  show
  $ $NO_FALLBACK rhg files
  show

  $ $NO_FALLBACK rhg cat -r "$tip" hide
  x

  $ cd ..

rhg names a working copy parent that the changelog does not know. Python only
warns about it and carries on.

  $ cp -R repo-sparse repo-unknown-parent
  $ hg clone -q repo-sparse repo-ahead
  $ echo b > repo-ahead/show
  $ hg -R repo-ahead commit -qm 'ahead'
  $ cp repo-ahead/.hg/dirstate* repo-unknown-parent/.hg/
  $ cd repo-unknown-parent
  $ $NO_FALLBACK rhg --config rhg.status=true status
  abort: working directory has unknown parent '696150d0499d'!
  [255]
  $ "$RHG_FALLBACK_EXECUTABLE" status
  warning: ignoring unknown working parent 696150d0499d!
  M show
  ! dir1/x
  ! dir1/y
  ! dir2/z
  ! hide
  $ cd ..

We support most things when narrow is enabled, too, with a couple of caveats.

  $ . "$TESTDIR/narrow-library.sh"
  $ real_hg=$RHG_FALLBACK_EXECUTABLE

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > narrow=
  > EOF

  $ hg clone --narrow  ./repo-sparse repo-narrow --include dir1
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 2 changes to 2 files
  new changesets 6d714a4a2998
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cd repo-narrow

  $ $NO_FALLBACK rhg cat -r "$tip" dir1/x
  x
  $ "$real_hg" cat -r "$tip" dir1/x
  x

  $ $NO_FALLBACK rhg cat -r "$tip" hide
  [1]
  $ "$real_hg" cat -r "$tip" hide
  [1]

A naive implementation of `rhg files` would leak the paths that are supposed
to be hidden by narrow.

  $ $NO_FALLBACK rhg files -r "$tip"
  dir1/x
  dir1/y
  $ "$real_hg" files -r "$tip"
  dir1/x
  dir1/y

The working copy version works with narrow correctly

  $ $NO_FALLBACK rhg files
  dir1/x
  dir1/y
  $ "$real_hg" files
  dir1/x
  dir1/y

Hg status needs to do some filtering based on narrow spec

  $ mkdir dir2
  $ touch dir2/q
  $ "$real_hg" status
  $ $NO_FALLBACK rhg --config rhg.status=true status

Adding "orphaned" index files:

  $ (cd ..; cp repo-sparse/.hg/store/data/hide.i repo-narrow/.hg/store/data/hide.i)
  $ (cd ..; mkdir repo-narrow/.hg/store/data/dir2; cp repo-sparse/.hg/store/data/dir2/z.i repo-narrow/.hg/store/data/dir2/z.i)
  $ "$real_hg" verify -q

  $ "$real_hg" files -r "$tip"
  dir1/x
  dir1/y

  $ $NO_FALLBACK rhg cat -r "$tip" dir2/z
  [1]
  $ "$real_hg" cat -r "$tip" dir2/z
  [1]

Errors in the narrowspec are reported like Python does.

  $ cd ..
  $ hg clone -q --narrow ./repo-sparse repo-bad-narrowspec --include dir1
  $ cd repo-bad-narrowspec
  $ cat > .hg/store/narrowspec << EOF
  > [include]
  > glob:**
  > EOF
  $ cp .hg/store/narrowspec .hg/narrowspec.dirstate
  $ $NO_FALLBACK rhg files
  abort: invalid prefix on narrow pattern: glob:**
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]
  $ $NO_FALLBACK rhg cat -r "$tip" dir1/x
  abort: invalid prefix on narrow pattern: glob:**
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]
  $ "$real_hg" files
  abort: invalid prefix on narrow pattern: glob:**
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]
  $ cat > .hg/store/narrowspec << EOF
  > path:dir1
  > EOF
  $ cp .hg/store/narrowspec .hg/narrowspec.dirstate
  $ $NO_FALLBACK rhg files
  abort: narrow config entry outside of section: path:dir1
  (add an [include] or [exclude] line to declare the entry type)
  [255]
  $ "$real_hg" files
  abort: narrow config entry outside of section: path:dir1
  (add an [include] or [exclude] line to declare the entry type)
  [255]

A section of includes after one of excludes is refused, while a second section
of includes is fine.

  $ cat > .hg/store/narrowspec << EOF
  > [exclude]
  > path:dir1/y
  > [include]
  > path:dir1
  > EOF
  $ cp .hg/store/narrowspec .hg/narrowspec.dirstate
  $ $NO_FALLBACK rhg files
  abort: narrow config cannot have includes after excludes
  [255]
  $ "$real_hg" files
  abort: narrow config cannot have includes after excludes
  [255]
  $ cat > .hg/store/narrowspec << EOF
  > [include]
  > path:dir1/x
  > [include]
  > path:dir1/y
  > EOF
  $ cp .hg/store/narrowspec .hg/narrowspec.dirstate
  $ $NO_FALLBACK rhg files
  dir1/x
  dir1/y
  $ "$real_hg" files
  dir1/x
  dir1/y

Whitespace around a pattern is stripped like Python does, vertical tabs
included.

  $ printf '[include]\npath:dir1\v\n' > .hg/store/narrowspec
  $ cp .hg/store/narrowspec .hg/narrowspec.dirstate
  $ $NO_FALLBACK rhg files
  abort: narrow pattern with whitespace at the edge: path:dir1\x0b (esc) (known-bad-output !)
  (narrow patterns can't begin or end in whitespace) (known-bad-output !)
  dir1/x (missing-correct-output !)
  dir1/y (missing-correct-output !)
  [255]
  $ "$real_hg" files
  dir1/x
  dir1/y
