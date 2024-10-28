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

TODO: bad error message

  $ $NO_FALLBACK rhg cat -r "$tip" hide
  abort: invalid revision identifier: 1406e74118627694268417491f018a4a883152f0
  [255]
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

# TODO: even though [hg files] hides the orphaned dir2/z, [hg cat] still shows it.
# rhg has the same issue, but at least it's not specific to rhg.
# This is despite [hg verify] succeeding above.

  $ $NO_FALLBACK rhg cat -r "$tip" dir2/z
  z
  $ "$real_hg" cat -r "$tip" dir2/z
  z
