get_file_fingerprint() {
    if [ "$#" -ne 1 ]; then
        printf 'USAGE: get_file_fingerprint FILE\n' >&2
        return 2
    fi

    # Get device, inode, mtime, and ctime.
    stat -c '%d:%i:%y:%z' -- "$1"
}

# Wait until the file fingerprint has changed.
wait_on_changed() {
    if [ "$#" -ne 3 ]; then
        printf 'USAGE: wait_on_changed TIMEOUT FILE FINGERPRINT\n' >&2
        return 2
    fi

    timeout="$1"
    wait_on="$2"
    old_fingerprint="$3"

    # If the test timeout have been extended, also scale the timer relative
    # to the normal timing.
    percentage=${HGTEST_TIMEOUT_PERCENTAGE:-100}
    if [ "$percentage" -gt 100 ]; then
        timeout=$((timeout * percentage / 100))
    fi
    # Scale the timeout to match the sleep steps below, i.e. 1/0.02.
    remaining=$((50 * timeout))

    while [ "$remaining" -gt 0 ]; do
        if fingerprint=$(get_file_fingerprint "$wait_on" 2>/dev/null) &&
            [ "$fingerprint" != "$old_fingerprint" ]; then
            return 0
        fi

        remaining=$((remaining - 1))
        sleep 0.02
    done

    echo "file unchanged or missing after $timeout seconds: $wait_on" >&2
    return 1
}
