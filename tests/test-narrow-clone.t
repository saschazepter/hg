  $ . "$TESTDIR/narrow-library.sh"

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [narrow]
  > serveellipses=True
  > EOF
  $ mkdir dir
  $ mkdir dir/src
  $ cd dir/src
  $ for x in `$TESTDIR/seq.py 20`; do echo $x > "f$x"; hg add "f$x"; hg commit -m "Commit src $x"; done
  $ cd ..
  $ mkdir tests
  $ cd tests
  $ for x in `$TESTDIR/seq.py 20`; do echo $x > "t$x"; hg add "t$x"; hg commit -m "Commit test $x"; done
  $ cd ../../..

Only path: and rootfilesin: pattern prefixes are allowed

  $ hg clone --narrow ssh://user@dummy/master badnarrow --noupdate --include 'glob:**'
  abort: invalid prefix on narrow pattern: glob:**
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]

  $ hg clone --narrow ssh://user@dummy/master badnarrow --noupdate --exclude 'set:ignored'
  abort: invalid prefix on narrow pattern: set:ignored
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]

narrow clone a file, f10

  $ hg clone --narrow ssh://user@dummy/master narrow --noupdate --include "dir/src/f10"
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 1 changes to 1 files
  new changesets *:* (glob)
  $ cd narrow
  $ hg debugrequires | grep -v generaldelta
  dotencode
  dirstate-v2 (dirstate-v2 !)
  fncache
  narrowhg-experimental
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  testonly-simplestore (reposimplestore !)

  $ hg tracked
  I path:dir/src/f10
  $ hg tracked
  I path:dir/src/f10
  $ hg update
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ find * | sort
  dir
  dir/src
  dir/src/f10
  $ cat dir/src/f10
  10

  $ cd ..

local-to-local narrow clones work

  $ hg clone --narrow master narrow-via-localpeer --noupdate --include "dir/src/f10"
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 1 changes to 1 files
  new changesets 5d21aaea77f8:26ce255d5b5d
  $ hg tracked -R narrow-via-localpeer
  I path:dir/src/f10
  $ rm -Rf narrow-via-localpeer

narrow clone with a newline should fail

  $ hg clone --narrow ssh://user@dummy/master narrow_fail --noupdate --include 'dir/src/f10
  > '
  abort: newlines are not allowed in narrowspec paths
  [255]

narrow clone a directory, tests/, except tests/t19

  $ hg clone --narrow ssh://user@dummy/master narrowdir --noupdate --include "dir/tests/" --exclude "dir/tests/t19"
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 21 changesets with 19 changes to 19 files
  new changesets *:* (glob)
  $ cd narrowdir
  $ hg tracked
  I path:dir/tests
  X path:dir/tests/t19
  $ hg tracked
  I path:dir/tests
  X path:dir/tests/t19
  $ hg update
  19 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ find * | sort
  dir
  dir/tests
  dir/tests/t1
  dir/tests/t10
  dir/tests/t11
  dir/tests/t12
  dir/tests/t13
  dir/tests/t14
  dir/tests/t15
  dir/tests/t16
  dir/tests/t17
  dir/tests/t18
  dir/tests/t2
  dir/tests/t20
  dir/tests/t3
  dir/tests/t4
  dir/tests/t5
  dir/tests/t6
  dir/tests/t7
  dir/tests/t8
  dir/tests/t9

  $ cd ..

narrow clone everything but a directory (tests/)

  $ hg clone --narrow ssh://user@dummy/master narrowroot --noupdate --exclude "dir/tests"
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 21 changesets with 20 changes to 20 files
  new changesets *:* (glob)
  $ cd narrowroot
  $ hg tracked
  I path:.
  X path:dir/tests
  $ hg tracked
  I path:.
  X path:dir/tests
  $ hg update
  20 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ find * | sort
  dir
  dir/src
  dir/src/f1
  dir/src/f10
  dir/src/f11
  dir/src/f12
  dir/src/f13
  dir/src/f14
  dir/src/f15
  dir/src/f16
  dir/src/f17
  dir/src/f18
  dir/src/f19
  dir/src/f2
  dir/src/f20
  dir/src/f3
  dir/src/f4
  dir/src/f5
  dir/src/f6
  dir/src/f7
  dir/src/f8
  dir/src/f9

  $ cd ..

narrow clone no paths at all

  $ hg clone --narrow ssh://user@dummy/master narrowempty --noupdate
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets * (glob)
  $ cd narrowempty
  $ hg tracked
  $ hg update
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ ls -A
  .hg

  $ cd ..

simple clone
  $ hg clone ssh://user@dummy/master simpleclone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 40 changesets with 40 changes to 40 files
  new changesets * (glob)
  updating to branch default
  40 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd simpleclone
  $ find * | sort
  dir
  dir/src
  dir/src/f1
  dir/src/f10
  dir/src/f11
  dir/src/f12
  dir/src/f13
  dir/src/f14
  dir/src/f15
  dir/src/f16
  dir/src/f17
  dir/src/f18
  dir/src/f19
  dir/src/f2
  dir/src/f20
  dir/src/f3
  dir/src/f4
  dir/src/f5
  dir/src/f6
  dir/src/f7
  dir/src/f8
  dir/src/f9
  dir/tests
  dir/tests/t1
  dir/tests/t10
  dir/tests/t11
  dir/tests/t12
  dir/tests/t13
  dir/tests/t14
  dir/tests/t15
  dir/tests/t16
  dir/tests/t17
  dir/tests/t18
  dir/tests/t19
  dir/tests/t2
  dir/tests/t20
  dir/tests/t3
  dir/tests/t4
  dir/tests/t5
  dir/tests/t6
  dir/tests/t7
  dir/tests/t8
  dir/tests/t9

  $ cd ..

Testing the --narrowspec flag to clone

  $ cat >> narrowspecs <<EOF
  > %include foo
  > [include]
  > path:dir/tests/
  > path:dir/src/f12
  > EOF

  $ hg clone ssh://user@dummy/master specfile --narrowspec narrowspecs
  reading narrowspec from '$TESTTMP/narrowspecs'
  config error: cannot specify other files using '%include' in narrowspec
  [30]

  $ cat > narrowspecs <<EOF
  > [include]
  > path:dir/tests/
  > path:dir/src/f12
  > EOF

  $ hg clone ssh://user@dummy/master specfile --narrowspec narrowspecs
  reading narrowspec from '$TESTTMP/narrowspecs'
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 23 changesets with 21 changes to 21 files
  new changesets c13e3773edb4:26ce255d5b5d
  updating to branch default
  21 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd specfile
  $ hg tracked
  I path:dir/src/f12
  I path:dir/tests
  $ cd ..

Narrow spec with invalid patterns is rejected

  $ cat > narrowspecs <<EOF
  > [include]
  > glob:**
  > EOF

  $ hg clone ssh://user@dummy/master badspecfile --narrowspec narrowspecs
  reading narrowspec from '$TESTTMP/narrowspecs'
  abort: invalid prefix on narrow pattern: glob:**
  (narrow patterns must begin with one of the following: path:, rootfilesin:)
  [255]
