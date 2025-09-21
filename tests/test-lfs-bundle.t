In this test, we want to test LFS bundle application on both LFS and non-LFS
repos.

To make it more interesting, the file revisions will contain hg filelog
metadata ('\1\n'). The bundle will have 1 file revision overlapping with the
destination repo.

#  rev      1          2         3
#  repo:    yes        yes       no
#  bundle:  no (base)  yes       yes (deltabase: 2 if possible)

It is interesting because rev 2 could have been stored as LFS in the repo, and
non-LFS in the bundle; or vice-versa.

Init

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > lfs=
  > drawdag=$TESTDIR/drawdag.py
  > [lfs]
  > url=file:$TESTTMP/lfs-remote
  > EOF

Helper functions

  $ commitxy() {
  > hg debugdrawdag "$@" <<'EOS'
  >  Y  # Y/X=\1\nAAAA\nE\nF
  >  |  # Y/Y=\1\nAAAA\nG\nH
  >  X  # X/X=\1\nAAAA\nC\n
  >     # X/Y=\1\nAAAA\nD\n
  > EOS
  > }

  $ commitz() {
  > hg debugdrawdag "$@" <<'EOS'
  >  Z  # Z/X=\1\nAAAA\nI\n
  >  |  # Z/Y=\1\nAAAA\nJ\n
  >  |  # Z/Z=\1\nZ
  >  Y
  > EOS
  > }

  $ enablelfs() {
  >   cat >> .hg/hgrc <<EOF
  > [lfs]
  > track=all()
  > EOF
  > }

Generate bundles

  $ for i in normal lfs; do
  >   NAME=src-$i
  >   hg init $TESTTMP/$NAME
  >   cd $TESTTMP/$NAME
  >   [ $i = lfs ] && enablelfs
  >   commitxy
  >   commitz
  >   hg bundle -q --base X -r Y+Z $TESTTMP/$NAME.bundle
  >   SRCNAMES="$SRCNAMES $NAME"
  > done

Prepare destination repos

  $ for i in normal lfs; do
  >   NAME=dst-$i
  >   hg init $TESTTMP/$NAME
  >   cd $TESTTMP/$NAME
  >   [ $i = lfs ] && enablelfs
  >   commitxy
  >   DSTNAMES="$DSTNAMES $NAME"
  > done

Apply bundles

  $ for i in $SRCNAMES; do
  >   for j in $DSTNAMES; do
  >     echo ---- Applying $i.bundle to $j ----
  >     cp -R $TESTTMP/$j $TESTTMP/tmp-$i-$j
  >     cd $TESTTMP/tmp-$i-$j
  >     if hg unbundle $TESTTMP/$i.bundle -q 2>/dev/null; then
  >       hg verify -q && echo OK
  >     else
  >       echo CRASHED
  >     fi
  >   done
  > done
  ---- Applying src-normal.bundle to dst-normal ----
  OK
  ---- Applying src-normal.bundle to dst-lfs ----
  OK
  ---- Applying src-lfs.bundle to dst-normal ----
  OK
  ---- Applying src-lfs.bundle to dst-lfs ----
  OK


Test that the cache info can be printed.  The 4 cases are:

1) The test-provided config path, with plain and json output
2) The test-provided config path, with plain and json output, but the cache disabled
3) A config provided path, with plain and json output
4) A config provided path, with plain and json output, but the cache disabled

  $ hg debug::lfs-local-cache
  path:    $TESTTMP/.cache/lfs (glob)
  enabled: yes
  $ hg debug::lfs-local-cache -T json
  [
   {
    "enabled": "yes",
    "path": "$TESTTMP/.cache/lfs" (glob) (no-windows !)
    "path": "$STR_REPR_TESTTMP\\.cache\\lfs" (windows !)
   }
  ]

  $ hg debug::lfs-local-cache --config experimental.lfs.disableusercache=1
  path:    (unknown)
  enabled: no
  $ hg debug::lfs-local-cache --config experimental.lfs.disableusercache=1 \
  >                           -T json
  [
   {
    "enabled": "no",
    "path": ""
   }
  ]

  $ hg debug::lfs-local-cache --config lfs.usercache=relpath
  path:    $TESTTMP/tmp-src-lfs-dst-lfs/relpath
  enabled: yes
  $ hg debug::lfs-local-cache --config lfs.usercache=relpath -T json
  [
   {
    "enabled": "yes",
    "path": "$TESTTMP/tmp-src-lfs-dst-lfs/relpath" (no-windows !)
    "path": "$STR_REPR_TESTTMP\\tmp-src-lfs-dst-lfs\\relpath" (windows !)
   }
  ]

  $ hg debug::lfs-local-cache --config lfs.usercache=relpath \
  >                           --config experimental.lfs.disableusercache=1
  path:    (unknown)
  enabled: no
  $ hg debug::lfs-local-cache --config lfs.usercache=relpath \
  >                           --config experimental.lfs.disableusercache=1 \
  >                           -T json
  [
   {
    "enabled": "no",
    "path": ""
   }
  ]


Hint if the cache location cannot be inferred from the environment

#if windows
  $ unset LOCALAPPDATA
  $ unset APPDATA
  $ HGRCPATH= hg config lfs --source
  abort: unknown lfs usercache location
  (define LOCALAPPDATA or APPDATA in the environment, or set lfs.usercache)
  [255]
#endif

#if osx
  $ unset HOME
  $ HGRCPATH= hg config lfs --source
  abort: unknown lfs usercache location
  (define HOME in the environment, or set lfs.usercache)
  [255]
#endif

#if no-windows no-osx
  $ unset XDG_CACHE_HOME
  $ unset HOME
  $ HGRCPATH= hg config lfs --source
  abort: unknown lfs usercache location
  (define XDG_CACHE_HOME or HOME in the environment, or set lfs.usercache)
  [255]
#endif

