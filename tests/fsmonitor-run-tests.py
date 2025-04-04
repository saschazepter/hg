#!/usr/bin/env python3

# fsmonitor-run-tests.py - Run Mercurial tests with fsmonitor enabled
#
# Copyright 2017 Facebook, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This is a wrapper around run-tests.py that spins up an isolated instance of
# Watchman and runs the Mercurial tests against it. This ensures that the global
# version of Watchman isn't affected by anything this test does.


import argparse
import contextlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

osenvironb = getattr(os, 'environb', os.environ)

# Don't compare sys.version_info directly, to prevent pyupgrade from dropping
# the conditional.
sys_version_info = sys.version_info

if sys_version_info >= (3, 8, 0):

    def _sys2bytes(p):
        return p.encode('utf-8')

else:
    print(
        '%s is only supported on Python 3.8+, not %s'
        % (sys.argv[0], '.'.join(str(v) for v in sys.version_info[:3]))
    )
    sys.exit(70)  # EX_SOFTWARE from `man 3 sysexit`


def getparser():
    """Obtain the argument parser used by the CLI."""
    parser = argparse.ArgumentParser(
        description='Run tests with fsmonitor enabled.',
        epilog='Unrecognized options are passed to run-tests.py.',
    )
    # - keep these sorted
    # - none of these options should conflict with any in run-tests.py
    parser.add_argument(
        '--keep-fsmonitor-tmpdir',
        action='store_true',
        help='keep temporary directory with fsmonitor state',
    )
    parser.add_argument(
        '--watchman',
        help='location of watchman binary (default: watchman in PATH)',
        default='watchman',
    )

    return parser


@contextlib.contextmanager
def watchman(args):
    basedir = tempfile.mkdtemp(prefix='hg-fsmonitor')
    try:
        # Much of this configuration is borrowed from Watchman's test harness.
        cfgfile = os.path.join(basedir, 'config.json')
        # TODO: allow setting a config
        with open(cfgfile, 'w') as f:
            f.write(json.dumps({}))

        logfile = os.path.join(basedir, 'log')
        clilogfile = os.path.join(basedir, 'cli-log')
        if os.name == 'nt':
            sockfile = '\\\\.\\pipe\\watchman-test-%s' % uuid.uuid4().hex
        else:
            sockfile = os.path.join(basedir, 'sock')
        pidfile = os.path.join(basedir, 'pid')
        statefile = os.path.join(basedir, 'state')

        argv = [
            args.watchman,
            '--sockname',
            sockfile,
            '--logfile',
            logfile,
            '--pidfile',
            pidfile,
            '--statefile',
            statefile,
            '--foreground',
            '--log-level=2',  # debug logging for watchman
        ]

        envb = osenvironb.copy()
        envb[b'WATCHMAN_CONFIG_FILE'] = _sys2bytes(cfgfile)
        with open(clilogfile, 'wb') as f:
            proc = subprocess.Popen(
                argv, env=envb, stdin=None, stdout=f, stderr=f
            )
            try:
                yield sockfile
            finally:
                proc.terminate()
                proc.kill()
    finally:
        if args.keep_fsmonitor_tmpdir:
            print('fsmonitor dir available at %s' % basedir)
        else:
            shutil.rmtree(basedir, ignore_errors=True)


def run():
    parser = getparser()
    args, runtestsargv = parser.parse_known_args()

    with watchman(args) as sockfile:
        osenvironb[b'WATCHMAN_SOCK'] = _sys2bytes(sockfile)
        # Indicate to hghave that we're running with fsmonitor enabled.
        osenvironb[b'HGFSMONITOR_TESTS'] = b'1'

        runtestdir = os.path.dirname(__file__)
        runtests = os.path.join(runtestdir, 'run-tests.py')
        blacklist = os.path.join(runtestdir, 'blacklists', 'fsmonitor')

        runtestsargv.insert(0, runtests)
        runtestsargv.extend(
            [
                '--extra-config',
                'extensions.fsmonitor=',
                # specify fsmonitor.mode=paranoid always in order to force
                # fsmonitor extension execute "paranoid" code path
                #
                # TODO: make fsmonitor-run-tests.py accept specific options
                '--extra-config',
                'fsmonitor.mode=paranoid',
                '--blacklist',
                blacklist,
            ]
        )

        return subprocess.call(runtestsargv)


if __name__ == '__main__':
    sys.exit(run())
