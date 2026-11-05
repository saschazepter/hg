#if no-windows
For debugging: this is a pretty simple test that is a good candidate
for tracking down network-related bugs. Sometimes a command in this
hangs, so having showstack pre-loaded is sometimes helpful. This also
gives us a test that at least proves showstack can be loaded.
  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > showstack = $TESTDIR/../contrib/showstack.py
  > EOF
#endif

  $ hg init test
  $ cd test
  $ echo a > a
  $ hg ci -Ama
  adding a
  $ cd ..
  $ hg clone test test2
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd test2
  $ echo a >> a
  $ hg ci -mb

Cloning with a password in the URL should not save the password in .hg/hgrc:

  $ hg serve -p $HGPORT -d --pid-file=hg.pid -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ hg clone http://foo:xyzzy@localhost:$HGPORT/ test3
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets cb9a9f314b8b:ba677d0156c1
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

The value we use, then the files it is stored in:

  $ hg -R test3 config paths.default
  http://foo@localhost:$HGPORT/

  $ cat test3/.hg/hgrc
  %include hgrc-managed
  # example repository config (see 'hg help config' for more info)
  #
  # Values are written for this repository with `hg config --local --set` and
  # dropped again with `hg config --local --del`, for instance a path alias to
  # another clone of it (see 'hg help config.paths' for more info):
  #
  #   hg config --local --set paths.default:pushurl=ssh://jdoe@example.net/fork
  #   hg config --local --set paths.my-fork=ssh://jdoe@example.net/hg/jdoes-fork
  #   hg config --local --set paths.my-clone=/home/jdoe/jdoes-clone
  #
  # or a name and email local to this repository:
  #
  #   hg config --local --set 'ui.username=Jane Doe <jdoe@example.com>'

  $ cat test3/.hg/hgrc-managed
  # This file is managed by Mercurial, do not edit it by hand.
  # Use `hg config --set` to change the values it holds.
  [paths]
  default = http://foo@localhost:$HGPORT/

  $ killdaemons.py

expect error, cloning not allowed

  $ echo '[web]' > .hg/hgrc
  $ echo 'allowpull = false' >> .hg/hgrc
  $ hg serve -p $HGPORT -d --pid-file=hg.pid -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ hg clone http://localhost:$HGPORT/ test4 # bundle2+
  abort: authorization failed
  [255]
  $ hg clone http://localhost:$HGPORT/ test4 --config devel.legacy.exchange=bundle1
  abort: authorization failed
  [255]
  $ killdaemons.py

serve errors

  $ cat errors.log
  $ req() {
  >     hg serve -p $HGPORT -d --pid-file=hg.pid -E errors.log
  >     cat hg.pid >> $DAEMON_PIDS
  >     hg --cwd ../test pull http://localhost:$HGPORT/
  >     killdaemons.py hg.pid
  >     echo % serve errors
  >     cat errors.log
  > }

expect error, pulling not allowed

  $ req
  pulling from http://localhost:$HGPORT/
  abort: authorization failed
  % serve errors

  $ cd ..
