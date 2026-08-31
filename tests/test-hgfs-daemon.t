#require jif fuse

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

  $ jf hgfs-server --socket "$SOCK" 2>error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"

Health ping
-----------

  $ jf hgfs-client --socket "$SOCK" health
  Health: version=* pid=* (glob)

A second server on the same socket is refused
---------------------------------------------

  $ jf hgfs-server --socket "$SOCK"
  abort: another hgfs-server already holds * (glob)
  [255]

Mount the clone
---------------

  $ mkdir mnt
  $ jf hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  mounted */source at */mnt (created * UTC) (glob)
  $ wait_for_mount "hgvfs" "$TESTTMP/mnt"
  hgvfs on $TESTTMP/mnt type fuse (rw,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)
  $ stat "$TESTTMP/mnt" >/dev/null
  stat: cannot statx '$TESTTMP/mnt': Function not implemented (known-bad-output !)
  [1]
  $ ls "$TESTTMP/mnt"
  ls: cannot access '$TESTTMP/mnt': Function not implemented (known-bad-output !)
  [2]

Mounting again at the same point is rejected
--------------------------------------------

  $ jf hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  abort: already mounted at * (glob)
  [255]

List shows the mount
--------------------

  $ jf hgfs-client --socket "$SOCK" list
  */mnt clone=*/source created=* (glob)

Unmount
-------

  $ jf hgfs-client --socket "$SOCK" unmount --mount "$TESTTMP/mnt"
  unmounted $TESTTMP/mnt
  $ mount | grep "hgvfs on $TESTTMP/mnt" || echo "not mounted"
  not mounted

List is now empty
-----------------

  $ jf hgfs-client --socket "$SOCK" list
  no mounts

Unmounting an unknown path fails cleanly
----------------------------------------

  $ jf hgfs-client --socket "$SOCK" unmount --mount "$TESTTMP/mnt"
  abort: nothing mounted at * (glob)
  [255]

Mounting a nonexistent mount point fails
----------------------------------------

  $ jf hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/does-not-exist"
  abort: * (glob)
  [255]

Re-mount so graceful shutdown has a live mount to clean up.

  $ jf hgfs-client --socket "$SOCK" mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  mounted */source at */mnt (created * UTC) (glob)

Stale socket file is cleaned up
-------------------------------

  $ STALE="$TESTTMP/stale.sock"
  $ touch "$STALE"
  $ jf hgfs-server --socket "$STALE" 2>stale-error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$STALE"
  $ jf hgfs-client --socket "$STALE" health
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

  $ jf hgfs-server --socket "$SOCK" 2>error2.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"
  $ jf hgfs-client --socket "$SOCK" health
  Health: version=* pid=* (glob)
