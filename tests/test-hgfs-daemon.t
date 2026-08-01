#require rhg

To run this test you need rhg built with `--features hgfs`.

  $ SOCK=/tmp/hgfs.sock
  $ rm -f "$SOCK"

Start the server
----------------

  $ hg debug::hgfs-server 2>error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"

Health ping
-----------

  $ hg debug::hgfs-client
  Health: version=* pid=* (glob)
