#require rhg fuse

To run this test you need rhg built with `--features hgfs`.

  $ . "$TESTDIR/testlib/fuse-util.sh"

  $ SOCK=/tmp/hgfs.sock
  $ rm -f "$SOCK"

Setup repo
----------

  $ hg init source
  $ cd source
  $ echo a > a
  $ hg commit -Aqm0
  $ cd ..

Start the server
----------------

  $ hg debug::hgfs-server 2>error.log >/dev/null &
  $ echo $! >> $DAEMON_PIDS
  $ "$RUNTESTDIR/testlib/wait-on-file" 30 "$SOCK"

Health ping
-----------

  $ hg debug::hgfs-client health
  Health: version=* pid=* (glob)

Mount the clone
---------------

  $ mkdir mnt
  $ hg debug::hgfs-client mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  mounted */source at */mnt (created * UTC) (glob)
  $ wait_for_mount "hgvfs" "$TESTTMP/mnt"
  hgvfs on $TESTTMP/mnt type fuse (ro,nosuid,nodev,noatime,user_id=*,group_id=*) (glob)
  $ ls "$TESTTMP/mnt"
  commits
  meta

Mounting again at the same point is rejected
--------------------------------------------

  $ hg debug::hgfs-client mount --clone "$TESTTMP/source" --mount "$TESTTMP/mnt"
  abort: hgfs-client error: already mounted at * (glob)
  [255]

Mounting a nonexistent mount point fails
----------------------------------------

  $ hg debug::hgfs-client mount --clone "$TESTTMP/source" --mount "$TESTTMP/does-not-exist"
  abort: hgfs-client error: * (glob)
  [255]

Cleanup
-------

  $ cd "$TESTTMP"
  $ fusermount -u "$TESTTMP/mnt"
