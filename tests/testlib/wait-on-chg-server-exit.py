#!/usr/bin/env python3
#
# wait until chg command servers noticed they lost their socket and terminated
#
# usage: wait-on-chg-server-exit.py [--all] LOG-FILE SOCKET-DIR
#
# Scan LOG-FILE (a "cmdserver.log" file, with its rotated variants) to detect
# the pids of the started servers.
#
# Then wait for these servers to stop, except the most recent one. If
# --all is passed, all servers are waited for, including the last one.
#
# Use --all after breaking the ownership of the current server's socket, and
# the default form after an operation that replaced the current server (the
# latest server is then the replacement, expected to stay alive).
#
# The wait gives up after $CHGTIMEOUT ×2 seconds (default: 60 × 2).

from __future__ import annotations

import os
import re
import sys
import time

from typing import (
    Iterator,
)


def server_log_files(log_path) -> Iterator[str]:
    """yield the server log file and its rotated variants, oldest first"""
    rotated = []
    i = 1
    while True:
        path = '%s.%d' % (log_path, i)
        if not os.path.exists(path):
            break
        rotated.append(path)
        i += 1
    yield from reversed(rotated)
    yield log_path


def all_servers(log_path: str, socket_dir: str) -> list[int]:
    """started-pids as recorded in the log, in started order"""
    prefix = r'\((\d+)\)> %s' % re.escape(socket_dir)
    re_start = re.compile(prefix + r'.* now owned, serving\.$')
    started = []
    for path in server_log_files(log_path):
        try:
            with open(path) as f:
                for line in f:
                    line = line.rstrip('\n')
                    m = re_start.search(line)
                    if m:
                        started.append(int(m.group(1)))
        except FileNotFoundError:
            continue
    return started


def is_alive(pid: int) -> bool:
    """return True if process with `pid` is still running"""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def main(args):
    wait_on_all = False
    if args and args[0] == '--all':
        wait_on_all = True
        args = args[1:]
    if len(args) != 2:
        msg = 'USAGE: wait-on-chg-server-exit.py [--all] LOG-FILE SOCKET-DIR'
        print(msg, file=sys.stderr)
        return 64
    log_path, socket_dir = args
    timeout = float(os.environ.get('CHGTIMEOUT', 60)) * 2
    deadline = time.monotonic() + timeout
    while time.monotonic() <= deadline:
        doomed = all_servers(log_path, socket_dir)
        if not doomed:
            print('no process to wait for?', file=sys.stderr)
            return 2
        if not wait_on_all:
            doomed.pop()
        if all(not is_alive(p) for p in doomed):
            break
        time.sleep(0.1)
    else:
        print('timed out waiting for chg server shutdowns', file=sys.stderr)
        return 3
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
