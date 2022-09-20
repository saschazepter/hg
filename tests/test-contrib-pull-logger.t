Check that the pull logger plugins logs pulls
=============================================

Enable the extension

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "pull-logger = $TESTDIR/../contrib/pull_logger.py" >> $HGRCPATH


Check the format of the generated log entries, with a bunch of elements in the
common and heads set

  $ hg init server
  $ hg -R server debugbuilddag '.*2+2'
  $ hg clone ssh://user@dummy/server client --rev 0
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ tail -1 server/.hg/pull_log.jsonl
  {"common": ["0000000000000000000000000000000000000000"], "heads": ["1ea73414a91b0920940797d8fc6a11e447f8ea1e"], "logger_version": 0, "timestamp": *} (glob)
  $ hg -R client pull --rev 1 --rev 2
  pulling from ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files (+1 heads)
  new changesets d8736c3a2c84:fa28e81e283b
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ tail -1 server/.hg/pull_log.jsonl
  {"common": ["1ea73414a91b0920940797d8fc6a11e447f8ea1e"], "heads": ["d8736c3a2c84ee759a2821385804bcb67f266ade", "fa28e81e283b3416de4d48ee0dd2d446e9e38d7c"], "logger_version": 0, "timestamp": *} (glob)
  $ hg -R client pull --rev 2 --rev 3
  pulling from ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 944641ddcaef
  (run 'hg update' to get a working copy)
  $ tail -1 server/.hg/pull_log.jsonl
  {"common": ["1ea73414a91b0920940797d8fc6a11e447f8ea1e", "fa28e81e283b3416de4d48ee0dd2d446e9e38d7c"], "heads": ["944641ddcaef174df7ce1bc2751a5f165129778b", "fa28e81e283b3416de4d48ee0dd2d446e9e38d7c"], "logger_version": 0, "timestamp": *} (glob)


Check the number of entries generated in the log when pulling from multiple
clients at the same time

  $ rm -f server/.hg/pull_log.jsonl
  $ for i in $($TESTDIR/seq.py 32); do
  >   hg clone ssh://user@dummy/server client_$i --rev 0
  > done > /dev/null
  $ for i in $($TESTDIR/seq.py 32); do
  >   hg -R client_$i pull --rev 1 &
  > done > /dev/null
  $ wait
  $ wc -l server/.hg/pull_log.jsonl
  \s*64 .* (re)


Test log rotation when reaching some size threshold

  $ cat >> $HGRCPATH << EOF
  > [pull-logger]
  > rotate-size = 1kb
  > EOF

  $ rm -f server/.hg/pull_log.jsonl
  $ for i in $($TESTDIR/seq.py 10); do
  >   hg -R client pull --rev 1
  > done > /dev/null
  $ wc -l server/.hg/pull_log.jsonl
  \s*3 .* (re)
  $ wc -l server/.hg/pull_log.jsonl.rotated
  \s*7 .* (re)
