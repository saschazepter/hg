#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ hg debugrequires -R master | grep generaldelta
  generaldelta
  $ cd master
preferuncompressed = False so that we can make both generaldelta and non-generaldelta clones
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > [experimental]
  > bundle2-exp = True
  > [server]
  > preferuncompressed = False
  > EOF
  $ echo x > x
  $ hg commit -qAm x

  $ cd ..

  $ hgcloneshallow ssh://user@dummy/master shallow-generaldelta -q --pull --config experimental.bundle2-exp=True
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
  $ hg debugrequires -R shallow-generaldelta/ | grep generaldelta
  generaldelta
  $ hgcloneshallow ssh://user@dummy/master shallow-plain -q --pull --config format.usegeneraldelta=False --config format.generaldelta=False --config experimental.bundle2-exp=True
  $ hg debugrequires -R shallow-plain/ | grep generaldelta
  [1]

  $ cd master
  $ echo a > a
  $ hg commit -qAm a

pull from generaldelta to generaldelta
  $ cd ../shallow-generaldelta
  $ hg pull -u
  pulling from ssh://user@dummy/master
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 2fbb8bb2b903
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
push from generaldelta to generaldelta
  $ echo b > b
  $ hg commit -qAm b
  $ hg push
  pushing to ssh://user@dummy/master
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
pull from generaldelta to non-generaldelta
  $ cd ../shallow-plain
  $ hg pull -u
  pulling from ssh://user@dummy/master
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  new changesets 2fbb8bb2b903:d6788bd632ca
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
push from non-generaldelta to generaldelta
  $ echo c > c
  $ hg commit -qAm c
  $ hg push
  pushing to ssh://user@dummy/master
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
