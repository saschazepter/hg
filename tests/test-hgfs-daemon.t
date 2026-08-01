#require rhg fuse

To run this test you need rhg built with `--features hgfs`.

  $ . "$TESTDIR/testlib/fuse-util.sh"

Use a per-test socket path.

  $ SOCK="$TESTTMP/hgfs.sock"

Setup repo
----------

  $ hg init source
  $ cd source
  $ echo a > a
  $ hg commit -Aqm0
  $ cd ..

Start the server
----------------

  $ hg debug::hgfs-server --socket "$SOCK" 2>error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"

Health ping
-----------

  $ hg debug::hgfs-client --socket "$SOCK" health
  Health: version=* pid=* (glob)

A second server on the same socket is refused
---------------------------------------------

  $ hg debug::hgfs-server --socket "$SOCK"
  abort: hgfs-server error: another hgfs-server already holds * (glob)
  [255]

Mount the clone
---------------

  $ mkdir mnt
  $ hg debug::hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  mounted */source at */mnt (created * UTC) (glob)
  $ wait_for_mount "hgvfs" "$TESTTMP/mnt"
  hgvfs on $TESTTMP/mnt type fuse (ro,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)
  $ ls "$TESTTMP/mnt"
  commits
  meta

Mounting again at the same point is rejected
--------------------------------------------

  $ hg debug::hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  abort: already mounted at * (glob)
  [255]

List shows the mount
--------------------

  $ hg debug::hgfs-client --socket "$SOCK" list
  */mnt clone=*/source created=* (glob)

Unmount
-------

  $ hg debug::hgfs-client --socket "$SOCK" unmount --mount "$TESTTMP/mnt"
  unmounted $TESTTMP/mnt
  $ mount | grep "hgvfs on $TESTTMP/mnt" || echo "not mounted"
  not mounted

List is now empty
-----------------

  $ hg debug::hgfs-client --socket "$SOCK" list
  no mounts

Unmounting an unknown path fails cleanly
----------------------------------------

  $ hg debug::hgfs-client --socket "$SOCK" unmount --mount "$TESTTMP/mnt"
  abort: nothing mounted at * (glob)
  [255]

Mounting a nonexistent mount point fails
----------------------------------------

  $ hg debug::hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/does-not-exist"
  abort: * (glob)
  [255]

Re-mount so graceful shutdown has a live mount to clean up.

  $ hg debug::hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  mounted */source at */mnt (created * UTC) (glob)

Stale socket file is cleaned up
-------------------------------

  $ STALE="$TESTTMP/stale.sock"
  $ touch "$STALE"
  $ hg debug::hgfs-server --socket "$STALE" 2>stale-error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$STALE"
  $ hg debug::hgfs-client --socket "$STALE" health
  Health: version=* pid=* (glob)

Graceful shutdown unmounts, removes the socket, and releases the lock
---------------------------------------------------------------------

  $ cd "$TESTTMP"
  $ killdaemons.py
  $ mount | grep "hgvfs on $TESTTMP/mnt" || echo "not mounted"
  not mounted
  $ test -S "$SOCK" || echo "socket removed"
  socket removed

A fresh server can reclaim the same socket
------------------------------------------

  $ hg debug::hgfs-server --socket "$SOCK" 2>error2.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"
  $ hg debug::hgfs-client --socket "$SOCK" health
  Health: version=* pid=* (glob)
