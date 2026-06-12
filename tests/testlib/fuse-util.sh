
wait_for_mount() {
    iterations=0
    maxiterations=50
    while ! (mount | grep "$1 on $2") && [ $iterations -lt $maxiterations ]
    do
        sleep 0.1
        iterations=`expr $iterations + 1`
    done
    [ $iterations -ge $maxiterations ] && echo "timed out waiting for the FUSE to mount" || true
}

mount_FUSE() {
    FUSE_ROOT="$1"; shift
    hg debug::virtual-share $FUSE_ROOT --pid-file=$TESTTMP/fuse.pid 2>error.log &
    wait_for_mount "hgvfs" "$FUSE_ROOT"
    cat $TESTTMP/fuse.pid >> $DAEMON_PIDS
    cat error.log
}
