# This python code can be imported into tests in order to terminate a process
# with signal.SIGKILL on posix, or a roughly equivalent procedure on Windows.

from __future__ import annotations

import os
import signal
import subprocess
import sys

from .. import (
    encoding,
    pycompat,
)

from ..utils import procutil


def kill_nt(pid: int, exit_code: int):
    env = dict(encoding.environ)
    env[b"DAEMON_EXITCODE"] = b"%d" % exit_code

    # Simulate the message written to stderr for this process on non-Windows
    # platforms, for test consistency.
    print("Killed!", file=sys.stderr)

    subprocess.run(
        [
            encoding.environ[b"PYTHON"],
            b"%s/killdaemons.py"
            % encoding.environ[b'RUNTESTDIR_FORWARD_SLASH'],
            "-",
        ],
        env=procutil.tonativeenv(env),
        input=b"%d\n" % pid,
    )


def kill(pid: int):
    """Kill the process with the given PID with SIGKILL or equivalent."""
    if pycompat.iswindows:
        exit_code = 128 + 9
        kill_nt(pid, exit_code)
    else:
        os.kill(pid, signal.SIGKILL)
