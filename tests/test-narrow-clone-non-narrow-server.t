Test attempting a narrow clone against a server that doesn't support narrowhg.

  $ . "$TESTDIR/narrow-library.sh"

  $ hg init master
  $ cd master

  $ for x in `$TESTDIR/seq.py 10`; do
  >   echo $x > "f$x"
  >   hg add "f$x"
  >   hg commit -m "Add $x"
  > done

  $ hg serve -a localhost -p $HGPORT1 --config extensions.narrow=! -d \
  >    --pid-file=hg.pid
  $ cat hg.pid >> "$DAEMON_PIDS"
  $ hg serve -a localhost -p $HGPORT2 -d --pid-file=hg.pid
  $ cat hg.pid >> "$DAEMON_PIDS"

Verify that narrow is advertised in the bundle2 capabilities:
  $ echo hello | hg -R . serve --stdio | \
  >   python -c "import sys, urllib; print urllib.unquote_plus(list(sys.stdin)[1])" | grep narrow
  narrow=v0

  $ cd ..

  $ hg clone --narrow --include f1 http://localhost:$HGPORT1/ narrowclone
  requesting all changes
  abort: server doesn't support narrow clones
  [255]

Make a narrow clone (via HGPORT2), then try to narrow and widen
into it (from HGPORT1) to prove that narrowing is fine and widening fails
gracefully:
  $ hg clone -r 0 --narrow --include f1 http://localhost:$HGPORT2/ narrowclone
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets * (glob)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd narrowclone
  $ hg tracked --addexclude f2 http://localhost:$HGPORT1/
  comparing with http://localhost:$HGPORT1/
  searching for changes
  looking for local changes to affected paths
  $ hg tracked --addinclude f1 http://localhost:$HGPORT1/
  comparing with http://localhost:$HGPORT1/
  searching for changes
  no changes found
  abort: server doesn't support narrow clones
  [255]
