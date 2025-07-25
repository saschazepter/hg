#!/usr/bin/env python3
#
# run-tests.py - Run a set of tests on Mercurial
#
# Copyright 2006 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

# Modifying this script is tricky because it has many modes:
#   - serial (default) vs parallel (-jN, N > 1)
#   - no coverage (default) vs coverage (-c, -C, -s)
#   - temp install (default) vs specific hg script (--with-hg, --local)
#   - tests are a mix of shell scripts and Python scripts
#
# If you change this script, it is recommended that you ensure you
# haven't broken it by running it in various modes with a representative
# sample of test scripts.  For example:
#
#  1) serial, no coverage, temp install:
#      ./run-tests.py test-s*
#  2) serial, no coverage, local hg:
#      ./run-tests.py --local test-s*
#  3) serial, coverage, temp install:
#      ./run-tests.py -c test-s*
#  4) serial, coverage, local hg:
#      ./run-tests.py -c --local test-s*      # unsupported
#  5) parallel, no coverage, temp install:
#      ./run-tests.py -j2 test-s*
#  6) parallel, no coverage, local hg:
#      ./run-tests.py -j2 --local test-s*
#  7) parallel, coverage, temp install:
#      ./run-tests.py -j2 -c test-s*          # currently broken
#  8) parallel, coverage, local install:
#      ./run-tests.py -j2 -c --local test-s*  # unsupported (and broken)
#  9) parallel, custom tmp dir:
#      ./run-tests.py -j2 --tmpdir /tmp/myhgtests
#  10) parallel, pure, tests that call run-tests:
#      ./run-tests.py --pure `grep -l run-tests.py *.t`
#
# (You could use any subset of the tests: test-s* happens to match
# enough that it's worth doing parallel runs, few enough that it
# completes fairly quickly, includes both shell and Python scripts, and
# includes some scripts that run daemon processes.)


import argparse
import collections
import contextlib
import difflib

import errno
import functools
import json
import multiprocessing
import os
import pathlib
import platform
import queue
import random
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import sysconfig
import tempfile
import threading
import time
import unittest
import uuid
import xml.dom.minidom as minidom

# Don't compare sys.version_info directly, to prevent pyupgrade from dropping
# the conditional.
sys_version_info = sys.version_info

if sys_version_info < (3, 8, 0):
    print(
        '%s is only supported on Python 3.8+, not %s'
        % (sys.argv[0], '.'.join(str(v) for v in sys.version_info[:3]))
    )
    sys.exit(70)  # EX_SOFTWARE from `man 3 sysexit`

MACOS = sys.platform == 'darwin'
WINDOWS = os.name == r'nt'
shellquote = shlex.quote
BINDIRNAME = b"Scripts" if WINDOWS else b"bin"

# The number of HGPORTx ports allocated to each test.
HGPORT_COUNT = 4

RUNTEST_DIR = os.path.abspath(os.path.dirname(__file__.encode('utf-8')))
RUNTEST_DIR_FORWARD_SLASH = RUNTEST_DIR.replace(os.sep.encode('utf-8'), b'/')


processlock = threading.Lock()

pygmentspresent = False
try:  # is pygments installed
    import pygments
    import pygments.lexers as lexers
    import pygments.lexer as lexer
    import pygments.formatters as formatters
    import pygments.token as token
    import pygments.style as style
    from pygments.console import ansiformat

    if WINDOWS:
        hgpath = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        sys.path.append(hgpath)
        try:
            from mercurial import win32  # pytype: disable=import-error

            # Don't check the result code because it fails on heptapod, but
            # something is able to convert to color anyway.
            win32.enablevtmode()
        finally:
            sys.path = sys.path[:-1]

    pygmentspresent = True
    difflexer = lexers.DiffLexer()
    terminal256formatter = formatters.Terminal256Formatter()

    def colorize(text: str, style: str, color: bool = True) -> str:
        if not color:
            return text
        return ansiformat(style, text)

except ImportError:

    def colorize(text: str, style: str, color: bool = True) -> str:
        return text


progress_type = {}

if pygmentspresent:
    _T_ERROR = token.string_to_tokentype("Token.Generic.Error")
    _T_FAILED = token.string_to_tokentype("Token.Generic.Failed")
    _T_FNAME = token.string_to_tokentype("Token.Generic.FName")
    _T_IGNORED = token.string_to_tokentype("Token.Generic.Ignored")
    _T_SKIPPED = token.string_to_tokentype("Token.Generic.Skipped")
    _T_SNAME = token.string_to_tokentype("Token.Generic.SName")
    _T_SKIPPED_DOT = token.string_to_tokentype("Token.Generic.SkippedDot")
    _T_SUCCESS = token.string_to_tokentype("Token.Generic.Success")
    _T_TIMEDOUT = token.string_to_tokentype("Token.Generic.TimedOut")

    class TestRunnerStyle(style.Style):
        default_style = ""
        styles = {
            _T_ERROR: '#cd00cd',
            _T_FAILED: '#7f0000',
            _T_FNAME: '#ff0000',
            _T_IGNORED: '#cdcd00',
            _T_SKIPPED: '#e5e5e5',
            _T_SNAME: '#00ffff',
            _T_SKIPPED_DOT: '#00ffff',
            _T_SUCCESS: '#00cd00',
            _T_TIMEDOUT: '#ff00ff',
        }

    class TestRunnerLexer(lexer.RegexLexer):
        testpattern = r'[\w-]+\.(t|py)(#[a-zA-Z0-9_\-\.]+)?'
        tokens = {
            'root': [
                (r'^Skipped', _T_SKIPPED, 'skipped'),
                (r'^Failed ', _T_FAILED, 'failed'),
                (r'^ERROR: ', _T_FAILED, 'failed'),
            ],
            'skipped': [
                (testpattern, _T_SNAME),
                (r':.*', _T_SKIPPED),
            ],
            'failed': [
                (testpattern, _T_FNAME),
                (r'(:| ).*', _T_FAILED),
            ],
        }

    progress_type['.'] = _T_SUCCESS
    progress_type['s'] = _T_SKIPPED_DOT
    progress_type['i'] = _T_IGNORED
    progress_type['!'] = _T_FAILED
    progress_type['E'] = _T_ERROR
    progress_type['t'] = _T_TIMEDOUT

    class progressLexer(lexer.RegexLexer):
        testpattern = r'[\w-]+\.(t|py)(#[a-zA-Z0-9_\-\.]+)?'
        tokens = {
            'root': [
                (r'^Skipped', _T_SKIPPED, 'skipped'),
                (r'^Failed ', _T_FAILED, 'failed'),
                (r'^ERROR: ', _T_FAILED, 'failed'),
            ],
            'skipped': [
                (testpattern, _T_SNAME),
                (r':.*', _T_SKIPPED),
            ],
            'failed': [
                (testpattern, _T_FNAME),
                (r'(:| ).*', _T_FAILED),
            ],
        }

    runnerformatter = formatters.Terminal256Formatter(style=TestRunnerStyle)
    runnerlexer = TestRunnerLexer()

origenviron = os.environ.copy()


def _sys2bytes(p):
    if p is None:
        return p
    return p.encode('utf-8')


def _bytes2sys(p):
    if p is None:
        return p
    return p.decode('utf-8')


original_env = os.environ.copy()
osenvironb = getattr(os, 'environb', None)
if osenvironb is None:
    # Windows lacks os.environb, for instance.  A proxy over the real thing
    # instead of a copy allows the environment to be updated via bytes on
    # all platforms.
    class environbytes:
        def __init__(self, strenv):
            self.__len__ = strenv.__len__
            self.clear = strenv.clear
            self._strenv = strenv

        def __getitem__(self, k):
            v = self._strenv.__getitem__(_bytes2sys(k))
            return _sys2bytes(v)

        def __setitem__(self, k, v):
            self._strenv.__setitem__(_bytes2sys(k), _bytes2sys(v))

        def __delitem__(self, k):
            self._strenv.__delitem__(_bytes2sys(k))

        def __contains__(self, k):
            return self._strenv.__contains__(_bytes2sys(k))

        def __iter__(self):
            return iter([_sys2bytes(k) for k in iter(self._strenv)])

        def get(self, k, default=None):
            v = self._strenv.get(_bytes2sys(k), _bytes2sys(default))
            return _sys2bytes(v)

        def pop(self, k, default=None):
            v = self._strenv.pop(_bytes2sys(k), _bytes2sys(default))
            return _sys2bytes(v)

    osenvironb = environbytes(os.environ)

getcwdb = getattr(os, 'getcwdb')
if not getcwdb or WINDOWS:
    getcwdb = lambda: _sys2bytes(os.getcwd())


if WINDOWS:
    _getcwdb = getcwdb

    def getcwdb():
        cwd = _getcwdb()
        if re.match(b'^[a-z]:', cwd):
            # os.getcwd() is inconsistent on the capitalization of the drive
            # letter, so adjust it. see https://bugs.python.org/issue40368
            cwd = cwd[0:1].upper() + cwd[1:]
        return cwd


# For Windows support
wifexited = getattr(os, "WIFEXITED", lambda x: False)


# Whether to use IPv6
def checksocketfamily(name, port=20058):
    """return true if we can listen on localhost using family=name

    name should be either 'AF_INET', or 'AF_INET6'.
    port being used is okay - EADDRINUSE is considered as successful.
    """
    family = getattr(socket, name, None)
    if family is None:
        return False
    try:
        s = socket.socket(family, socket.SOCK_STREAM)
        s.bind(('localhost', port))
        s.close()
        return True
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            return True
        elif exc.errno in (
            errno.EADDRNOTAVAIL,
            errno.EPROTONOSUPPORT,
            errno.EAFNOSUPPORT,
        ):
            return False
        else:
            raise
    else:
        return False


# useipv6 will be set by parseargs
useipv6 = None


def checkportisavailable(port):
    """return true if a port seems free to bind on localhost"""
    if useipv6:
        family = socket.AF_INET6
    else:
        family = socket.AF_INET
    try:
        with contextlib.closing(socket.socket(family, socket.SOCK_STREAM)) as s:
            s.bind(('localhost', port))
        return True
    except PermissionError:
        return False
    except OSError as exc:
        if WINDOWS and exc.errno == errno.WSAEACCES:
            return False
        if exc.errno not in (
            errno.EADDRINUSE,
            errno.EADDRNOTAVAIL,
            errno.EPROTONOSUPPORT,
        ):
            raise
    return False


closefds = os.name == 'posix'


def Popen4(cmd, wd, timeout, env=None):
    processlock.acquire()
    p = subprocess.Popen(
        _bytes2sys(cmd),
        shell=True,
        bufsize=-1,
        cwd=_bytes2sys(wd),
        env=env,
        close_fds=closefds,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    processlock.release()

    p.fromchild = p.stdout
    p.tochild = p.stdin
    p.childerr = p.stderr

    p.timeout = False
    if timeout:

        def t():
            start = time.time()
            while time.time() - start < timeout and p.returncode is None:
                time.sleep(0.1)
            if p.returncode is None:
                p.timeout = True
                vlog('# Timout reached for process %d' % p.pid)
                terminate(p)

        threading.Thread(target=t).start()

    return p


default_defaults = {
    'jobs': ('HGTEST_JOBS', multiprocessing.cpu_count()),
    'timeout': ('HGTEST_TIMEOUT', 360 if not WINDOWS else 360 * 4),
    'slowtimeout': ('HGTEST_SLOWTIMEOUT', 1500),
    'port': ('HGTEST_PORT', 20059),
    'shell': ('HGTEST_SHELL', 'sh'),
}

defaults = default_defaults.copy()


def canonpath(path):
    return os.path.realpath(os.path.expanduser(path))


def parselistfiles(files, listtype, warn=True):
    entries = dict()
    for filename in files:
        try:
            path = os.path.expanduser(os.path.expandvars(filename))
            f = open(path, "rb")
        except FileNotFoundError:
            if warn:
                print("warning: no such %s file: %s" % (listtype, filename))
            continue

        for line in f.readlines():
            line = line.split(b'#', 1)[0].strip()
            if line:
                # Ensure path entries are compatible with os.path.relpath()
                entries[os.path.normpath(line)] = filename

        f.close()
    return entries


def parsettestcases(path):
    """read a .t test file, return a set of test case names

    If path does not exist, return an empty set.
    """
    cases = []
    try:
        with open(path, 'rb') as f:
            for l in f:
                if l.startswith(b'#testcases '):
                    cases.append(sorted(l[11:].split()))
    except FileNotFoundError:
        pass
    return cases


def getparser():
    """Obtain the OptionParser used by the CLI."""
    parser = argparse.ArgumentParser(usage='%(prog)s [options] [tests]')

    def validate_wheel_path(wheel):
        """Validate the wheel path and convert to abspath early."""
        if wheel:
            wheel = os.path.realpath(wheel)
            if not os.path.exists(wheel):
                raise argparse.ArgumentTypeError(
                    "wheel does not exist: %r" % wheel
                )
        return wheel

    selection = parser.add_argument_group('Test Selection')
    selection.add_argument(
        '--allow-slow-tests',
        action='store_true',
        help='allow extremely slow tests',
    )
    selection.add_argument(
        "--blacklist",
        action="append",
        help="skip tests listed in the specified blacklist file",
    )
    selection.add_argument(
        "--shard-total",
        type=int,
        default=None,
        help="total number of shard to use (enable sharding)",
    )
    selection.add_argument(
        "--shard-index",
        type=int,
        default=None,
        help="index of this shard [1-N]",
    )
    selection.add_argument(
        "--changed",
        help="run tests that are changed in parent rev or working directory",
    )
    selection.add_argument(
        "-k", "--keywords", help="run tests matching keywords"
    )
    selection.add_argument(
        "-r", "--retest", action="store_true", help="retest failed tests"
    )
    selection.add_argument(
        "--test-list",
        action="append",
        help="read tests to run from the specified file",
    )
    selection.add_argument(
        "--whitelist",
        action="append",
        help="always run tests listed in the specified whitelist file",
    )
    selection.add_argument(
        'tests', metavar='TESTS', nargs='*', help='Tests to run'
    )

    harness = parser.add_argument_group('Test Harness Behavior')
    harness.add_argument(
        "-d",
        "--debug",
        action="store_true",
        help="debug mode: write output of test scripts to console"
        " rather than capturing and diffing it (disables timeout)",
    )
    harness.add_argument(
        "-f",
        "--first",
        action="store_true",
        help="exit on the first test failure",
    )
    harness.add_argument(
        "-i",
        "--interactive",
        action="store_true",
        help="prompt to accept changed output",
    )
    harness.add_argument(
        "-j",
        "--jobs",
        type=int,
        help="number of jobs to run in parallel"
        " (default: $%s or %d)" % defaults['jobs'],
    )
    harness.add_argument(
        "--keep-tmpdir",
        action="store_true",
        help="keep temporary directory after running tests",
    )
    harness.add_argument(
        "--list-tests",
        action="store_true",
        help="list tests instead of running them",
    )
    harness.add_argument(
        "--loop", action="store_true", help="loop tests repeatedly"
    )
    harness.add_argument(
        '--random', action="store_true", help='run tests in random order'
    )
    harness.add_argument(
        '--order-by-runtime',
        action="store_true",
        help='run slowest tests first, according to .testtimes',
    )
    harness.add_argument(
        "-p",
        "--port",
        type=int,
        help="port on which servers should listen"
        " (default: $%s or %d)" % defaults['port'],
    )
    harness.add_argument(
        '--profile-runner',
        action='store_true',
        help='run statprof on run-tests',
    )
    harness.add_argument(
        "-R", "--restart", action="store_true", help="restart at last error"
    )
    harness.add_argument(
        "--runs-per-test",
        type=int,
        dest="runs_per_test",
        help="run each test N times (default=1)",
        default=1,
    )
    harness.add_argument(
        "--shell", help="shell to use (default: $%s or %s)" % defaults['shell']
    )
    harness.add_argument(
        '--showchannels', action='store_true', help='show scheduling channels'
    )
    harness.add_argument(
        "--slowtimeout",
        type=int,
        help="kill errant slow tests after SLOWTIMEOUT seconds"
        " (default: $%s or %d)" % defaults['slowtimeout'],
    )
    harness.add_argument(
        "-t",
        "--timeout",
        type=int,
        help="kill errant tests after TIMEOUT seconds"
        " (default: $%s or %d)" % defaults['timeout'],
    )
    harness.add_argument(
        "--tmpdir",
        help="run tests in the given temporary directory"
        " (implies --keep-tmpdir)",
    )
    harness.add_argument(
        "-v", "--verbose", action="store_true", help="output verbose messages"
    )

    hgconf = parser.add_argument_group('Mercurial Configuration')
    hgconf.add_argument(
        "--chg",
        action="store_true",
        help="install and use chg wrapper in place of hg",
    )
    hgconf.add_argument(
        "--chg-debug",
        action="store_true",
        help="show chg debug logs",
    )
    hgconf.add_argument(
        "--rhg",
        action="store_true",
        help="install and use rhg Rust implementation in place of hg",
    )
    hgconf.add_argument(
        "--pyoxidized",
        action="store_true",
        help="build the hg binary using pyoxidizer",
    )
    hgconf.add_argument(
        '--extra-config-opt',
        action="append",
        default=[],
        help='set the given config opt in the test hgrc',
    )
    hgconf.add_argument(
        "-l",
        "--local",
        action="store_true",
        help="shortcut for --with-hg=<testdir>/../hg, "
        "--with-rhg=<testdir>/../rust/target/release/rhg if --rhg is set, "
        "and --with-chg=<testdir>/../contrib/chg/chg if --chg is set",
    )
    hgconf.add_argument(
        "--ipv6",
        action="store_true",
        help="prefer IPv6 to IPv4 for network related tests",
    )
    hgconf.add_argument(
        "--hg-wheel",
        default=None,
        type=validate_wheel_path,
        metavar="WHEEL_PATH",
        dest="wheel",
        help="install mercurial from the given wheel",
    )
    hgconf.add_argument(
        "--pure",
        action="store_true",
        help="use pure Python code instead of C extensions",
    )
    hgconf.add_argument(
        "--rust",
        action="store_true",
        help="use Rust code alongside C extensions",
    )
    hgconf.add_argument(
        "--no-rust",
        action="store_true",
        help="do not use Rust code even if compiled",
    )
    hgconf.add_argument(
        "--with-chg",
        metavar="CHG",
        help="use specified chg wrapper in place of hg",
    )
    hgconf.add_argument(
        "--with-rhg",
        metavar="RHG",
        help="use specified rhg Rust implementation in place of hg",
    )
    hgconf.add_argument(
        "--with-hg",
        metavar="HG",
        help="test using specified hg script rather than a "
        "temporary installation",
    )

    reporting = parser.add_argument_group('Results Reporting')
    reporting.add_argument(
        "-C",
        "--annotate",
        action="store_true",
        help="output files annotated with coverage",
    )
    reporting.add_argument(
        "--color",
        choices=["always", "auto", "never"],
        default=os.environ.get('HGRUNTESTSCOLOR', 'auto'),
        help="colorisation: always|auto|never (default: auto)",
    )
    reporting.add_argument(
        "-c",
        "--cover",
        action="store_true",
        help="print a test coverage report",
    )
    reporting.add_argument(
        '--exceptions',
        action='store_true',
        help='log all exceptions and generate an exception report',
    )
    reporting.add_argument(
        "-H",
        "--htmlcov",
        action="store_true",
        help="create an HTML report of the coverage of the files",
    )
    reporting.add_argument(
        "--json",
        action="store_true",
        help="store test result data in 'report.json' file",
    )
    reporting.add_argument(
        "--outputdir",
        help="directory to write error logs to (default=test directory)",
    )
    reporting.add_argument(
        "-n", "--nodiff", action="store_true", help="skip showing test changes"
    )
    reporting.add_argument(
        "-S",
        "--noskips",
        action="store_true",
        help="don't report skip tests verbosely",
    )
    reporting.add_argument(
        "--time", action="store_true", help="time how long each test takes"
    )
    reporting.add_argument(
        "--tail-report",
        action="store_true",
        help="display information about the final test of each thread",
    )
    reporting.add_argument("--view", help="external diff viewer")
    reporting.add_argument(
        "--xunit", help="record xunit results at specified path"
    )

    for option, (envvar, default) in defaults.items():
        defaults[option] = type(default)(os.environ.get(envvar, default))
    parser.set_defaults(**defaults)

    return parser


def parseargs(args, parser):
    """Parse arguments with our OptionParser and validate results."""
    options = parser.parse_args(args)

    # jython is always pure
    if 'java' in sys.platform or '__pypy__' in sys.modules:
        options.pure = True

    if platform.python_implementation() != 'CPython' and options.rust:
        parser.error('Rust extensions are only available with CPython')

    if options.pure and options.rust:
        parser.error('--rust cannot be used with --pure')

    if options.rust and options.no_rust:
        parser.error('--rust cannot be used with --no-rust')

    if options.local:
        if options.with_hg or options.with_rhg or options.with_chg:
            parser.error(
                '--local cannot be used with --with-hg or --with-rhg or --with-chg'
            )
        if options.pyoxidized:
            parser.error('--pyoxidized does not work with --local (yet)')
        testdir = os.path.dirname(_sys2bytes(canonpath(sys.argv[0])))
        reporootdir = os.path.dirname(testdir)
        venv_local = b'.venv_%s%d.%d' % (
            sys.implementation.name.encode(),
            sys.version_info.major,
            sys.version_info.minor,
        )
        path_local_hg = os.path.join(reporootdir, venv_local, BINDIRNAME, b"hg")
        if not os.path.exists(path_local_hg):
            if "HGTEST_REAL_HG" in os.environ:
                # this file is run from a test (typically test-run-tests.t)
                # no local environment but we can still use ./hg to please test-run-tests.t
                path_local_hg = os.path.join(reporootdir, b"hg")
            else:
                message = (
                    f"run-tests.py called with --local but {_bytes2sys(venv_local)} does not exist.\n"
                    f'To create it, run \nmake local PYTHON="{sys.executable}"'
                )
                paths_venv = sorted(
                    pathlib.Path(_bytes2sys(reporootdir)).glob(".venv_*")
                )
                if paths_venv:
                    message += (
                        "\nAlternatively, call run-tests.py with a Python "
                        f"corresponding to {[p.name for p in paths_venv]}."
                    )
                print(message, file=sys.stderr)
                sys.exit(1)

        pathandattrs = [(path_local_hg, 'with_hg')]
        if options.chg:
            pathandattrs.append((b'contrib/chg/chg', 'with_chg'))
        if options.rhg:
            pathandattrs.append((b'rust/target/release/rhg', 'with_rhg'))
        for relpath, attr in pathandattrs:
            binpath = os.path.join(reporootdir, relpath)
            if not (WINDOWS or os.access(binpath, os.X_OK)):
                parser.error(
                    '--local specified, but %r not found or '
                    'not executable' % binpath
                )
            setattr(options, attr, _bytes2sys(binpath))

    if options.with_hg:
        options.with_hg = canonpath(_sys2bytes(options.with_hg))
        if not (
            os.path.isfile(options.with_hg)
            and os.access(options.with_hg, os.X_OK)
        ):
            parser.error('--with-hg must specify an executable hg script')
        if os.path.basename(options.with_hg) not in [b'hg', b'hg.exe']:
            msg = 'warning: --with-hg should specify an hg script, not: %s\n'
            msg %= _bytes2sys(os.path.basename(options.with_hg))
            sys.stderr.write(msg)
            sys.stderr.flush()

    if (options.chg or options.with_chg) and WINDOWS:
        parser.error('chg does not work on %s' % os.name)
    if (options.rhg or options.with_rhg) and WINDOWS:
        parser.error('rhg does not work on %s' % os.name)
    if options.pyoxidized and not (MACOS or WINDOWS):
        parser.error('--pyoxidized is currently macOS and Windows only')
    if options.with_chg:
        options.chg = False  # no installation to temporary location
        options.with_chg = canonpath(_sys2bytes(options.with_chg))
        if not (
            os.path.isfile(options.with_chg)
            and os.access(options.with_chg, os.X_OK)
        ):
            parser.error('--with-chg must specify a chg executable')
    if options.with_rhg:
        options.rhg = False  # no installation to temporary location
        options.with_rhg = canonpath(_sys2bytes(options.with_rhg))
        if not (
            os.path.isfile(options.with_rhg)
            and os.access(options.with_rhg, os.X_OK)
        ):
            parser.error('--with-rhg must specify a rhg executable')
    if options.chg and options.with_hg:
        # chg shares installation location with hg
        parser.error(
            '--chg does not work when --with-hg is specified '
            '(use --with-chg instead)'
        )
    if options.rhg and options.with_hg:
        # rhg shares installation location with hg
        parser.error(
            '--rhg does not work when --with-hg is specified '
            '(use --with-rhg instead)'
        )
    if options.rhg and options.chg:
        parser.error('--rhg and --chg do not work together')

    if options.color == 'always' and not pygmentspresent:
        sys.stderr.write(
            'warning: --color=always ignored because '
            'pygments is not installed\n'
        )

    global useipv6
    if options.ipv6:
        useipv6 = checksocketfamily('AF_INET6')
    else:
        # only use IPv6 if IPv4 is unavailable and IPv6 is available
        useipv6 = (not checksocketfamily('AF_INET')) and checksocketfamily(
            'AF_INET6'
        )

    options.anycoverage = options.cover or options.annotate or options.htmlcov
    if options.anycoverage:
        try:
            import coverage

            coverage.__version__  # silence unused import warning
        except ImportError:
            parser.error('coverage options now require the coverage package')

    if options.anycoverage and options.local:
        # this needs some path mangling somewhere, I guess
        parser.error(
            "sorry, coverage options do not work when --local " "is specified"
        )

    if options.anycoverage and options.with_hg:
        parser.error(
            "sorry, coverage options do not work when --with-hg " "is specified"
        )

    global verbose
    if options.verbose:
        verbose = ''

    if options.tmpdir:
        options.tmpdir = canonpath(options.tmpdir)

    if options.jobs < 1:
        parser.error('--jobs must be positive')
    if options.interactive and options.debug:
        parser.error("-i/--interactive and -d/--debug are incompatible")
    if options.debug:
        if options.timeout != defaults['timeout']:
            sys.stderr.write('warning: --timeout option ignored with --debug\n')
        if options.slowtimeout != defaults['slowtimeout']:
            sys.stderr.write(
                'warning: --slowtimeout option ignored with --debug\n'
            )
        options.timeout = 0
        options.slowtimeout = 0

    if options.blacklist:
        options.blacklist = parselistfiles(options.blacklist, 'blacklist')
    if options.whitelist:
        options.whitelisted = parselistfiles(options.whitelist, 'whitelist')
    else:
        options.whitelisted = {}

    if options.showchannels:
        options.nodiff = True

    if options.shard_total is not None:
        if options.shard_index is None:
            parser.error("--shard-total requires --shard-index to be set")

    if options.shard_index is not None:
        if options.shard_total is None:
            parser.error("--shard-index requires --shard-total to be set")
        elif options.shard_index <= 0:
            msg = "--shard-index must be > 0 (%d)"
            msg %= options.shard_index
            parser.error(msg)
        elif options.shard_index > options.shard_total:
            msg = (
                "--shard-index must be <= than --shard-total (%d not in [1,%d])"
            )
            msg %= (options.shard_index, options.shard_total)
            parser.error(msg)

    if options.shard_total is not None and options.order_by_runtime:
        msg = "cannot use --order-by-runtime when sharding"
        parser.error(msg)

    if options.shard_total is not None and options.random:
        msg = "cannot use --random when sharding"
        parser.error(msg)

    return options


def rename(src, dst):
    """Like os.rename(), trade atomicity and opened files friendliness
    for existing destination support.
    """
    shutil.copy(src, dst)
    os.remove(src)


def makecleanable(path):
    """Try to fix directory permission recursively so that the entire tree
    can be deleted"""
    for dirpath, dirnames, _filenames in os.walk(path, topdown=True):
        for d in dirnames:
            p = os.path.join(dirpath, d)
            try:
                os.chmod(p, os.stat(p).st_mode & 0o777 | 0o700)  # chmod u+rwx
            except OSError:
                pass


_unified_diff = functools.partial(difflib.diff_bytes, difflib.unified_diff)


def getdiff(expected, output, ref, err):
    servefail = False
    lines = []
    for line in _unified_diff(expected, output, ref, err):
        if line.startswith(b'+++') or line.startswith(b'---'):
            line = line.replace(b'\\', b'/')
            if line.endswith(b' \n'):
                line = line[:-2] + b'\n'
        lines.append(line)
        if not servefail and line.startswith(
            b'+  abort: child process failed to start'
        ):
            servefail = True

    return servefail, lines


verbose = False


def vlog(*msg):
    """Log only when in verbose mode."""
    if verbose is False:
        return

    return log(*msg)


# Bytes that break XML even in a CDATA block: control characters 0-31
# sans \t, \n and \r
CDATA_EVIL = re.compile(br"[\000-\010\013\014\016-\037]")

# Match feature conditionalized output lines in the form, capturing the feature
# list in group 2, and the preceeding line output in group 1:
#
#   output..output (feature !)\n
optline = re.compile(br'(.*) \((.+?) !\)\n$')


def cdatasafe(data):
    """Make a string safe to include in a CDATA block.

    Certain control characters are illegal in a CDATA block, and
    there's no way to include a ]]> in a CDATA either. This function
    replaces illegal bytes with ? and adds a space between the ]] so
    that it won't break the CDATA block.
    """
    return CDATA_EVIL.sub(b'?', data).replace(b']]>', b'] ]>')


def log(*msg):
    """Log something to stdout.

    Arguments are strings to print.
    """
    with iolock:
        if verbose:
            print(verbose, end=' ')
        for m in msg:
            print(m, end=' ')
        print()
        sys.stdout.flush()


def highlightdiff(line, color):
    if not color:
        return line
    assert pygmentspresent
    return pygments.highlight(
        line.decode('latin1'), difflexer, terminal256formatter
    ).encode('latin1')


def highlightmsg(msg, color):
    if not color:
        return msg
    assert pygmentspresent
    return pygments.highlight(msg, runnerlexer, runnerformatter)


def highlight_progress(progress, color):
    if not color:
        return progress
    assert pygmentspresent
    token = progress_type.get(progress)
    if token is None:
        return progress
    style = runnerformatter.style_string.get(str(token))
    if style is None:
        return progress
    else:
        return style[0] + progress + style[1]


def terminate(proc):
    """Terminate subprocess"""
    vlog('# Terminating process %d' % proc.pid)
    try:
        proc.terminate()
    except OSError:
        pass


def killdaemons(pidfile):
    import killdaemons as killmod

    return killmod.killdaemons(pidfile, tryhard=False, remove=True, logfn=vlog)


# sysconfig is not thread-safe (https://github.com/python/cpython/issues/92452)
sysconfiglock = threading.Lock()


class Test(unittest.TestCase):
    """Encapsulates a single, runnable test.

    While this class conforms to the unittest.TestCase API, it differs in that
    instances need to be instantiated manually. (Typically, unittest.TestCase
    classes are instantiated automatically by scanning modules.)
    """

    # Status code reserved for skipped tests (used by hghave).
    SKIPPED_STATUS = 80

    def __init__(
        self,
        path,
        outputdir,
        tmpdir,
        keeptmpdir=False,
        debug=False,
        first=False,
        timeout=None,
        startport=None,
        extraconfigopts=None,
        shell=None,
        python=None,
        hgcommand=None,
        slowtimeout=None,
        usechg=False,
        chgdebug=False,
        useipv6=False,
    ):
        """Create a test from parameters.

        path is the full path to the file defining the test.

        tmpdir is the main temporary directory to use for this test.

        keeptmpdir determines whether to keep the test's temporary directory
        after execution. It defaults to removal (False).

        debug mode will make the test execute verbosely, with unfiltered
        output.

        timeout controls the maximum run time of the test. It is ignored when
        debug is True. See slowtimeout for tests with #require slow.

        slowtimeout overrides timeout if the test has #require slow.

        startport controls the starting port number to use for this test. Each
        test will reserve 3 port numbers for execution. It is the caller's
        responsibility to allocate a non-overlapping port range to Test
        instances.

        extraconfigopts is an iterable of extra hgrc config options. Values
        must have the form "key=value" (something understood by hgrc). Values
        of the form "foo.key=value" will result in "[foo] key=value".

        shell is the shell to execute tests in.
        """
        if timeout is None:
            timeout = defaults['timeout']
        if startport is None:
            startport = defaults['port']
        if slowtimeout is None:
            slowtimeout = defaults['slowtimeout']
        self.path = path
        self.relpath = os.path.relpath(path)
        self.bname = os.path.basename(path)
        self.name = _bytes2sys(self.bname)
        self._testdir = os.path.dirname(path)
        self._outputdir = outputdir
        self._tmpname = os.path.basename(path)
        self.errpath = os.path.join(self._outputdir, b'%s.err' % self.bname)

        self._threadtmp = tmpdir
        self._keeptmpdir = keeptmpdir
        self._debug = debug
        self._first = first
        self._timeout = timeout
        self._slowtimeout = slowtimeout
        self._startport = startport
        self._extraconfigopts = extraconfigopts or []
        self._shell = _sys2bytes(shell)
        assert python is not None
        self._python = python
        self._hgcommand = hgcommand or b'hg'
        self._usechg = usechg
        self._chgdebug = chgdebug
        self._useipv6 = useipv6

        self._aborted = False
        self._daemonpids = []
        self._finished = None
        self._ret = None
        self._out = None
        self._skipped = None
        self._testtmp = None
        self._chgsockdir = None

        self._refout = self.readrefout()

    @property
    def _pythonb(self):
        return _sys2bytes(self._python.replace('\\', '/'))

    def readrefout(self):
        """read reference output"""
        # If we're not in --debug mode and reference output file exists,
        # check test output against it.
        if self._debug:
            return None  # to match "out is None"
        elif os.path.exists(self.refpath):
            with open(self.refpath, 'rb') as f:
                return f.read().splitlines(True)
        else:
            return []

    # needed to get base class __repr__ running
    @property
    def _testMethodName(self):
        return self.name

    def __str__(self):
        return self.name

    def shortDescription(self):
        return self.name

    def setUp(self):
        """Tasks to perform before run()."""
        self._finished = False
        self._ret = None
        self._out = None
        self._skipped = None

        try:
            os.mkdir(self._threadtmp)
        except FileExistsError:
            pass

        name = self._tmpname
        self._testtmp = os.path.join(self._threadtmp, name)
        os.mkdir(self._testtmp)

        # Remove any previous output files.
        if os.path.exists(self.errpath):
            try:
                os.remove(self.errpath)
            except FileNotFoundError:
                # We might have raced another test to clean up a .err file,
                # so ignore FileNotFoundError when removing a previous .err
                # file.
                pass

        if self._usechg:
            self._chgsockdir = os.path.join(
                self._threadtmp, b'%s.chgsock' % name
            )
            os.mkdir(self._chgsockdir)

    def run(self, result):
        """Run this test and report results against a TestResult instance."""
        # This function is extremely similar to unittest.TestCase.run(). Once
        # we require Python 2.7 (or at least its version of unittest), this
        # function can largely go away.
        self._result = result
        result.startTest(self)
        try:
            try:
                self.setUp()
            except (KeyboardInterrupt, SystemExit):
                self._aborted = True
                raise
            except Exception:
                result.addError(self, sys.exc_info())
                return

            success = False
            try:
                self.runTest()
            except KeyboardInterrupt:
                self._aborted = True
                raise
            except unittest.SkipTest as e:
                result.addSkip(self, str(e))
                # The base class will have already counted this as a
                # test we "ran", but we want to exclude skipped tests
                # from those we count towards those run.
                result.testsRun -= 1
            except self.failureException as e:
                # This differs from unittest in that we don't capture
                # the stack trace. This is for historical reasons and
                # this decision could be revisited in the future,
                # especially for PythonTest instances.
                if result.addFailure(self, str(e)):
                    success = True
            except Exception:
                result.addError(self, sys.exc_info())
            else:
                success = True

            try:
                self.tearDown()
            except (KeyboardInterrupt, SystemExit):
                self._aborted = True
                raise
            except Exception:
                result.addError(self, sys.exc_info())
                success = False

            if success:
                result.addSuccess(self)
        finally:
            result.stopTest(self, interrupted=self._aborted)

    def runTest(self):
        """Run this test instance.

        This will return a tuple describing the result of the test.
        """
        env = self._getenv()
        self._genrestoreenv(env)
        self._daemonpids.append(env['DAEMON_PIDS'])
        self._createhgrc(env['HGRCPATH'])

        vlog('# Test', self.name)

        ret, out = self._run(env)
        self._finished = True
        self._ret = ret
        self._out = out

        def describe(ret):
            if ret < 0:
                return 'killed by signal: %d' % -ret
            return 'returned error code %d' % ret

        self._skipped = False

        if ret == self.SKIPPED_STATUS:
            if out is None:  # Debug mode, nothing to parse.
                missing = ['unknown']
                failed = None
            else:
                missing, failed = TTest.parsehghaveoutput(out)

            if not missing:
                missing = ['skipped']

            if failed:
                self.fail('hg have failed checking for %s' % failed[-1])
            else:
                self._skipped = True
                raise unittest.SkipTest(missing[-1])
        elif ret == 'timeout':
            self.fail('timed out')
        elif ret is False:
            self.fail('no result code from test')
        elif out != self._refout:
            # Diff generation may rely on written .err file.
            if (
                (ret != 0 or out != self._refout)
                and not self._skipped
                and not self._debug
            ):
                with open(self.errpath, 'wb') as f:
                    for line in out:
                        f.write(line)

            # The result object handles diff calculation for us.
            with firstlock:
                if self._result.addOutputMismatch(self, ret, out, self._refout):
                    # change was accepted, skip failing
                    return
                if self._first:
                    global firsterror
                    firsterror = True

            if ret:
                msg = 'output changed and ' + describe(ret)
            else:
                msg = 'output changed'

            self.fail(msg)
        elif ret:
            self.fail(describe(ret))

    def tearDown(self):
        """Tasks to perform after run()."""
        for entry in self._daemonpids:
            killdaemons(entry)
        self._daemonpids = []

        if self._keeptmpdir:
            log(
                '\nKeeping testtmp dir: %s\nKeeping threadtmp dir: %s'
                % (
                    _bytes2sys(self._testtmp),
                    _bytes2sys(self._threadtmp),
                )
            )
        else:
            try:
                shutil.rmtree(self._testtmp)
            except OSError:
                # unreadable directory may be left in $TESTTMP; fix permission
                # and try again
                makecleanable(self._testtmp)
                shutil.rmtree(self._testtmp, True)
            shutil.rmtree(self._threadtmp, True)

        if self._usechg:
            # chgservers will stop automatically after they find the socket
            # files are deleted
            shutil.rmtree(self._chgsockdir, True)

        if (
            (self._ret != 0 or self._out != self._refout)
            and not self._skipped
            and not self._debug
            and self._out
        ):
            with open(self.errpath, 'wb') as f:
                for line in self._out:
                    f.write(line)

        vlog("# Ret was:", self._ret, '(%s)' % self.name)

    def _run(self, env):
        # This should be implemented in child classes to run tests.
        raise unittest.SkipTest('unknown test type')

    def abort(self):
        """Terminate execution of this test."""
        self._aborted = True

    def _portmap(self, i):
        offset = b'' if i == 0 else b'%d' % i
        return (br':%d\b' % (self._startport + i), b':$HGPORT%s' % offset)

    def _getreplacements(self):
        """Obtain a mapping of text replacements to apply to test output.

        Test output needs to be normalized so it can be compared to expected
        output. This function defines how some of that normalization will
        occur.
        """
        r = [self._portmap(port) for port in range(HGPORT_COUNT)]

        r.extend(
            [
                (br'([^0-9])%s' % re.escape(self._localip()), br'\1$LOCALIP'),
                (br'\bHG_TXNID=TXN:[a-f0-9]{40}\b', br'HG_TXNID=TXN:$ID$'),
                (self._escapepath(self._testtmp), b'$TESTTMP'),
            ]
        )

        if WINDOWS:
            # JSON output escapes backslashes in Windows paths, so also catch a
            # double-escape.
            replaced = self._testtmp.replace(b'\\', br'\\')
            r.append((self._escapepath(replaced), b'$STR_REPR_TESTTMP'))

        replacementfile = os.path.join(self._testdir, b'common-pattern.py')

        if os.path.exists(replacementfile):
            data = {}
            with open(replacementfile, mode='rb') as source:
                # the intermediate 'compile' step help with debugging
                code = compile(source.read(), replacementfile, 'exec')
                exec(code, data)
                for value in data.get('substitutions', ()):
                    if len(value) != 2:
                        msg = 'malformatted substitution in %s: %r'
                        msg %= (replacementfile, value)
                        raise ValueError(msg)
                    r.append(value)
        return r

    def _escapepath(self, p):
        if WINDOWS:
            return b''.join(
                c.isalpha()
                and b'[%s%s]' % (c.lower(), c.upper())
                or c in b'/\\'
                and br'[/\\]'
                or c.isdigit()
                and c
                or b'\\' + c
                for c in [p[i : i + 1] for i in range(len(p))]
            )
        else:
            return re.escape(p)

    def _localip(self):
        if self._useipv6:
            return b'::1'
        else:
            return b'127.0.0.1'

    def _genrestoreenv(self, testenv):
        """Generate a script that can be used by tests to restore the original
        environment."""
        # Put the restoreenv script inside self._threadtmp
        scriptpath = os.path.join(self._threadtmp, b'restoreenv.sh')
        testenv['HGTEST_RESTOREENV'] = _bytes2sys(scriptpath)

        # Only restore environment variable names that the shell allows
        # us to export.
        name_regex = re.compile('^[a-zA-Z][a-zA-Z0-9_]*$')

        # Do not restore these variables; otherwise tests would fail.
        reqnames = {'PYTHON', 'TESTDIR', 'TESTTMP'}

        with open(scriptpath, 'w') as envf:
            for name, value in origenviron.items():
                if not name_regex.match(name):
                    # Skip environment variables with unusual names not
                    # allowed by most shells.
                    continue
                if name in reqnames:
                    continue
                envf.write('%s=%s\n' % (name, shellquote(value)))

            for name in testenv:
                if name in origenviron or name in reqnames:
                    continue
                envf.write('unset %s\n' % (name,))

    def _getenv(self):
        """Obtain environment variables to use during test execution."""

        def defineport(i):
            offset = '' if i == 0 else '%s' % i
            env["HGPORT%s" % offset] = '%s' % (self._startport + i)

        env = os.environ.copy()
        with sysconfiglock:
            env['PYTHONUSERBASE'] = sysconfig.get_config_var('userbase') or ''
        env['HGEMITWARNINGS'] = '1'
        env['TESTTMP'] = _bytes2sys(self._testtmp)
        # the FORWARD_SLASH version is useful when running `sh` on non unix
        # system (e.g. Windows)
        env['TESTTMP_FORWARD_SLASH'] = env['TESTTMP'].replace(os.sep, '/')
        uid_file = os.path.join(_bytes2sys(self._testtmp), 'UID')
        env['HGTEST_UUIDFILE'] = uid_file
        env['TESTNAME'] = self.name
        env['HOME'] = _bytes2sys(self._testtmp)
        if WINDOWS:
            env['REALUSERPROFILE'] = env['USERPROFILE']
            # py3.8+ ignores HOME: https://bugs.python.org/issue36264
            env['USERPROFILE'] = env['HOME']
        formated_timeout = _bytes2sys(b"%d" % default_defaults['timeout'][1])
        env['HGTEST_TIMEOUT_DEFAULT'] = formated_timeout
        env['HGTEST_TIMEOUT'] = _bytes2sys(b"%d" % self._timeout)

        for port in range(HGPORT_COUNT):
            defineport(port)
        env["HGRCPATH"] = _bytes2sys(os.path.join(self._threadtmp, b'.hgrc'))
        env["DAEMON_PIDS"] = _bytes2sys(
            os.path.join(self._threadtmp, b'daemon.pids')
        )
        env["HGEDITOR"] = f'"{self._python}" -c "import sys; sys.exit(0)"'
        env["HGUSER"] = "test"
        env["HGENCODING"] = "ascii"
        env["HGENCODINGMODE"] = "strict"
        env["HGHOSTNAME"] = "test-hostname"
        env['HGIPV6'] = str(int(self._useipv6))
        # See contrib/catapipe.py for how to use this functionality.
        if 'HGTESTCATAPULTSERVERPIPE' not in env:
            # If we don't have HGTESTCATAPULTSERVERPIPE explicitly set, pull the
            # non-test one in as a default, otherwise set to devnull
            env['HGTESTCATAPULTSERVERPIPE'] = env.get(
                'HGCATAPULTSERVERPIPE', os.devnull
            )

        extraextensions = []
        for opt in self._extraconfigopts:
            section, key = opt.split('.', 1)
            if section != 'extensions':
                continue
            name = key.split('=', 1)[0]
            extraextensions.append(name)

        if extraextensions:
            env['HGTESTEXTRAEXTENSIONS'] = ' '.join(extraextensions)

        # LOCALIP could be ::1 or 127.0.0.1. Useful for tests that require raw
        # IP addresses.
        env['LOCALIP'] = _bytes2sys(self._localip())

        # This has the same effect as Py_LegacyWindowsStdioFlag in exewrapper.c,
        # but this is needed for testing python instances like dummyssh,
        # dummysmtpd.py, and dumbhttp.py.
        if WINDOWS:
            env['PYTHONLEGACYWINDOWSSTDIO'] = '1'

        # Modified HOME in test environment can confuse Rust tools. So set
        # CARGO_HOME and RUSTUP_HOME automatically if a Rust toolchain is
        # present and these variables aren't already defined.
        cargo_home_path = os.path.expanduser('~/.cargo')
        rustup_home_path = os.path.expanduser('~/.rustup')

        if os.path.exists(cargo_home_path) and b'CARGO_HOME' not in osenvironb:
            env['CARGO_HOME'] = cargo_home_path
        if (
            os.path.exists(rustup_home_path)
            and b'RUSTUP_HOME' not in osenvironb
        ):
            env['RUSTUP_HOME'] = rustup_home_path

        # Reset some environment variables to well-known values so that
        # the tests produce repeatable output.
        env['LANG'] = env['LC_ALL'] = env['LANGUAGE'] = 'C'
        env['TZ'] = 'GMT'
        env["EMAIL"] = "Foo Bar <foo.bar@example.com>"
        env['COLUMNS'] = '80'
        env['TERM'] = 'xterm'

        dropped = [
            'CDPATH',
            'CHGDEBUG',
            'EDITOR',
            'GREP_OPTIONS',
            'HG',
            'HGMERGE',
            'HGPLAIN',
            'HGPLAINEXCEPT',
            'HGPROF',
            'http_proxy',
            'no_proxy',
            'NO_PROXY',
            'PAGER',
            'VISUAL',
        ]

        for k in dropped:
            if k in env:
                del env[k]

        # unset env related to hooks
        for k in list(env):
            if k.startswith('HG_'):
                del env[k]

        if self._usechg:
            env['CHGSOCKNAME'] = os.path.join(self._chgsockdir, b'server')
        if self._chgdebug:
            env['CHGDEBUG'] = 'true'

        return env

    def _createhgrc(self, path):
        """Create an hgrc file for this test."""
        with open(path, 'wb') as hgrc:
            hgrc.write(b'[ui]\n')
            hgrc.write(b'slash = True\n')
            hgrc.write(b'interactive = False\n')
            hgrc.write(b'detailed-exit-code = True\n')
            hgrc.write(b'merge = internal:merge\n')
            hgrc.write(b'mergemarkers = detailed\n')
            hgrc.write(b'promptecho = True\n')
            dummyssh = os.path.join(self._testdir, b'dummyssh')
            hgrc.write(b'ssh = "%s" "%s"\n' % (self._pythonb, dummyssh))
            hgrc.write(b'timeout.warn=15\n')
            hgrc.write(b'[chgserver]\n')
            hgrc.write(b'idletimeout=60\n')
            hgrc.write(b'[defaults]\n')
            hgrc.write(b'[devel]\n')
            hgrc.write(b'all-warnings = true\n')
            hgrc.write(b'default-date = 0 0\n')
            hgrc.write(b'[largefiles]\n')
            hgrc.write(
                b'usercache = %s\n'
                % (os.path.join(self._testtmp, b'.cache/largefiles'))
            )
            hgrc.write(b'[lfs]\n')
            hgrc.write(
                b'usercache = %s\n'
                % (os.path.join(self._testtmp, b'.cache/lfs'))
            )
            hgrc.write(b'[web]\n')
            hgrc.write(b'address = localhost\n')
            hgrc.write(b'ipv6 = %r\n' % self._useipv6)
            hgrc.write(b'server-header = testing stub value\n')

            for opt in self._extraconfigopts:
                section, key = _sys2bytes(opt).split(b'.', 1)
                assert b'=' in key, (
                    'extra config opt %s must ' 'have an = for assignment' % opt
                )
                hgrc.write(b'[%s]\n%s\n' % (section, key))

    def fail(self, msg):
        # unittest differentiates between errored and failed.
        # Failed is denoted by AssertionError (by default at least).
        raise AssertionError(msg)

    def _runcommand(self, cmd, env, normalizenewlines=False):
        """Run command in a sub-process, capturing the output (stdout and
        stderr).

        Return a tuple (exitcode, output). output is None in debug mode.
        """
        if self._debug:
            proc = subprocess.Popen(
                _bytes2sys(cmd),
                shell=True,
                close_fds=closefds,
                cwd=_bytes2sys(self._testtmp),
                env=env,
            )
            ret = proc.wait()
            return (ret, None)

        proc = Popen4(cmd, self._testtmp, self._timeout, env)

        def cleanup():
            terminate(proc)
            ret = proc.wait()
            if ret == 0:
                ret = signal.SIGTERM << 8
            killdaemons(env['DAEMON_PIDS'])
            return ret

        proc.tochild.close()

        try:
            output = proc.fromchild.read()
        except KeyboardInterrupt:
            vlog('# Handling keyboard interrupt')
            cleanup()
            raise

        ret = proc.wait()
        if wifexited(ret):
            ret = os.WEXITSTATUS(ret)

        if proc.timeout:
            ret = 'timeout'

        if ret:
            killdaemons(env['DAEMON_PIDS'])

        for s, r in self._getreplacements():
            output = re.sub(s, r, output)

        if normalizenewlines:
            output = output.replace(b'\r\n', b'\n')

        return ret, output.splitlines(True)


class PythonTest(Test):
    """A Python-based test."""

    @property
    def refpath(self):
        return os.path.join(self._testdir, b'%s.out' % self.bname)

    def _run(self, env):
        # Quote the python(3) executable for Windows
        cmd = b'"%s" "%s"' % (self._pythonb, self.path)
        vlog("# Running", cmd.decode("utf-8"))
        result = self._runcommand(cmd, env, normalizenewlines=WINDOWS)
        if self._aborted:
            raise KeyboardInterrupt()

        return result


# Some glob patterns apply only in some circumstances, so the script
# might want to remove (glob) annotations that otherwise should be
# retained.
checkcodeglobpats = [
    # On Windows it looks like \ doesn't require a (glob), but we know
    # better.
    re.compile(br'^pushing to \$TESTTMP/.*[^)]$'),
    re.compile(br'^moving \S+/.*[^)]$'),
    re.compile(br'^pulling from \$TESTTMP/.*[^)]$'),
    # Not all platforms have 127.0.0.1 as loopback (though most do),
    # so we always glob that too.
    re.compile(br'.*\$LOCALIP.*$'),
]

bchr = lambda x: bytes([x])

WARN_UNDEFINED = 1
WARN_YES = 2
WARN_NO = 3

MARK_OPTIONAL = b" (?)\n"


def isoptional(line):
    return line.endswith(MARK_OPTIONAL)


class TTest(Test):
    """A "t test" is a test backed by a .t file."""

    SKIPPED_PREFIX = b'skipped: '
    FAILED_PREFIX = b'hghave check failed: '
    NEEDESCAPE = re.compile(br'[\x00-\x08\x0b-\x1f\x7f-\xff]').search

    ESCAPESUB = re.compile(br'[\x00-\x08\x0b-\x1f\\\x7f-\xff]').sub
    ESCAPEMAP = {bchr(i): br'\x%02x' % i for i in range(256)}
    ESCAPEMAP.update({b'\\': b'\\\\', b'\r': br'\r'})

    def __init__(self, path, *args, **kwds):
        # accept an extra "case" parameter
        case = kwds.pop('case', [])
        self._case = case
        self._allcases = {x for y in parsettestcases(path) for x in y}
        super().__init__(path, *args, **kwds)
        if case:
            casepath = b'#'.join(case)
            self.name = '%s#%s' % (self.name, _bytes2sys(casepath))
            self.errpath = b'%s#%s.err' % (self.errpath[:-4], casepath)
            self._tmpname += b'-%s' % casepath.replace(b'#', b'-')
        self._have = {}

    @property
    def refpath(self):
        return os.path.join(self._testdir, self.bname)

    def _run(self, env):
        with open(self.path, 'rb') as f:
            lines = f.readlines()

        # .t file is both reference output and the test input, keep reference
        # output updated with the the test input. This avoids some race
        # conditions where the reference output does not match the actual test.
        if self._refout is not None:
            self._refout = lines

        salt, script, after, expected = self._parsetest(lines)

        # Write out the generated script.
        fname = b'%s.sh' % self._testtmp
        with open(fname, 'wb') as f:
            for l in script:
                f.write(l)

        cmd = b'%s "%s"' % (self._shell, fname)
        vlog("# Running", cmd.decode("utf-8"))

        exitcode, output = self._runcommand(cmd, env)

        if self._aborted:
            raise KeyboardInterrupt()

        # Do not merge output if skipped. Return hghave message instead.
        # Similarly, with --debug, output is None.
        if exitcode == self.SKIPPED_STATUS or output is None:
            return exitcode, output

        return self._processoutput(exitcode, output, salt, after, expected)

    def _hghave(self, reqs):
        allreqs = b' '.join(reqs)

        self._detectslow(reqs)

        if allreqs in self._have:
            return self._have.get(allreqs)

        # TODO do something smarter when all other uses of hghave are gone.
        cmd = b'%s -c "%s/hghave %s"'
        cmd %= (self._shell, RUNTEST_DIR_FORWARD_SLASH, allreqs)
        proc = Popen4(
            cmd,
            self._testtmp,
            0,
            self._getenv(),
        )
        stdout, stderr = proc.communicate()
        ret = proc.wait()
        if wifexited(ret):
            ret = os.WEXITSTATUS(ret)
        if ret == 2:
            print(stdout.decode('utf-8'))
            sys.exit(1)

        if ret != 0:
            self._have[allreqs] = (False, stdout)
            return False, stdout

        self._have[allreqs] = (True, None)
        return True, None

    def _detectslow(self, reqs):
        """update the timeout of slow test when appropriate"""
        if b'slow' in reqs:
            self._timeout = self._slowtimeout

    def _iftest(self, args):
        # implements "#if"
        reqs = []
        for arg in args:
            if arg.startswith(b'no-') and arg[3:] in self._allcases:
                if arg[3:] in self._case:
                    return False
            elif arg in self._allcases:
                if arg not in self._case:
                    return False
            else:
                reqs.append(arg)
        self._detectslow(reqs)
        return self._hghave(reqs)[0]

    def _parsetest(self, lines):
        # We generate a shell script which outputs unique markers to line
        # up script results with our source. These markers include input
        # line number and the last return code.
        salt = b"SALT%d" % time.time()

        def addsalt(line, inpython):
            if inpython:
                script.append(b'%s %d 0\n' % (salt, line))
            else:
                script.append(b'echo %s %d $?\n' % (salt, line))

        activetrace = []
        session = str(uuid.uuid4()).encode('ascii')
        hgcatapult = os.getenv('HGTESTCATAPULTSERVERPIPE') or os.getenv(
            'HGCATAPULTSERVERPIPE'
        )

        def toggletrace(cmd=None):
            if not hgcatapult or hgcatapult == os.devnull:
                return

            if activetrace:
                script.append(
                    b'echo END %s %s >> "$HGTESTCATAPULTSERVERPIPE"\n'
                    % (session, activetrace[0])
                )
            if cmd is None:
                return

            if isinstance(cmd, str):
                quoted = shellquote(cmd.strip())
            else:
                quoted = shellquote(cmd.strip().decode('utf8')).encode('utf8')
            quoted = quoted.replace(b'\\', b'\\\\')
            script.append(
                b'echo START %s %s >> "$HGTESTCATAPULTSERVERPIPE"\n'
                % (session, quoted)
            )
            activetrace[0:] = [quoted]

        script = []

        # After we run the shell script, we re-unify the script output
        # with non-active parts of the source, with synchronization by our
        # SALT line number markers. The after table contains the non-active
        # components, ordered by line number.
        after = {}

        # Expected shell script output.
        expected = {}

        pos = prepos = -1

        # The current stack of conditionnal section.
        # Each relevant conditionnal section can have the following value:
        #  - True:  we should run this block
        #  - False: we should skip this block
        #  - None:  The parent block is skipped,
        #           (no branch of this one will ever run)
        condition_stack = []

        def run_line():
            """return True if the current line should be run"""
            if not condition_stack:
                return True
            return bool(condition_stack[-1])

        def push_conditional_block(should_run):
            """Push a new conditional context, with its initial state

            i.e. entry a #if block"""
            if not run_line():
                condition_stack.append(None)
            else:
                condition_stack.append(should_run)

        def flip_conditional():
            """reverse the current condition state

            i.e. enter a #else
            """
            assert condition_stack
            if condition_stack[-1] is not None:
                condition_stack[-1] = not condition_stack[-1]

        def pop_conditional():
            """exit the current skipping context

            i.e. reach the #endif"""
            assert condition_stack
            condition_stack.pop()

        # We keep track of whether or not we're in a Python block so we
        # can generate the surrounding doctest magic.
        inpython = False

        if self._debug:
            script.append(b'set -x\n')
        if os.getenv('MSYSTEM'):
            script.append(b'alias pwd="pwd -W"\n')

        if hgcatapult and hgcatapult != os.devnull:
            hgcatapult = hgcatapult.encode('utf8')
            cataname = self.name.encode('utf8')

            # Kludge: use a while loop to keep the pipe from getting
            # closed by our echo commands. The still-running file gets
            # reaped at the end of the script, which causes the while
            # loop to exit and closes the pipe. Sigh.
            script.append(
                b'rtendtracing() {\n'
                b'  echo END %(session)s %(name)s >> %(catapult)s\n'
                b'  rm -f "$TESTTMP/.still-running"\n'
                b'}\n'
                b'trap "rtendtracing" 0\n'
                b'touch "$TESTTMP/.still-running"\n'
                b'while [ -f "$TESTTMP/.still-running" ]; do sleep 1; done '
                b'> %(catapult)s &\n'
                b'HGCATAPULTSESSION=%(session)s ; export HGCATAPULTSESSION\n'
                b'echo START %(session)s %(name)s >> %(catapult)s\n'
                % {
                    b'name': cataname,
                    b'session': session,
                    b'catapult': hgcatapult,
                }
            )

        if self._case:
            casestr = b'#'.join(self._case)
            if isinstance(casestr, str):
                quoted = shellquote(casestr)
            else:
                quoted = shellquote(casestr.decode('utf8')).encode('utf8')
            script.append(b'TESTCASE=%s\n' % quoted)
            script.append(b'export TESTCASE\n')

        n = 0
        for n, l in enumerate(lines):
            if not l.endswith(b'\n'):
                l += b'\n'
            if l.startswith(b'#require'):
                lsplit = l.split()
                if len(lsplit) < 2 or lsplit[0] != b'#require':
                    after.setdefault(pos, []).append(
                        b'  !!! invalid #require\n'
                    )
                if run_line():
                    haveresult, message = self._hghave(lsplit[1:])
                    if not haveresult:
                        script = [b'echo "%s"\nexit 80\n' % message]
                        break
                after.setdefault(pos, []).append(l)
            elif l.startswith(b'#if'):
                lsplit = l.split()
                if len(lsplit) < 2 or lsplit[0] != b'#if':
                    after.setdefault(pos, []).append(b'  !!! invalid #if\n')
                push_conditional_block(self._iftest(lsplit[1:]))
                after.setdefault(pos, []).append(l)
            elif l.startswith(b'#else'):
                if not condition_stack:
                    after.setdefault(pos, []).append(b'  !!! missing #if\n')
                flip_conditional()
                after.setdefault(pos, []).append(l)
            elif l.startswith(b'#endif'):
                if not condition_stack:
                    after.setdefault(pos, []).append(b'  !!! missing #if\n')
                pop_conditional()
                after.setdefault(pos, []).append(l)
            elif not run_line():
                after.setdefault(pos, []).append(l)
            elif l.startswith(b'  >>> '):  # python inlines
                after.setdefault(pos, []).append(l)
                prepos = pos
                pos = n
                if not inpython:
                    # We've just entered a Python block. Add the header.
                    inpython = True
                    addsalt(prepos, False)  # Make sure we report the exit code.
                    pyh = b'"%s"  %s/testlib/heredoctest.py <<EOF\n'
                    pyh %= (self._pythonb, RUNTEST_DIR_FORWARD_SLASH)
                    script.append(pyh)
                addsalt(n, True)
                script.append(l[2:])
            elif l.startswith(b'  ... '):  # python inlines
                after.setdefault(prepos, []).append(l)
                script.append(l[2:])
            elif l.startswith(b'  $ '):  # commands
                if inpython:
                    script.append(b'EOF\n')
                    inpython = False
                after.setdefault(pos, []).append(l)
                prepos = pos
                pos = n
                addsalt(n, False)
                rawcmd = l[4:]
                cmd = rawcmd.split()
                toggletrace(rawcmd)
                if len(cmd) == 2 and cmd[0] == b'cd':
                    rawcmd = b'cd %s || exit 1\n' % cmd[1]
                script.append(rawcmd)
            elif l.startswith(b'  > '):  # continuations
                after.setdefault(prepos, []).append(l)
                script.append(l[4:])
            elif l.startswith(b'  '):  # results
                # Queue up a list of expected results.
                expected.setdefault(pos, []).append(l[2:])
            else:
                if inpython:
                    script.append(b'EOF\n')
                    inpython = False
                # Non-command/result. Queue up for merged output.
                after.setdefault(pos, []).append(l)

        if inpython:
            script.append(b'EOF\n')
        if condition_stack:
            after.setdefault(pos, []).append(b'  !!! missing #endif\n')
        addsalt(n + 1, False)
        # Need to end any current per-command trace
        if activetrace:
            toggletrace()
        return salt, script, after, expected

    def _processoutput(self, exitcode, output, salt, after, expected):
        # Merge the script output back into a unified test.
        warnonly = WARN_UNDEFINED  # 1: not yet; 2: yes; 3: for sure not
        if exitcode != 0:
            warnonly = WARN_NO

        pos = -1
        postout = []
        for out_rawline in output:
            out_line, cmd_line = out_rawline, None
            if salt in out_rawline:
                out_line, cmd_line = out_rawline.split(salt, 1)

            pos, postout, warnonly = self._process_out_line(
                out_line, pos, postout, expected, warnonly
            )
            pos, postout = self._process_cmd_line(cmd_line, pos, postout, after)

        if pos in after:
            postout += after.pop(pos)

        if warnonly == WARN_YES:
            exitcode = False  # Set exitcode to warned.

        return exitcode, postout

    def _process_out_line(self, out_line, pos, postout, expected, warnonly):
        while out_line:
            if not out_line.endswith(b'\n'):
                out_line += b' (no-eol)\n'

            # Find the expected output at the current position.
            els = [None]
            if expected.get(pos, None):
                els = expected[pos]

            optional = []
            for i, el in enumerate(els):
                r = False
                if el:
                    r, exact = self.linematch(el, out_line)
                if isinstance(r, str):
                    if r == '-glob':
                        out_line = ''.join(el.rsplit(' (glob)', 1))
                        r = ''  # Warn only this line.
                    elif r == "retry":
                        postout.append(b'  ' + el)
                    else:
                        log('\ninfo, unknown linematch result: %r\n' % r)
                        r = False
                if r:
                    els.pop(i)
                    break
                if el:
                    if isoptional(el):
                        optional.append(i)
                    else:
                        m = optline.match(el)
                        if m:
                            conditions = [c for c in m.group(2).split(b' ')]

                            if not self._iftest(conditions):
                                optional.append(i)
                    if exact:
                        # Don't allow line to be matches against a later
                        # line in the output
                        els.pop(i)
                        break

            if r:
                if r == "retry":
                    continue
                # clean up any optional leftovers
                for i in optional:
                    postout.append(b'  ' + els[i])
                for i in reversed(optional):
                    del els[i]
                postout.append(b'  ' + el)
            else:
                if self.NEEDESCAPE(out_line):
                    out_line = TTest._stringescape(
                        b'%s (esc)\n' % out_line.rstrip(b'\n')
                    )
                postout.append(b'  ' + out_line)  # Let diff deal with it.
                if r != '':  # If line failed.
                    warnonly = WARN_NO
                elif warnonly == WARN_UNDEFINED:
                    warnonly = WARN_YES
            break
        else:
            # clean up any optional leftovers
            while expected.get(pos, None):
                el = expected[pos].pop(0)
                if el:
                    if not isoptional(el):
                        m = optline.match(el)
                        if m:
                            conditions = [c for c in m.group(2).split(b' ')]

                            if self._iftest(conditions):
                                # Don't append as optional line
                                continue
                        else:
                            continue
                postout.append(b'  ' + el)
        return pos, postout, warnonly

    def _process_cmd_line(self, cmd_line, pos, postout, after):
        """process a "command" part of a line from unified test output"""
        if cmd_line:
            # Add on last return code.
            ret = int(cmd_line.split()[1])
            if ret != 0:
                postout.append(b'  [%d]\n' % ret)
            if pos in after:
                # Merge in non-active test bits.
                postout += after.pop(pos)
            pos = int(cmd_line.split()[0])
        return pos, postout

    @staticmethod
    def rematch(el, l):
        try:
            # parse any flags at the beginning of the regex. Only 'i' is
            # supported right now, but this should be easy to extend.
            flags, el = re.match(br'^(\(\?i\))?(.*)', el).groups()[0:2]
            flags = flags or b''
            el = flags + b'(?:' + el + b')'
            # use \Z to ensure that the regex matches to the end of the string
            if WINDOWS:
                return re.match(el + br'\r?\n\Z', l)
            return re.match(el + br'\n\Z', l)
        except re.error:
            # el is an invalid regex
            return False

    @staticmethod
    def globmatch(el, l):
        # The only supported special characters are * and ? plus / which also
        # matches \ on windows. Escaping of these characters is supported.
        if el + b'\n' == l:
            if os.altsep:
                # matching on "/" is not needed for this line
                for pat in checkcodeglobpats:
                    if pat.match(el):
                        return True
                return b'-glob'
            return True
        el = el.replace(b'$LOCALIP', b'*')
        i, n = 0, len(el)
        res = b''
        while i < n:
            c = el[i : i + 1]
            i += 1
            if c == b'\\' and i < n and el[i : i + 1] in b'*?\\/':
                res += el[i - 1 : i + 1]
                i += 1
            elif c == b'*':
                res += b'.*'
            elif c == b'?':
                res += b'.'
            elif c == b'/' and os.altsep:
                res += b'[/\\\\]'
            else:
                res += re.escape(c)
        return TTest.rematch(res, l)

    def linematch(self, el, l):
        if el == l:  # perfect match (fast)
            return True, True
        retry = False
        if isoptional(el):
            retry = "retry"
            el = el[: -len(MARK_OPTIONAL)] + b"\n"
        else:
            m = optline.match(el)
            if m:
                conditions = [c for c in m.group(2).split(b' ')]

                el = m.group(1) + b"\n"
                if not self._iftest(conditions):
                    # listed feature missing, should not match
                    return "retry", False

        if el.endswith(b" (esc)\n"):
            el = el[:-7].decode('unicode_escape') + '\n'
            el = el.encode('latin-1')
        if el == l or WINDOWS and el[:-1] + b'\r\n' == l:
            return True, True
        if el.endswith(b" (re)\n"):
            return (TTest.rematch(el[:-6], l) or retry), False
        if el.endswith(b" (glob)\n"):
            # ignore '(glob)' added to l by 'replacements'
            if l.endswith(b" (glob)\n"):
                l = l[:-8] + b"\n"
            return (TTest.globmatch(el[:-8], l) or retry), False
        if os.altsep:
            _l = l.replace(b'\\', b'/')
            if el == _l or WINDOWS and el[:-1] + b'\r\n' == _l:
                return True, True
        return retry, True

    @staticmethod
    def parsehghaveoutput(lines):
        """Parse hghave log lines.

        Return tuple of lists (missing, failed):
          * the missing/unknown features
          * the features for which existence check failed"""
        missing = []
        failed = []
        for line in lines:
            if line.startswith(TTest.SKIPPED_PREFIX):
                line = line.splitlines()[0]
                missing.append(_bytes2sys(line[len(TTest.SKIPPED_PREFIX) :]))
            elif line.startswith(TTest.FAILED_PREFIX):
                line = line.splitlines()[0]
                failed.append(_bytes2sys(line[len(TTest.FAILED_PREFIX) :]))

        return missing, failed

    @staticmethod
    def _escapef(m):
        return TTest.ESCAPEMAP[m.group(0)]

    @staticmethod
    def _stringescape(s):
        return TTest.ESCAPESUB(TTest._escapef, s)


iolock = threading.RLock()
firstlock = threading.RLock()
firsterror = False

base_class = unittest.TextTestResult


class TestResult(base_class):
    """Holds results when executing via unittest."""

    def __init__(self, options, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self._options = options

        # unittest.TestResult didn't have skipped until 2.7. We need to
        # polyfill it.
        self.skipped = []

        # We have a custom "ignored" result that isn't present in any Python
        # unittest implementation. It is very similar to skipped. It may make
        # sense to map it into skip some day.
        self.ignored = []

        self._dot_printed = 0
        self.times = []
        self._firststarttime = None
        # Data stored for the benefit of generating xunit reports.
        self.successes = []
        self.faildata = {}

        if options.color == 'auto':
            isatty = self.stream.isatty()
            # For some reason, redirecting stdout on Windows disables the ANSI
            # color processing of stderr, which is what is used to print the
            # output.  Therefore, both must be tty on Windows to enable color.
            if WINDOWS:
                isatty = isatty and sys.stdout.isatty()
            self.color = pygmentspresent and isatty
        elif options.color == 'never':
            self.color = False
        else:  # 'always', for testing purposes
            self.color = pygmentspresent

    def _write_dot(self, progress):
        """write an item of the "dot" progress"""
        formated = highlight_progress(progress, self.color)
        self.stream.write(formated)
        self._dot_printed += 1
        if not self._dot_printed % 75:
            self.stream.write(f' [{self._dot_printed}]\n'.rjust(8))
        self.stream.flush()

    def onStart(self, test):
        """Can be overriden by custom TestResult"""

    def onEnd(self):
        """Can be overriden by custom TestResult"""

    def addFailure(self, test, reason):
        self.failures.append((test, reason))

        if self._options.first:
            self.stop()
        else:
            with iolock:
                if reason == "timed out":
                    self._write_dot('t')
                else:
                    if not self._options.nodiff:
                        self.stream.write('\n')
                        # Exclude the '\n' from highlighting to lex correctly
                        formatted = 'ERROR: %s output changed\n' % test
                        self.stream.write(highlightmsg(formatted, self.color))
                    self._write_dot('!')

                self.stream.flush()

    def addSuccess(self, test):
        with iolock:
            # bypass the TextTestResult method as do deal with the output ourself
            super(base_class, self).addSuccess(test)
            if self.showAll:
                self._write_status(test, "ok")
            elif self.dots:
                self._write_dot('.')
        self.successes.append(test)

    def addError(self, test, err):
        super(base_class, self).addError(test, err)
        if self.showAll:
            self._write_status(test, "ERROR")
        elif self.dots:
            self._write_dot('E')
        if self._options.first:
            self.stop()

    # Polyfill.
    def addSkip(self, test, reason):
        self.skipped.append((test, reason))
        with iolock:
            if self.showAll:
                self.stream.writeln('skipped %s' % reason)
            else:
                self._write_dot('s')

    def addIgnore(self, test, reason):
        self.ignored.append((test, reason))
        with iolock:
            if self.showAll:
                self.stream.writeln('ignored %s' % reason)
            else:
                if reason not in ('not retesting', "doesn't match keyword"):
                    self._write_dot('i')
                else:
                    self.testsRun += 1

    def addOutputMismatch(self, test, ret, got, expected):
        """Record a mismatch in test output for a particular test."""
        if self.shouldStop or firsterror:
            # don't print, some other test case already failed and
            # printed, we're just stale and probably failed due to our
            # temp dir getting cleaned up.
            return

        accepted = False
        lines = []

        with iolock:
            if self._options.nodiff:
                pass
            elif self._options.view:
                v = self._options.view
                subprocess.call(
                    r'"%s" "%s" "%s"'
                    % (v, _bytes2sys(test.refpath), _bytes2sys(test.errpath)),
                    shell=True,
                )
            else:
                servefail, lines = getdiff(
                    expected, got, test.refpath, test.errpath
                )
                self.stream.write('\n')
                for line in lines:
                    line = highlightdiff(line, self.color)
                    self.stream.flush()
                    self.stream.buffer.write(line)
                    self.stream.buffer.flush()

                if servefail:
                    raise test.failureException(
                        'server failed to start (HGPORT=%s)' % test._startport
                    )

            # handle interactive prompt without releasing iolock
            if self._options.interactive:
                if test.readrefout() != expected:
                    self.stream.write(
                        'Reference output has changed (run again to prompt '
                        'changes)'
                    )
                else:
                    self.stream.write('Accept this change? [y/N] ')
                    self.stream.flush()
                    answer = sys.stdin.readline().strip()
                    if answer.lower() in ('y', 'yes'):
                        if test.path.endswith(b'.t'):
                            rename(test.errpath, test.path)
                        else:
                            rename(test.errpath, b'%s.out' % test.path)
                        accepted = True
            if not accepted:
                self.faildata[test.name] = b''.join(lines)

        return accepted

    def startTest(self, test):
        super().startTest(test)

        # os.times module computes the user time and system time spent by
        # child's processes along with real elapsed time taken by a process.
        # This module has one limitation. It can only work for Linux user
        # and not for Windows. Hence why we fall back to another function
        # for wall time calculations.
        test.started_times = os.times()
        # TODO use a monotonic clock once support for Python 2.7 is dropped.
        test.started_time = time.time()
        if self._firststarttime is None:  # thread racy but irrelevant
            self._firststarttime = test.started_time

    def stopTest(self, test, interrupted=False):
        super().stopTest(test)

        test.stopped_times = os.times()
        stopped_time = time.time()

        starttime = test.started_times
        endtime = test.stopped_times
        origin = self._firststarttime
        self.times.append(
            (
                test.name,
                endtime[2] - starttime[2],  # user space CPU time
                endtime[3] - starttime[3],  # sys  space CPU time
                stopped_time - test.started_time,  # real time
                test.started_time - origin,  # start date in run context
                stopped_time - origin,  # end date in run context
            )
        )

        if interrupted:
            with iolock:
                self.stream.writeln(
                    'INTERRUPTED: %s (after %d seconds)'
                    % (test.name, self.times[-1][3])
                )


def getTestResult():
    """
    Returns the relevant test result
    """
    if "CUSTOM_TEST_RESULT" in os.environ:
        testresultmodule = __import__(os.environ["CUSTOM_TEST_RESULT"])
        return testresultmodule.TestResult
    else:
        return TestResult


class TestSuite(unittest.TestSuite):
    """Custom unittest TestSuite that knows how to execute Mercurial tests."""

    def __init__(
        self,
        testdir,
        jobs=1,
        whitelist=None,
        blacklist=None,
        keywords=None,
        loop=False,
        runs_per_test=1,
        loadtest=None,
        showchannels=False,
        tail_report=False,
        *args,
        **kwargs,
    ):
        """Create a new instance that can run tests with a configuration.

        testdir specifies the directory where tests are executed from. This
        is typically the ``tests`` directory from Mercurial's source
        repository.

        jobs specifies the number of jobs to run concurrently. Each test
        executes on its own thread. Tests actually spawn new processes, so
        state mutation should not be an issue.

        If there is only one job, it will use the main thread.

        whitelist and blacklist denote tests that have been whitelisted and
        blacklisted, respectively. These arguments don't belong in TestSuite.
        Instead, whitelist and blacklist should be handled by the thing that
        populates the TestSuite with tests. They are present to preserve
        backwards compatible behavior which reports skipped tests as part
        of the results.

        keywords denotes key words that will be used to filter which tests
        to execute. This arguably belongs outside of TestSuite.

        loop denotes whether to loop over tests forever.
        """
        super().__init__(*args, **kwargs)

        self._jobs = jobs
        self._whitelist = whitelist
        self._blacklist = blacklist
        self._keywords = keywords
        self._loop = loop
        self._runs_per_test = runs_per_test
        self._loadtest = loadtest
        self._showchannels = showchannels
        self._tail_report = tail_report

    def run(self, result):
        # We have a number of filters that need to be applied. We do this
        # here instead of inside Test because it makes the running logic for
        # Test simpler.
        tests = []
        num_tests = [0]
        for test in self._tests:

            def get():
                num_tests[0] += 1
                if getattr(test, 'should_reload', False):
                    return self._loadtest(test, num_tests[0])
                return test

            if not os.path.exists(test.path):
                result.addSkip(test, "Doesn't exist")
                continue

            is_whitelisted = self._whitelist and (
                test.relpath in self._whitelist or test.bname in self._whitelist
            )
            if not is_whitelisted:
                is_blacklisted = self._blacklist and (
                    test.relpath in self._blacklist
                    or test.bname in self._blacklist
                )
                if is_blacklisted:
                    result.addSkip(test, 'blacklisted')
                    continue
                if self._keywords:
                    with open(test.path, 'rb') as f:
                        t = f.read().lower() + test.bname.lower()
                    ignored = False
                    for k in self._keywords.lower().split():
                        if k not in t:
                            result.addIgnore(test, "doesn't match keyword")
                            ignored = True
                            break

                    if ignored:
                        continue
            for _ in range(self._runs_per_test):
                tests.append(get())

        runtests = list(tests)
        done = queue.Queue()
        running = 0

        channels_lock = threading.Lock()
        channels = [""] * self._jobs

        def job(test, result):
            with channels_lock:
                for n, v in enumerate(channels):
                    if not v:
                        channel = n
                        break
                else:
                    raise ValueError('Could not find output channel')
                channels[channel] = "=" + test.name[5:].split(".")[0]

            r = (None, test, None)
            try:
                test(result)
            except KeyboardInterrupt:
                pass
            except:  # re-raises
                r = ('!', test, 'run-test raised an error, see traceback')
                raise
            finally:
                try:
                    channels[channel] = ''
                except IndexError:
                    pass
                done.put(r)

        def stat():
            count = 0
            while channels:
                d = '\n%03s  ' % count
                for n, v in enumerate(channels):
                    if v:
                        d += v[0]
                        channels[n] = v[1:] or '.'
                    else:
                        d += ' '
                    d += ' '
                with iolock:
                    sys.stdout.write(d + '  ')
                    sys.stdout.flush()
                for x in range(10):
                    if channels:
                        time.sleep(0.1)
                count += 1

        stoppedearly = False

        if self._showchannels:
            statthread = threading.Thread(target=stat, name="stat")
            statthread.start()

        start_time = time.monotonic()
        tail_data = []
        try:
            while tests or running:
                finished = None
                if not done.empty() or running == self._jobs or not tests:
                    try:
                        _, finished, _ = done.get(True, 1)
                        running -= 1
                        if result and result.shouldStop:
                            stoppedearly = True
                            break
                    except queue.Empty:
                        continue
                if tests and not running == self._jobs:
                    test = tests.pop(0)
                    if self._loop:
                        if getattr(test, 'should_reload', False):
                            num_tests[0] += 1
                            tests.append(self._loadtest(test, num_tests[0]))
                        else:
                            tests.append(test)
                    if self._jobs == 1:
                        job(test, result)
                    else:
                        t = threading.Thread(
                            target=job, name=test.name, args=(test, result)
                        )
                        t.start()
                    running += 1
                if finished is not None and running < self._jobs:
                    tail_data.append((finished, running, time.monotonic()))

            # If we stop early we still need to wait on started tests to
            # finish. Otherwise, there is a race between the test completing
            # and the test's cleanup code running. This could result in the
            # test reporting incorrect.
            if stoppedearly:
                while running:
                    try:
                        done.get(True, 1)
                        running -= 1
                    except queue.Empty:
                        continue
        except KeyboardInterrupt:
            for test in runtests:
                test.abort()

        if self._tail_report:
            with iolock:
                sys.stdout.write('\n### test tail-report ###\n')
                sys.stdout.flush()
                channels = []
                for test, remaining, end_time in tail_data:
                    m = "[% 13.6f s] %d tests still running; finished %s\n"
                    m %= (end_time - start_time, remaining, test)
                    sys.stdout.write(m)
                    sys.stdout.flush()

        return result


# Save the most recent 5 wall-clock runtimes of each test to a
# human-readable text file named .testtimes. Tests are sorted
# alphabetically, while times for each test are listed from oldest to
# newest.


def loadtimes(outputdir):
    times = []
    try:
        with open(os.path.join(outputdir, b'.testtimes')) as fp:
            for line in fp:
                m = re.match('(.*?) ([0-9. ]+)', line)
                times.append(
                    (m.group(1), [float(t) for t in m.group(2).split()])
                )
    except FileNotFoundError:
        pass
    return times


def savetimes(outputdir, result):
    saved = dict(loadtimes(outputdir))
    maxruns = 5
    skipped = {str(t[0]) for t in result.skipped}
    for tdata in result.times:
        test, real = tdata[0], tdata[3]
        if test not in skipped:
            ts = saved.setdefault(test, [])
            ts.append(real)
            ts[:] = ts[-maxruns:]

    fd, tmpname = tempfile.mkstemp(
        prefix=b'.testtimes', dir=outputdir, text=True
    )
    with os.fdopen(fd, 'w') as fp:
        for name, ts in sorted(saved.items()):
            fp.write('%s %s\n' % (name, ' '.join(['%.3f' % (t,) for t in ts])))
    timepath = os.path.join(outputdir, b'.testtimes')
    try:
        os.unlink(timepath)
    except OSError:
        pass
    try:
        os.rename(tmpname, timepath)
    except OSError:
        pass


def get_site_packages_dir(python_exe):
    return subprocess.run(
        [
            python_exe,
            "-c",
            "import sys; print([p for p in sys.path if p.startswith(sys.prefix) and p.endswith('site-packages')][0])",
        ],
        check=True,
        capture_output=True,
    ).stdout.strip()


class TextTestRunner(unittest.TextTestRunner):
    """Custom unittest test runner that uses appropriate settings."""

    def __init__(self, runner, *args, **kwargs):
        super().__init__(*args, **kwargs)

        self._runner = runner

        self._result = getTestResult()(
            self._runner.options, self.stream, self.descriptions, self.verbosity
        )

    def listtests(self, test):
        test = sorted(test, key=lambda t: t.name)

        self._result.onStart(test)

        for t in test:
            print(t.name)
            self._result.addSuccess(t)

        if self._runner.options.xunit:
            with open(self._runner.options.xunit, "wb") as xuf:
                self._writexunit(self._result, xuf)

        if self._runner.options.json:
            jsonpath = os.path.join(self._runner._outputdir, b'report.json')
            with open(jsonpath, 'w') as fp:
                self._writejson(self._result, fp)

        return self._result

    def run(self, test):
        self._result.onStart(test)
        test(self._result)

        failed = len(self._result.failures)
        skipped = len(self._result.skipped)
        ignored = len(self._result.ignored)

        with iolock:
            if not self._runner.options.tail_report:
                self.stream.writeln('')

            if not self._runner.options.noskips:
                for test, msg in sorted(
                    self._result.skipped, key=lambda s: s[0].name
                ):
                    formatted = 'Skipped %s: %s\n' % (test.name, msg)
                    msg = highlightmsg(formatted, self._result.color)
                    self.stream.write(msg)
            for test, msg in sorted(
                self._result.failures, key=lambda f: f[0].name
            ):
                formatted = 'Failed %s: %s\n' % (test.name, msg)
                self.stream.write(highlightmsg(formatted, self._result.color))
            for test, msg in sorted(
                self._result.errors, key=lambda e: e[0].name
            ):
                self.stream.writeln('Errored %s: %s' % (test.name, msg))

            if self._runner.options.xunit:
                with open(self._runner.options.xunit, "wb") as xuf:
                    self._writexunit(self._result, xuf)

            if self._runner.options.json:
                jsonpath = os.path.join(self._runner._outputdir, b'report.json')
                with open(jsonpath, 'w') as fp:
                    self._writejson(self._result, fp)

            self._runner._check_hg('Tested')

            savetimes(self._runner._outputdir, self._result)

            self.stream.writeln(
                '# Ran %d tests, %d skipped, %d failed.'
                % (self._result.testsRun, skipped + ignored, failed)
            )
            if failed:
                self.stream.writeln(
                    'python hash seed: %s' % os.environ['PYTHONHASHSEED']
                )
            if self._runner.options.time:
                self.printtimes(self._result.times)

            if self._runner.options.exceptions:
                exceptions = aggregateexceptions(
                    os.path.join(self._runner._outputdir, b'exceptions')
                )

                self.stream.writeln('Exceptions Report:')
                self.stream.writeln(
                    '%d total from %d frames'
                    % (exceptions['total'], len(exceptions['exceptioncounts']))
                )
                combined = exceptions['combined']
                for key in sorted(combined, key=combined.get, reverse=True):
                    frame, line, exc = key
                    totalcount, testcount, leastcount, leasttest = combined[key]

                    self.stream.writeln(
                        '%d (%d tests)\t%s: %s (%s - %d total)'
                        % (
                            totalcount,
                            testcount,
                            frame,
                            exc,
                            leasttest,
                            leastcount,
                        )
                    )

            self.stream.flush()

        return self._result

    def printtimes(self, times):
        # iolock held by run
        self.stream.writeln('# Producing time report')
        times.sort(key=lambda t: (t[3]))
        cols = '%7.3f %7.3f %7.3f %7.3f %7.3f   %s'
        self.stream.writeln(
            '%-7s %-7s %-7s %-7s %-7s   %s'
            % ('start', 'end', 'cuser', 'csys', 'real', 'Test')
        )
        for tdata in times:
            test = tdata[0]
            cuser, csys, real, start, end = tdata[1:6]
            self.stream.writeln(cols % (start, end, cuser, csys, real, test))

    @staticmethod
    def _writexunit(result, outf):
        # See http://llg.cubic.org/docs/junit/ for a reference.
        timesd = {t[0]: t[3] for t in result.times}
        doc = minidom.Document()
        s = doc.createElement('testsuite')
        s.setAttribute('errors', "0")  # TODO
        s.setAttribute('failures', str(len(result.failures)))
        s.setAttribute('name', 'run-tests')
        s.setAttribute(
            'skipped', str(len(result.skipped) + len(result.ignored))
        )
        s.setAttribute('tests', str(result.testsRun))
        doc.appendChild(s)
        for tc in result.successes:
            t = doc.createElement('testcase')
            t.setAttribute('name', tc.name)
            tctime = timesd.get(tc.name)
            if tctime is not None:
                t.setAttribute('time', '%.3f' % tctime)
            s.appendChild(t)
        for tc, err in sorted(result.faildata.items()):
            t = doc.createElement('testcase')
            t.setAttribute('name', tc)
            tctime = timesd.get(tc)
            if tctime is not None:
                t.setAttribute('time', '%.3f' % tctime)
            # createCDATASection expects a unicode or it will
            # convert using default conversion rules, which will
            # fail if string isn't ASCII.
            err = cdatasafe(err).decode('utf-8', 'replace')
            cd = doc.createCDATASection(err)
            # Use 'failure' here instead of 'error' to match errors = 0,
            # failures = len(result.failures) in the testsuite element.
            failelem = doc.createElement('failure')
            failelem.setAttribute('message', 'output changed')
            failelem.setAttribute('type', 'output-mismatch')
            failelem.appendChild(cd)
            t.appendChild(failelem)
            s.appendChild(t)
        for tc, message in result.skipped:
            # According to the schema, 'skipped' has no attributes. So store
            # the skip message as a text node instead.
            t = doc.createElement('testcase')
            t.setAttribute('name', tc.name)
            binmessage = message.encode('utf-8')
            message = cdatasafe(binmessage).decode('utf-8', 'replace')
            cd = doc.createCDATASection(message)
            skipelem = doc.createElement('skipped')
            skipelem.appendChild(cd)
            t.appendChild(skipelem)
            s.appendChild(t)
        outf.write(doc.toprettyxml(indent='  ', encoding='utf-8'))

    @staticmethod
    def _writejson(result, outf):
        timesd = {}
        for tdata in result.times:
            test = tdata[0]
            timesd[test] = tdata[1:]

        outcome = {}
        groups = [
            ('success', ((tc, None) for tc in result.successes)),
            ('failure', result.failures),
            ('skip', result.skipped),
        ]
        for res, testcases in groups:
            for tc, __ in testcases:
                if tc.name in timesd:
                    diff = result.faildata.get(tc.name, b'')
                    try:
                        diff = diff.decode('unicode_escape')
                    except UnicodeDecodeError as e:
                        diff = '%r decoding diff, sorry' % e
                    tres = {
                        'result': res,
                        'time': ('%0.3f' % timesd[tc.name][2]),
                        'cuser': ('%0.3f' % timesd[tc.name][0]),
                        'csys': ('%0.3f' % timesd[tc.name][1]),
                        'start': ('%0.3f' % timesd[tc.name][3]),
                        'end': ('%0.3f' % timesd[tc.name][4]),
                        'diff': diff,
                    }
                else:
                    # blacklisted test
                    tres = {'result': res}

                outcome[tc.name] = tres
        jsonout = json.dumps(
            outcome, sort_keys=True, indent=4, separators=(',', ': ')
        )
        outf.writelines(("testreport =", jsonout))


def sorttests(testdescs, previoustimes, shuffle=False):
    """Do an in-place sort of tests."""
    if shuffle:
        random.shuffle(testdescs)
        return

    if previoustimes:

        def sortkey(f):
            f = f['path']
            if f in previoustimes:
                # Use most recent time as estimate
                return -(previoustimes[f][-1])
            else:
                # Default to a rather arbitrary value of 1 second for new tests
                return -1.0

    else:
        # keywords for slow tests
        slow = {
            b'svn': 10,
            b'cvs': 10,
            b'hghave': 10,
            b'largefiles-update': 10,
            b'run-tests': 10,
            b'corruption': 10,
            b'race': 10,
            b'i18n': 10,
            b'check': 100,
            b'gendoc': 100,
            b'contrib-perf': 200,
            b'merge-combination': 100,
        }
        perf = {}

        def sortkey(f):
            # run largest tests first, as they tend to take the longest
            f = f['path']
            try:
                return perf[f]
            except KeyError:
                try:
                    val = -os.stat(f).st_size
                except FileNotFoundError:
                    perf[f] = -1e9  # file does not exist, tell early
                    return -1e9
                for kw, mul in slow.items():
                    if kw in f:
                        val *= mul
                if f.endswith(b'.py'):
                    val /= 10.0
                perf[f] = val / 1000.0
                return perf[f]

    testdescs.sort(key=sortkey)


class TestRunner:
    """Holds context for executing tests.

    Tests rely on a lot of state. This object holds it for them.
    """

    # Programs required to run tests.
    REQUIREDTOOLS = [
        b'diff',
        b'grep',
        b'unzip',
        b'gunzip',
        b'bunzip2',
        b'sed',
    ]

    # Maps file extensions to test class.
    TESTTYPES = [
        (b'.py', PythonTest),
        (b'.t', TTest),
    ]

    def __init__(self):
        self.options = None
        self._hgroot = None
        self._testdir = None
        self._outputdir = None
        self._hgtmp = None
        self._installdir = None
        self._bindir = None
        # a place for run-tests.py to generate executable it needs
        self._custom_bin_dir = None
        self._pythondir = None

        if sys.executable:
            self._python = sys.executable
        elif os.environ.get('PYTHONEXECUTABLE'):
            self._python = os.environ['PYTHONEXECUTABLE']
        elif os.environ.get('PYTHON'):
            self._python = os.environ['PYTHON']
        else:
            raise AssertionError('Could not find Python interpreter')

        # True if we had to infer the pythondir from --with-hg
        self._pythondir_inferred = False
        self._coveragefile = None
        self._createdfiles = []
        self._hgcommand = None
        self._hgpath = None
        self._portoffset = 0
        self._ports = {}

    @property
    def _pythonb(self):
        return _sys2bytes(self._python.replace('\\', '/'))

    def run(self, args, parser=None):
        """Run the test suite."""
        oldmask = os.umask(0o22)
        try:
            parser = parser or getparser()
            options = parseargs(args, parser)
            tests = [_sys2bytes(a) for a in options.tests]
            if options.test_list is not None:
                for listfile in options.test_list:
                    with open(listfile, 'rb') as f:
                        tests.extend(t for t in f.read().splitlines() if t)
            self.options = options

            self._checktools()
            testdescs = self.findtests(tests)
            if options.profile_runner:
                import statprof

                statprof.start()
            result = self._run(
                testdescs,
                shard_index=options.shard_index,
                shard_total=options.shard_total,
            )
            if options.profile_runner:
                statprof.stop()
                statprof.display()
            return result

        finally:
            os.umask(oldmask)

    def _run(self, testdescs, shard_index=None, shard_total=None):
        testdir = getcwdb()
        # assume all tests in same folder for now
        if testdescs:
            pathname = os.path.dirname(testdescs[0]['path'])
            if pathname:
                testdir = os.path.join(testdir, pathname)
        self._testdir = osenvironb[b'TESTDIR'] = testdir
        osenvironb[b'TESTDIR_FORWARD_SLASH'] = osenvironb[b'TESTDIR'].replace(
            os.sep.encode('ascii'), b'/'
        )

        if self.options.outputdir:
            self._outputdir = canonpath(_sys2bytes(self.options.outputdir))
        else:
            self._outputdir = getcwdb()
            if testdescs and pathname:
                self._outputdir = os.path.join(self._outputdir, pathname)
        previoustimes = {}
        if self.options.order_by_runtime:
            previoustimes = dict(loadtimes(self._outputdir))
        sorttests(testdescs, previoustimes, shuffle=self.options.random)

        if 'PYTHONHASHSEED' not in os.environ:
            # use a random python hash seed all the time
            # we do the randomness ourself to know what seed is used
            os.environ['PYTHONHASHSEED'] = str(random.getrandbits(32))

        # Rayon (Rust crate for multi-threading) will use all logical CPU cores
        # by default, causing thrashing on high-cpu-count systems.
        # Setting its limit to 3 during tests should still let us uncover
        # multi-threading bugs while keeping the thrashing reasonable.
        os.environ.setdefault("RAYON_NUM_THREADS", "3")

        if self.options.tmpdir:
            self.options.keep_tmpdir = True
            tmpdir = _sys2bytes(self.options.tmpdir)
            if os.path.exists(tmpdir):
                # Meaning of tmpdir has changed since 1.3: we used to create
                # HGTMP inside tmpdir; now HGTMP is tmpdir.  So fail if
                # tmpdir already exists.
                print("error: temp dir %r already exists" % tmpdir)
                return 1

            os.makedirs(tmpdir)
        else:
            d = None
            if WINDOWS:
                # without this, we get the default temp dir location, but
                # in all lowercase, which causes troubles with paths (issue3490)
                d = osenvironb.get(b'TMP', None)
            tmpdir = tempfile.mkdtemp(b'', b'hgtests.', d)

        self._hgtmp = osenvironb[b'HGTMP'] = os.path.realpath(tmpdir)

        self._custom_bin_dir = os.path.join(self._hgtmp, b'custom-bin')
        os.makedirs(self._custom_bin_dir)

        # detect and enforce an alternative way to specify rust extension usage
        if (
            not (
                self.options.wheel
                or self.options.pure
                or self.options.rust
                or self.options.no_rust
            )
            and os.environ.get("HGWITHRUSTEXT") == "cpython"
        ):
            self.options.rust = True

        if self.options.with_hg:
            self._installdir = None
            whg = self.options.with_hg
            self._bindir = os.path.dirname(os.path.realpath(whg))
            assert isinstance(self._bindir, bytes)
            self._hgcommand = os.path.basename(whg)

            normbin = os.path.normpath(os.path.abspath(whg))
            normbin = normbin.replace(_sys2bytes(os.sep), b'/')

            # Other Python scripts in the test harness need to
            # `import mercurial`. If `hg` is a Python script, we assume
            # the Mercurial modules are relative to its path and tell the tests
            # to load Python modules from its directory.
            with open(whg, 'rb') as fh:
                first_line = fh.readline()

            if re.match(b'#!.*python', first_line):
                python_exe = first_line.split(b"#!")[1].strip()
                try:
                    self._pythondir = get_site_packages_dir(python_exe)
                except (FileNotFoundError, subprocess.CalledProcessError):
                    self._pythondir = self._bindir
                if self.options.local:
                    self._python = _bytes2sys(python_exe)

            # If it looks like our in-repo Rust binary, use the source root.
            # This is a bit hacky. But rhg is still not supported outside the
            # source directory. So until it is, do the simple thing.
            elif re.search(b'/rust/target/[^/]+/hg', normbin):
                self._pythondir = os.path.dirname(self._testdir)
            # Fall back to the legacy behavior.
            else:
                self._pythondir = self._bindir
            self._pythondir_inferred = True

        else:
            self._hgcommand = b'hg'
            self._installdir = os.path.join(self._hgtmp, b"install")

            # create a virtual env where hg is going to be installed
            command_create_venv = [
                self._python,
                "-m",
                "venv",
                "--system-site-packages",
                "--without-pip",
                self._installdir,
            ]
            subprocess.run(command_create_venv, check=True)

            bindir = b"Scripts" if WINDOWS else b"bin"
            self._bindir = os.path.join(self._installdir, bindir)
            self._python = _bytes2sys(os.path.join(self._bindir, b"python"))
            self._pythondir = get_site_packages_dir(self._python)

        # Force the use of hg.exe instead of relying on MSYS to recognize hg is
        # a python script and feed it to python.exe.  Legacy stdio is force
        # enabled by hg.exe, and this is a more realistic way to launch hg
        # anyway.
        #
        # We do not do it when using wheels and they do not install a .exe.
        if WINDOWS and not self.options.wheel:
            # Currently no hg.exe without compiler
            if self.options.pure:
                self._hgcommand += b'.bat'
            elif not self._hgcommand.endswith(b'.exe'):
                self._hgcommand += b'.exe'

        self._real_hg = os.path.join(self._bindir, self._hgcommand)
        osenvironb[b'HGTEST_REAL_HG'] = self._real_hg
        # set CHGHG, then replace "hg" command by "chg"
        chgbindir = self._bindir
        if self.options.chg or self.options.with_chg:
            osenvironb[b'CHG_INSTALLED_AS_HG'] = b'1'
            osenvironb[b'CHGHG'] = self._real_hg
        else:
            # drop flag for hghave
            osenvironb.pop(b'CHG_INSTALLED_AS_HG', None)
        if self.options.chg:
            self._hgcommand = b'chg'
        elif self.options.with_chg:
            chgbindir = os.path.dirname(os.path.realpath(self.options.with_chg))
            self._hgcommand = os.path.basename(self.options.with_chg)

        # configure fallback and replace "hg" command by "rhg"
        rhgbindir = self._bindir
        if self.options.rhg or self.options.with_rhg:
            # Affects hghave.py
            osenvironb[b'RHG_INSTALLED_AS_HG'] = b'1'
            # Affects configuration. Alternatives would be setting configuration through
            # `$HGRCPATH` but some tests override that, or changing `_hgcommand` to include
            # `--config` but that disrupts tests that print command lines and check expected
            # output.
            osenvironb[b'RHG_ON_UNSUPPORTED'] = b'fallback'
            osenvironb[b'RHG_FALLBACK_EXECUTABLE'] = self._real_hg
        else:
            # drop flag for hghave
            osenvironb.pop(b'RHG_INSTALLED_AS_HG', None)
        if self.options.rhg:
            self._hgcommand = b'rhg'
        elif self.options.with_rhg:
            rhgbindir = os.path.dirname(os.path.realpath(self.options.with_rhg))
            self._hgcommand = os.path.basename(self.options.with_rhg)

        if self.options.pyoxidized:
            testdir = os.path.dirname(_sys2bytes(canonpath(sys.argv[0])))
            reporootdir = os.path.dirname(testdir)
            # XXX we should ideally install stuff instead of using the local build

            exe = b'hg'
            triple = b''

            if WINDOWS:
                triple = b'x86_64-pc-windows-msvc'
                exe = b'hg.exe'
            elif MACOS:
                # TODO: support Apple silicon too
                triple = b'x86_64-apple-darwin'

            bin_path = b'build/pyoxidizer/%s/release/app/%s' % (triple, exe)
            full_path = os.path.join(reporootdir, bin_path)
            self._hgcommand = full_path
            # Affects hghave.py
            osenvironb[b'PYOXIDIZED_INSTALLED_AS_HG'] = b'1'
        else:
            osenvironb.pop(b'PYOXIDIZED_INSTALLED_AS_HG', None)

        osenvironb[b"BINDIR"] = self._bindir
        osenvironb[b"PYTHON"] = self._pythonb

        fileb = _sys2bytes(__file__)
        osenvironb[b'RUNTESTDIR'] = RUNTEST_DIR
        osenvironb[b'RUNTESTDIR_FORWARD_SLASH'] = RUNTEST_DIR_FORWARD_SLASH
        sepb = _sys2bytes(os.pathsep)
        path = [self._bindir, RUNTEST_DIR] + osenvironb[b"PATH"].split(sepb)
        if os.path.islink(__file__):
            # test helper will likely be at the end of the symlink
            realfile = os.path.realpath(fileb)
            realdir = os.path.abspath(os.path.dirname(realfile))
            path.insert(2, realdir)
        if chgbindir != self._bindir:
            path.insert(1, chgbindir)
        if rhgbindir != self._bindir:
            path.insert(1, rhgbindir)
        if self._testdir != RUNTEST_DIR:
            path = [self._testdir] + path
        path = [self._custom_bin_dir] + path
        osenvironb[b"PATH"] = sepb.join(path)

        os.environ["HGTEST_BASE_HGMODULEPOLICY"] = os.environ.get(
            "HGMODULEPOLICY", ""
        )

        if self.options.pure:
            os.environ["HGTEST_RUN_TESTS_PURE"] = "--pure"
            os.environ["HGMODULEPOLICY"] = "py"
            os.environ.pop("HGWITHRUSTEXT", None)
        if self.options.rust:
            os.environ["HGMODULEPOLICY"] = "rust+c"
        if self.options.no_rust:
            current_policy = os.environ.get("HGMODULEPOLICY", "")
            if current_policy.startswith("rust+"):
                os.environ["HGMODULEPOLICY"] = current_policy[len("rust+") :]
            os.environ.pop("HGWITHRUSTEXT", None)

        if self.options.allow_slow_tests:
            os.environ["HGTEST_SLOW"] = "slow"
        elif 'HGTEST_SLOW' in os.environ:
            del os.environ['HGTEST_SLOW']

        self._coveragefile = os.path.join(self._testdir, b'.coverage')

        if self.options.exceptions:
            exceptionsdir = os.path.join(self._outputdir, b'exceptions')
            try:
                os.makedirs(exceptionsdir)
            except FileExistsError:
                pass

            # Remove all existing exception reports.
            for f in os.listdir(exceptionsdir):
                os.unlink(os.path.join(exceptionsdir, f))

            osenvironb[b'HGEXCEPTIONSDIR'] = exceptionsdir
            logexceptions = os.path.join(self._testdir, b'logexceptions.py')
            self.options.extra_config_opt.append(
                'extensions.logexceptions=%s' % logexceptions.decode('utf-8')
            )

        vlog("# Using TESTDIR", _bytes2sys(self._testdir))
        vlog("# Using RUNTESTDIR", _bytes2sys(osenvironb[b'RUNTESTDIR']))
        vlog("# Using HGTMP", _bytes2sys(self._hgtmp))
        vlog("# Using PATH", os.environ["PATH"])
        vlog("# Using PYTHONPATH", os.environ.get("PYTHONPATH", ""))
        vlog("# Writing to directory", _bytes2sys(self._outputdir))

        if shard_total is not None:
            slot = shard_index - 1
            testdescs = [
                t
                for (idx, t) in enumerate(testdescs)
                if (idx % shard_total == slot)
            ]

        try:
            return self._runtests(testdescs) or 0
        finally:
            time.sleep(0.1)
            self._cleanup()

    def findtests(self, args):
        """Finds possible test files from arguments.

        If you wish to inject custom tests into the test harness, this would
        be a good function to monkeypatch or override in a derived class.
        """
        if not args:
            if self.options.changed:
                proc = Popen4(
                    b'hg st --rev "%s" -man0 .'
                    % _sys2bytes(self.options.changed),
                    None,
                    0,
                )
                stdout, stderr = proc.communicate()
                args = stdout.strip(b'\0').split(b'\0')
            else:
                args = os.listdir(b'.')

        expanded_args = []
        for arg in args:
            if os.path.isdir(arg):
                if not arg.endswith(b'/'):
                    arg += b'/'
                expanded_args.extend([arg + a for a in os.listdir(arg)])
            else:
                expanded_args.append(arg)
        args = expanded_args

        testcasepattern = re.compile(br'([\w-]+\.t|py)(?:#([a-zA-Z0-9_\-.#]+))')
        tests = []
        for t in args:
            case = []

            if not (
                os.path.basename(t).startswith(b'test-')
                and (t.endswith(b'.py') or t.endswith(b'.t'))
            ):
                m = testcasepattern.match(os.path.basename(t))
                if m is not None:
                    t_basename, casestr = m.groups()
                    t = os.path.join(os.path.dirname(t), t_basename)
                    if casestr:
                        case = casestr.split(b'#')
                else:
                    continue

            if t.endswith(b'.t'):
                # .t file may contain multiple test cases
                casedimensions = parsettestcases(t)
                if casedimensions:
                    cases = []

                    def addcases(case, casedimensions):
                        if not casedimensions:
                            cases.append(case)
                        else:
                            for c in casedimensions[0]:
                                addcases(case + [c], casedimensions[1:])

                    addcases([], casedimensions)
                    if case and case in cases:
                        cases = [case]
                    elif case:
                        # Ignore invalid cases
                        cases = []
                    else:
                        pass
                    tests += [{'path': t, 'case': c} for c in sorted(cases)]
                else:
                    tests.append({'path': t})
            else:
                tests.append({'path': t})

        if self.options.retest:
            retest_args = []
            for test in tests:
                errpath = self._geterrpath(test)
                if os.path.exists(errpath):
                    retest_args.append(test)
            tests = retest_args
        return tests

    def _runtests(self, testdescs):
        def _reloadtest(test, i):
            # convert a test back to its description dict
            desc = {'path': test.path}
            case = getattr(test, '_case', [])
            if case:
                desc['case'] = case
            return self._gettest(desc, i)

        try:
            if self.options.restart:
                orig = list(testdescs)
                while testdescs:
                    desc = testdescs[0]
                    errpath = self._geterrpath(desc)
                    if os.path.exists(errpath):
                        break
                    testdescs.pop(0)
                if not testdescs:
                    print("running all tests")
                    testdescs = orig

            tests = [self._gettest(d, i) for i, d in enumerate(testdescs)]
            num_tests = len(tests) * self.options.runs_per_test

            jobs = min(num_tests, self.options.jobs)

            failed = False
            kws = self.options.keywords
            if kws is not None:
                kws = kws.encode('utf-8')

            suite = TestSuite(
                self._testdir,
                jobs=jobs,
                whitelist=self.options.whitelisted,
                blacklist=self.options.blacklist,
                keywords=kws,
                loop=self.options.loop,
                runs_per_test=self.options.runs_per_test,
                showchannels=self.options.showchannels,
                tail_report=self.options.tail_report,
                tests=tests,
                loadtest=_reloadtest,
            )
            verbosity = 1
            if self.options.list_tests:
                verbosity = 0
            elif self.options.verbose:
                verbosity = 2
            runner = TextTestRunner(self, verbosity=verbosity)

            osenvironb.pop(b'PYOXIDIZED_IN_MEMORY_RSRC', None)
            osenvironb.pop(b'PYOXIDIZED_FILESYSTEM_RSRC', None)

            if self.options.list_tests:
                result = runner.listtests(suite)
            else:
                install_start_time = time.monotonic()
                self._usecorrectpython()
                if self._installdir:
                    self._installhg()
                    self._check_hg("Testing")
                if self.options.chg:
                    assert self._installdir
                    self._installchg()
                if self.options.rhg:
                    assert self._installdir
                    self._installrhg()
                elif self.options.pyoxidized:
                    self._build_pyoxidized()
                self._use_correct_mercurial()
                install_end_time = time.monotonic()
                if self._installdir:
                    msg = 'installed Mercurial in %.2f seconds'
                    msg %= install_end_time - install_start_time
                    log(msg)

                log(
                    'running %d tests using %d parallel processes'
                    % (num_tests, jobs)
                )

                result = runner.run(suite)

            if result.failures or result.errors:
                failed = True

            result.onEnd()

            if self.options.anycoverage:
                self._outputcoverage()
        except KeyboardInterrupt:
            failed = True
            print("\ninterrupted!")

        if failed:
            return 1

    def _geterrpath(self, test):
        # test['path'] is a relative path
        if 'case' in test:
            # for multiple dimensions test cases
            casestr = b'#'.join(test['case'])
            errpath = b'%s#%s.err' % (test['path'], casestr)
        else:
            errpath = b'%s.err' % test['path']
        if self.options.outputdir:
            self._outputdir = canonpath(_sys2bytes(self.options.outputdir))
            errpath = os.path.join(self._outputdir, errpath)
        return errpath

    def _getport(self, count):
        port = self._ports.get(count)  # do we have a cached entry?
        if port is None:
            portneeded = HGPORT_COUNT
            # above 100 tries we just give up and let test reports failure
            for tries in range(100):
                allfree = True
                port = self.options.port + self._portoffset
                for idx in range(portneeded):
                    if not checkportisavailable(port + idx):
                        allfree = False
                        break
                self._portoffset += portneeded
                if allfree:
                    break
            self._ports[count] = port
        return port

    def _gettest(self, testdesc, count):
        """Obtain a Test by looking at its filename.

        Returns a Test instance. The Test may not be runnable if it doesn't
        map to a known type.
        """
        path = testdesc['path']
        lctest = path.lower()
        testcls = Test

        for ext, cls in self.TESTTYPES:
            if lctest.endswith(ext):
                testcls = cls
                break

        refpath = os.path.join(getcwdb(), path)
        tmpdir = os.path.join(self._hgtmp, b'child%d' % count)

        # extra keyword parameters. 'case' is used by .t tests
        kwds = {k: testdesc[k] for k in ['case'] if k in testdesc}

        t = testcls(
            refpath,
            self._outputdir,
            tmpdir,
            python=self._python,
            keeptmpdir=self.options.keep_tmpdir,
            debug=self.options.debug,
            first=self.options.first,
            timeout=self.options.timeout,
            startport=self._getport(count),
            extraconfigopts=self.options.extra_config_opt,
            shell=self.options.shell,
            hgcommand=self._hgcommand,
            usechg=bool(self.options.with_chg or self.options.chg),
            chgdebug=self.options.chg_debug,
            useipv6=useipv6,
            **kwds,
        )
        t.should_reload = True
        return t

    def _cleanup(self):
        """Clean up state from this test invocation."""
        if self.options.keep_tmpdir:
            return

        vlog("# Cleaning up HGTMP", _bytes2sys(self._hgtmp))
        shutil.rmtree(self._hgtmp, True)
        for f in self._createdfiles:
            try:
                os.remove(f)
            except OSError:
                pass

    def _usecorrectpython(self):
        """Configure the environment to use the appropriate Python in tests."""
        # Tests must use the same interpreter as us or bad things will happen.

        # install dir != None means we did install mercurial within a temporary
        # virtual env and do need to make sure the right python will be in
        # front of the PATH. Except for Windows who lack a `python3` executable
        # in this case.
        if self._installdir is None:
            pyexe_names = [b'python', b'python3']
        elif WINDOWS:
            pyexe_names = [b'python3']
        else:
            return

        # os.symlink() is a thing with py3 on Windows, but it requires
        # Administrator rights.
        if not WINDOWS and getattr(os, 'symlink', None):
            msg = "# Making python executable in test path a symlink to '%s'"
            msg %= self._python
            vlog(msg)
            for pyexename in pyexe_names:
                mypython = os.path.join(self._custom_bin_dir, pyexename)
                try:
                    if os.readlink(mypython) == self._python:
                        continue
                    os.unlink(mypython)
                except FileNotFoundError:
                    pass
                if self._findprogram(pyexename) != self._python:
                    try:
                        os.symlink(self._python, mypython)
                        self._createdfiles.append(mypython)
                    except FileExistsError:
                        # child processes may race, which is harmless
                        pass
        elif WINDOWS and not os.getenv('MSYSTEM'):
            raise AssertionError('cannot run test on Windows without MSYSTEM')
        else:
            # Generate explicit file instead of symlink
            #
            # This is especially important as Windows doesn't have
            # `python3.exe`, and MSYS cannot understand the reparse point with
            # that name provided by Microsoft.  Create a simple script on PATH
            # with that name that delegates to the py3 launcher so the shebang
            # lines work.
            esc_executable = _sys2bytes(shellquote(self._python))
            for pyexename in pyexe_names:
                stub_exec_path = os.path.join(self._custom_bin_dir, pyexename)
                with open(stub_exec_path, 'wb') as f:
                    f.write(b'#!/bin/sh\n')
                    f.write(b'%s "$@"\n' % esc_executable)

            if WINDOWS:
                # adjust the path to make sur the main python finds itself and
                # its own dll
                path = os.environ['PATH'].split(os.pathsep)
                main_exec_dir = os.path.dirname(self._python)
                extra_paths = [_bytes2sys(self._custom_bin_dir), main_exec_dir]

                # Binaries installed by pip into the user area like pylint.exe may
                # not be in PATH by default.
                appdata = os.environ.get('APPDATA')
                vi = sys.version_info
                if appdata is not None:
                    python_dir = 'Python%d%d' % (vi[0], vi[1])
                    scripts_path = [appdata, 'Python', python_dir, 'Scripts']
                    scripts_dir = os.path.join(*scripts_path)
                    extra_paths.append(scripts_dir)

                os.environ['PATH'] = os.pathsep.join(extra_paths + path)

    def _use_correct_mercurial(self):
        target_exec = os.path.join(self._custom_bin_dir, b'hg')
        # hgcommand is ≠ hg in case like `rhg` and `chg` or with windows .exe's
        if self._hgcommand != b'hg':
            real_exec = shutil.which(self._hgcommand)
            if real_exec is None:
                raise ValueError('could not find exec path for "%s"', real_exec)
            if real_exec == target_exec:
                # do not overwrite something with itself
                return
            if os.path.exists(target_exec):
                # there is already something at the destination. Let's not
                # overwrite it.
                return
            if WINDOWS:
                with open(target_exec, 'wb') as f:
                    f.write(b'#!/bin/sh\n')
                    escaped_exec = shellquote(_bytes2sys(real_exec))
                    f.write(b'%s "$@"\n' % _sys2bytes(escaped_exec))
            else:
                os.symlink(real_exec, target_exec)
            self._createdfiles.append(target_exec)

    def _install_hg_cmd_wheel(self):
        wheel_path = self.options.wheel
        assert wheel_path

        script = _sys2bytes(os.path.realpath(sys.argv[0]))
        hgroot = os.path.dirname(os.path.dirname(script))
        self._hgroot = hgroot
        os.chdir(hgroot)
        cmd = [
            self._pythonb,
            b"-m",
            b"pip",
            b"install",
            wheel_path,
            b"--no-cache-dir",
            b"--force",
            b"--ignore-installed",
        ]

        return cmd

    def _install_hg_cmd_setup(self):
        # Run installer in hg root
        setup_opts = b""
        if self.options.pure:
            setup_opts = b"--pure"
        elif self.options.rust:
            setup_opts = b"--rust"
        elif self.options.no_rust:
            setup_opts = b"--no-rust"

        script = _sys2bytes(os.path.realpath(sys.argv[0]))
        hgroot = os.path.dirname(os.path.dirname(script))
        self._hgroot = hgroot
        os.chdir(hgroot)
        cmd = [self._pythonb, b"-m", b"pip", b"install", b"."]
        if setup_opts:
            cmd.extend(
                [b"--config-settings", b"--global-option=%s" % setup_opts]
            )
        return cmd

    def _installhg(self):
        """Install hg into the test environment.

        This will also configure hg with the appropriate testing settings.
        """
        vlog("# Performing temporary installation of HG")
        install_env = original_env.copy()
        if self.options.wheel is None:
            cmd = self._install_hg_cmd_setup()
        else:
            cmd = self._install_hg_cmd_wheel()
            install_env["PYTHONUSERBASE"] = _bytes2sys(self._installdir)

        installerrs = os.path.join(self._hgtmp, b"install.err")
        if self.options.pure:
            install_env.pop('HGWITHRUSTEXT', None)
        elif self.options.no_rust:
            install_env.pop('HGWITHRUSTEXT', None)

        vlog("# Running", cmd)
        with open(installerrs, "wb") as logfile:
            r = subprocess.call(
                cmd,
                env=install_env,
                stdout=logfile,
                stderr=subprocess.STDOUT,
            )
        if r == 0:
            if not self.options.verbose:
                try:
                    os.remove(installerrs)
                except FileNotFoundError:
                    pass
        else:
            with open(installerrs, 'rb') as f:
                for line in f:
                    sys.stdout.buffer.write(line)
            sys.exit(1)
        os.chdir(self._testdir)

        hgbat = os.path.join(self._bindir, b'hg.bat')
        if os.path.isfile(hgbat):
            # hg.bat expects to be put in bin/scripts while run-tests.py
            # installation layout put it in bin/ directly. Fix it
            with open(hgbat, 'rb') as f:
                data = f.read()
            if br'"%~dp0..\python" "%~dp0hg" %*' in data:
                data = data.replace(
                    br'"%~dp0..\python" "%~dp0hg" %*',
                    b'"%~dp0python" "%~dp0hg" %*',
                )
                with open(hgbat, 'wb') as f:
                    f.write(data)
            else:
                print('WARNING: cannot fix hg.bat reference to python.exe')

        if self.options.anycoverage:
            custom = os.path.join(RUNTEST_DIR, b'sitecustomize.py')
            target = os.path.join(self._pythondir, b'sitecustomize.py')
            vlog('# Installing coverage trigger to %s' % target)
            shutil.copyfile(custom, target)
            rc = os.path.join(self._testdir, b'.coveragerc')
            vlog('# Installing coverage rc to %s' % rc)
            osenvironb[b'COVERAGE_PROCESS_START'] = rc
            covdir = os.path.join(self._installdir, b'..', b'coverage')
            try:
                os.mkdir(covdir)
            except FileExistsError:
                pass

            osenvironb[b'COVERAGE_DIR'] = covdir

    def _check_hg(self, verb):
        """Ensure that the 'mercurial' package imported by python is
        the one we expect it to be.  If not, print a warning to stderr."""
        if self._pythondir_inferred:
            # The pythondir has been inferred from --with-hg flag.
            # We cannot expect anything sensible here.
            return
        expecthg = os.path.join(self._pythondir, b'mercurial')
        actual_bin_hg = self._get_hg_bin_path()
        actual_py_hg = self._get_hg_py_path()
        if actual_bin_hg != actual_py_hg:
            msg = (
                b'fatal: "python" and "hg" disagree about mercurial lib path:\n'
                b'  hg: %s:\n'
                b'  py: %s:\n'
            )
            msg %= (actual_bin_hg, actual_py_hg)
            msg = colorize(msg.decode(), "red", self.options.color)
            sys.stderr.write(msg)
            sys.exit(2)
        if os.path.abspath(actual_py_hg) != os.path.abspath(expecthg):
            msg = (
                'warning: %s with unexpected mercurial lib: %s\n'
                '         (expected %s)\n'
            )
            msg %= (verb, actual_py_hg.decode(), expecthg.decode())
            msg = colorize(msg, "yellow", self.options.color)
            sys.stderr.write(msg)
        policy = self._get_hg_module_policy()
        msg = b"fatal: mercurial binary has unexpected flavor for %s: %s\n"
        err = None
        if self.options.pure and policy != b"py":
            err = msg % (b"--pure", policy)
        elif self.options.rust and b"rust" not in policy:
            err = msg % (b"--rust", policy)
        elif self.options.no_rust and b"rust" in policy:
            err = msg % (b"--no-rust", policy)
        if err is not None:
            err = colorize(err.decode(), "red", self.options.color)
            sys.stderr.write(err)
            sys.exit(3)

    @staticmethod
    def _get_debuginstall_env():
        """return the environment to run ``hg debuginstall`` safely"""
        # The debuginstall command checks a bunch of things, and exits with the
        # number of errors encountered, even if -T is passed and the template
        # didn't ask for things related to the error(s).  Supply a fallback so
        # that running tests without --local doesn't hinge on Mercurial being
        # configured on the current system.
        env = os.environ.copy()
        env["HGUSER"] = "test_gremlin"
        env["HGEDITOR"] = sys.executable  # The executable must exist
        return env

    def _get_hg_module_policy(self):
        """return the module policy as seen by the "hg" binary"""
        cmd = [
            _bytes2sys(self._real_hg),
            "debuginstall",
            "--template",
            "{hgmodulepolicy}",
        ]
        p = subprocess.Popen(
            " ".join(cmd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=True,
            env=self._get_debuginstall_env(),
        )
        out, err = p.communicate()
        if p.returncode != 0:
            msg = "fatal: fetching module policy from `hg` failed:\n"
            msg = colorize(msg, "red", self.options.color)
            sys.stderr.write(msg)
            cmd_err = colorize(err.decode(), "magenta", self.options.color)
            sys.stderr.write(cmd_err)
            cmd_err = colorize(out.decode(), "yellow", self.options.color)
            sys.stderr.write(cmd_err)
            sys.exit(4)
        return out

    def _get_hg_bin_path(self):
        """return the path to the mercurial lib according to the "hg" binary"""
        cmd = [
            _bytes2sys(self._real_hg),
            "debuginstall",
            "--template",
            "{hgmodules}",
        ]
        p = subprocess.Popen(
            " ".join(cmd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=True,
            env=self._get_debuginstall_env(),
        )
        out, err = p.communicate()
        if p.returncode != 0:
            msg = f"fatal: fetching library from `hg` failed with {p.returncode}:\n"
            msg = colorize(msg, "red", self.options.color)
            sys.stderr.write(msg)
            cmd_err = colorize(err.decode(), "magenta", self.options.color)
            sys.stderr.write(cmd_err)
            cmd_err = colorize(out.decode(), "yellow", self.options.color)
            sys.stderr.write(cmd_err)
            sys.exit(4)
        return out

    def _get_hg_py_path(self):
        """Return the path to the mercurial package that is actually found by
        the current Python interpreter."""
        if self._hgpath is not None:
            return self._hgpath

        # PYTHONSAFEPATH (-P) new in 3.11
        if sys.version_info >= (3, 11, 0):
            python_safe_path = "-P "
        else:
            python_safe_path = ""

        cmd = '"%s" %s-c "import mercurial; print (mercurial.__path__[0])"'
        cmd %= (self._python, python_safe_path)

        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, shell=True)
        out, err = p.communicate()

        self._hgpath = out.strip()

        return self._hgpath

    def _installchg(self):
        """Install chg into the test environment"""
        vlog('# Performing temporary installation of CHG')
        assert os.path.dirname(self._bindir) == self._installdir
        assert self._hgroot, 'must be called after _installhg()'
        cmd = b'"%(make)s" clean install PREFIX="%(prefix)s"' % {
            b'make': b'make',  # TODO: switch by option or environment?
            b'prefix': self._installdir,
        }
        cwd = os.path.join(self._hgroot, b'contrib', b'chg')
        vlog("# Running", cmd)
        proc = subprocess.Popen(
            cmd,
            shell=True,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        out, _err = proc.communicate()
        if proc.returncode != 0:
            sys.stdout.buffer.write(out)
            sys.exit(1)

    def _installrhg(self):
        """Install rhg into the test environment"""
        vlog('# Performing temporary installation of rhg')
        assert os.path.dirname(self._bindir) == self._installdir
        assert self._hgroot, 'must be called after _installhg()'
        cmd = b'"%(make)s" install-rhg PREFIX="%(prefix)s"' % {
            b'make': b'make',  # TODO: switch by option or environment?
            b'prefix': self._installdir,
        }
        cwd = self._hgroot
        vlog("# Running", cmd)
        proc = subprocess.Popen(
            cmd,
            shell=True,
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        out, _err = proc.communicate()
        if proc.returncode != 0:
            sys.stdout.buffer.write(out)
            sys.exit(1)

    def _build_pyoxidized(self):
        """build a pyoxidized version of mercurial into the test environment

        Ideally this function would be `install_pyoxidier` and would both build
        and install pyoxidier. However we are starting small to get pyoxidizer
        build binary to testing quickly.
        """
        vlog('# build a pyoxidized version of Mercurial')
        assert os.path.dirname(self._bindir) == self._installdir
        assert self._hgroot, 'must be called after _installhg()'
        target = b''
        if WINDOWS:
            target = b'windows'
        elif MACOS:
            target = b'macos'

        cmd = b'"%(make)s" pyoxidizer-%(platform)s-tests' % {
            b'make': b'make',
            b'platform': target,
        }
        cwd = self._hgroot
        vlog("# Running", cmd)
        proc = subprocess.Popen(
            _bytes2sys(cmd),
            shell=True,
            cwd=_bytes2sys(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        out, _err = proc.communicate()
        if proc.returncode != 0:
            sys.stdout.buffer.write(out)
            sys.exit(1)

        cmd = _bytes2sys(b"%s debuginstall -Tjson" % self._hgcommand)
        p = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            shell=True,
            env=self._get_debuginstall_env(),
        )
        out, err = p.communicate()

        props = json.loads(out)[0]

        # Affects hghave.py
        osenvironb.pop(b'PYOXIDIZED_IN_MEMORY_RSRC', None)
        osenvironb.pop(b'PYOXIDIZED_FILESYSTEM_RSRC', None)
        if props["hgmodules"] == props["pythonexe"]:
            osenvironb[b'PYOXIDIZED_IN_MEMORY_RSRC'] = b'1'
        else:
            osenvironb[b'PYOXIDIZED_FILESYSTEM_RSRC'] = b'1'

    def _outputcoverage(self):
        """Produce code coverage output."""
        import coverage

        coverage = coverage.coverage

        vlog('# Producing coverage report')
        # chdir is the easiest way to get short, relative paths in the
        # output.
        os.chdir(self._hgroot)
        covdir = os.path.join(_bytes2sys(self._installdir), '..', 'coverage')
        cov = coverage(data_file=os.path.join(covdir, 'cov'))

        # Map install directory paths back to source directory.
        cov.config.paths['srcdir'] = ['.', _bytes2sys(self._pythondir)]

        cov.combine()

        omit = [
            _bytes2sys(os.path.join(x, b'*'))
            for x in [self._bindir, self._testdir]
        ]
        cov.report(ignore_errors=True, omit=omit)

        if self.options.htmlcov:
            htmldir = os.path.join(_bytes2sys(self._outputdir), 'htmlcov')
            cov.html_report(directory=htmldir, omit=omit)
        if self.options.annotate:
            adir = os.path.join(_bytes2sys(self._outputdir), 'annotated')
            if not os.path.isdir(adir):
                os.mkdir(adir)
            cov.annotate(directory=adir, omit=omit)

    def _findprogram(self, program):
        """Search PATH for a executable program"""
        dpb = _sys2bytes(os.defpath)
        sepb = _sys2bytes(os.pathsep)
        for p in osenvironb.get(b'PATH', dpb).split(sepb):
            name = os.path.join(p, program)
            if WINDOWS or os.access(name, os.X_OK):
                return _bytes2sys(name)
        return None

    def _checktools(self):
        """Ensure tools required to run tests are present."""
        for p in self.REQUIREDTOOLS:
            if WINDOWS and not p.endswith(b'.exe'):
                p += b'.exe'
            found = self._findprogram(p)
            p = p.decode("utf-8")
            if found:
                vlog("# Found prerequisite", p, "at", found)
            else:
                print("WARNING: Did not find prerequisite tool: %s " % p)


def aggregateexceptions(path):
    exceptioncounts = collections.Counter()
    testsbyfailure = collections.defaultdict(set)
    failuresbytest = collections.defaultdict(set)

    for f in os.listdir(path):
        with open(os.path.join(path, f), 'rb') as fh:
            data = fh.read().split(b'\0')
            if len(data) != 5:
                continue

            exc, mainframe, hgframe, hgline, testname = data
            exc = exc.decode('utf-8')
            mainframe = mainframe.decode('utf-8')
            hgframe = hgframe.decode('utf-8')
            hgline = hgline.decode('utf-8')
            testname = testname.decode('utf-8')

            key = (hgframe, hgline, exc)
            exceptioncounts[key] += 1
            testsbyfailure[key].add(testname)
            failuresbytest[testname].add(key)

    # Find test having fewest failures for each failure.
    leastfailing = {}
    for key, tests in testsbyfailure.items():
        fewesttest = None
        fewestcount = 99999999
        for test in sorted(tests):
            if len(failuresbytest[test]) < fewestcount:
                fewesttest = test
                fewestcount = len(failuresbytest[test])

        leastfailing[key] = (fewestcount, fewesttest)

    # Create a combined counter so we can sort by total occurrences and
    # impacted tests.
    combined = {}
    for key in exceptioncounts:
        combined[key] = (
            exceptioncounts[key],
            len(testsbyfailure[key]),
            leastfailing[key][0],
            leastfailing[key][1],
        )

    return {
        'exceptioncounts': exceptioncounts,
        'total': sum(exceptioncounts.values()),
        'combined': combined,
        'leastfailing': leastfailing,
        'byfailure': testsbyfailure,
        'bytest': failuresbytest,
    }


if __name__ == '__main__':
    if WINDOWS and not os.getenv('MSYSTEM'):
        print('cannot run test on Windows without MSYSTEM', file=sys.stderr)
        print(
            '(if you need to do so contact the mercurial devs: '
            'mercurial@mercurial-scm.org)',
            file=sys.stderr,
        )
        sys.exit(255)

    runner = TestRunner()

    try:
        import msvcrt

        msvcrt.setmode(sys.stdin.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stdout.fileno(), os.O_BINARY)
        msvcrt.setmode(sys.stderr.fileno(), os.O_BINARY)
    except ImportError:
        pass

    sys.exit(runner.run(sys.argv[1:]))
