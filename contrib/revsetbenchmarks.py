#!/usr/bin/env python3

# Measure the performance of a list of revsets against multiple revisions
# defined by parameter. Checkout one by one and run perfrevset with every
# revset in the list to benchmark its performance.
#
# You should run this from the root of your mercurial repository.
#
# call with --help for details

import math
import optparse  # cannot use argparse, python 2.7 only
import os
import re
import subprocess
import sys

DEFAULTVARIANTS = [
    'plain',
    'min',
    'max',
    'first',
    'last',
    'reverse',
    'reverse+first',
    'reverse+last',
    'sort',
    'sort+first',
    'sort+last',
]


def check_output(*args, **kwargs):
    kwargs.setdefault('stderr', subprocess.PIPE)
    kwargs.setdefault('stdout', subprocess.PIPE)
    proc = subprocess.Popen(*args, **kwargs)
    output, error = proc.communicate()
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, ' '.join(args[0]))
    return output


def update(rev):
    """update the repo to a revision"""
    try:
        subprocess.check_call(['hg', 'update', '--quiet', '--check', str(rev)])
        check_output(
            ['make', 'local'], stderr=None
        )  # suppress output except for error/warning
    except subprocess.CalledProcessError as exc:
        print('update to revision %s failed, aborting' % rev, file=sys.stderr)
        sys.exit(exc.returncode)


def hg(cmd, repo=None):
    """run a mercurial command

    <cmd> is the list of command + argument,
    <repo> is an optional repository path to run this command in."""
    fullcmd = ['./hg']
    if repo is not None:
        fullcmd += ['-R', repo]
    fullcmd += [
        '--config',
        'extensions.perf=' + os.path.join(contribdir, 'perf.py'),
    ]
    fullcmd += cmd
    return check_output(fullcmd, stderr=subprocess.STDOUT)


def perf(revset, target=None, contexts=False):
    """run benchmark for this very revset"""
    try:
        args = ['perfrevset']
        if contexts:
            args.append('--contexts')
        args.append('--')
        args.append(revset)
        output = hg(args, repo=target)
        return parseoutput(output)
    except subprocess.CalledProcessError as exc:
        print(
            'abort: cannot run revset benchmark: %s' % exc.cmd, file=sys.stderr
        )
        if getattr(exc, 'output', None) is None:  # no output before 2.7
            print('(no output)', file=sys.stderr)
        else:
            print(exc.output, file=sys.stderr)
        return None


outputre = re.compile(
    br'! wall (\d+.\d+) comb (\d+.\d+) user (\d+.\d+) '
    br'sys (\d+.\d+) \(best of (\d+)\)'
)


def parseoutput(output):
    """parse a textual output into a dict

    We cannot just use json because we want to compare with old
    versions of Mercurial that may not support json output.
    """
    match = outputre.search(output)
    if not match:
        print('abort: invalid output:', file=sys.stderr)
        print(output, file=sys.stderr)
        sys.exit(1)
    return {
        'comb': float(match.group(2)),
        'count': int(match.group(5)),
        'sys': float(match.group(3)),
        'user': float(match.group(4)),
        'wall': float(match.group(1)),
    }


def printrevision(rev):
    """print data about a revision"""
    sys.stdout.write("Revision ")
    sys.stdout.flush()
    subprocess.check_call(
        [
            'hg',
            'log',
            '--rev',
            str(rev),
            '--template',
            '{if(tags, " ({tags})")} ' '{rev}:{node|short}: {desc|firstline}\n',
        ]
    )


def idxwidth(nbidx):
    """return the max width of number used for index

    This is similar to log10(nbidx), but we use custom code here
    because we start with zero and we'd rather not deal with all the
    extra rounding business that log10 would imply.
    """
    nbidx -= 1  # starts at 0
    idxwidth = 0
    while nbidx:
        idxwidth += 1
        nbidx //= 10
    if not idxwidth:
        idxwidth = 1
    return idxwidth


def getfactor(main, other, field, sensitivity=0.05):
    """return the relative factor between values for 'field' in main and other

    Return None if the factor is insignificant (less than <sensitivity>
    variation)."""
    factor = 1
    if main is not None:
        factor = other[field] / main[field]
    low, high = 1 - sensitivity, 1 + sensitivity
    if low < factor < high:
        return None
    return factor


def formatfactor(factor):
    """format a factor into a 4 char string

     22%
    156%
    x2.4
     x23
    x789
    x1e4
    x5x7

    """
    if factor is None:
        return '    '
    elif factor < 2:
        return '%3i%%' % (factor * 100)
    elif factor < 10:
        return 'x%3.1f' % factor
    elif factor < 1000:
        return '%4s' % ('x%i' % factor)
    else:
        order = int(math.log(factor)) + 1
        while math.log(factor) > 1:
            factor //= 0
        return 'x%ix%i' % (factor, order)


def formattiming(value):
    """format a value to strictly 8 char, dropping some precision if needed"""
    if value < 10**7:
        return ('%.6f' % value)[:8]
    else:
        # value is HUGE very unlikely to happen (4+ month run)
        return '%i' % value


_marker = object()


def printresult(variants, idx, data, maxidx, verbose=False, reference=_marker):
    """print a line of result to stdout"""
    mask = '%%0%ii) %%s' % idxwidth(maxidx)

    out = []
    for var in variants:
        if data[var] is None:
            out.append('error   ')
            out.append(' ' * 4)
            continue
        out.append(formattiming(data[var]['wall']))
        if reference is not _marker:
            factor = None
            if reference is not None:
                factor = getfactor(reference[var], data[var], 'wall')
            out.append(formatfactor(factor))
        if verbose:
            out.append(formattiming(data[var]['comb']))
            out.append(formattiming(data[var]['user']))
            out.append(formattiming(data[var]['sys']))
            out.append('%6d' % data[var]['count'])
    print(mask % (idx, ' '.join(out)))


def printheader(variants, maxidx, verbose=False, relative=False):
    header = [' ' * (idxwidth(maxidx) + 1)]
    for var in variants:
        if not var:
            var = 'iter'
        if len(var) > 8:
            var = var[:3] + '..' + var[-3:]
        header.append('%-8s' % var)
        if relative:
            header.append('    ')
        if verbose:
            header.append('%-8s' % 'comb')
            header.append('%-8s' % 'user')
            header.append('%-8s' % 'sys')
            header.append('%6s' % 'count')
    print(' '.join(header))


def getrevs(spec):
    """get the list of rev matched by a revset"""
    try:
        out = check_output(['hg', 'log', '--template={rev}\n', '--rev', spec])
    except subprocess.CalledProcessError as exc:
        print("abort, can't get revision from %s" % spec, file=sys.stderr)
        sys.exit(exc.returncode)
    return [r for r in out.split() if r]


def applyvariants(revset, variant):
    if variant == 'plain':
        return revset
    for var in variant.split('+'):
        revset = '%s(%s)' % (var, revset)
    return revset


helptext = """This script will run multiple variants of provided revsets using
different revisions in your mercurial repository. After the benchmark are run
summary output is provided. Use it to demonstrate speed improvements or pin
point regressions. Revsets to run are specified in a file (or from stdin), one
revsets per line. Line starting with '#' will be ignored, allowing insertion of
comments."""
parser = optparse.OptionParser(
    usage="usage: %prog [options] <revs>", description=helptext
)
parser.add_option(
    "-f",
    "--file",
    help="read revset from FILE (stdin if omitted)",
    metavar="FILE",
)
parser.add_option("-R", "--repo", help="run benchmark on REPO", metavar="REPO")

parser.add_option(
    "-v",
    "--verbose",
    action='store_true',
    help="display all timing data (not just best total time)",
)

parser.add_option(
    "",
    "--variants",
    default=','.join(DEFAULTVARIANTS),
    help="comma separated list of variant to test "
    "(eg: plain,min,sorted) (plain = no modification)",
)
parser.add_option(
    '',
    '--contexts',
    action='store_true',
    help='obtain changectx from results instead of integer revs',
)

(options, args) = parser.parse_args()

if not args:
    parser.print_help()
    sys.exit(255)

# the directory where both this script and the perf.py extension live.
contribdir = os.path.dirname(__file__)

revsetsfile = sys.stdin
if options.file:
    revsetsfile = open(options.file)

revsets = [l.strip() for l in revsetsfile if not l.startswith('#')]
revsets = [l for l in revsets if l]

print("Revsets to benchmark")
print("----------------------------")

for idx, rset in enumerate(revsets):
    print("%i) %s" % (idx, rset))

print("----------------------------")
print()

revs = []
for a in args:
    revs.extend(getrevs(a))

variants = options.variants.split(',')

results = []
for r in revs:
    print("----------------------------")
    printrevision(r)
    print("----------------------------")
    update(r)
    res = []
    results.append(res)
    printheader(variants, len(revsets), verbose=options.verbose)
    for idx, rset in enumerate(revsets):
        varres = {}
        for var in variants:
            varrset = applyvariants(rset, var)
            data = perf(varrset, target=options.repo, contexts=options.contexts)
            varres[var] = data
        res.append(varres)
        printresult(
            variants, idx, varres, len(revsets), verbose=options.verbose
        )
        sys.stdout.flush()
    print("----------------------------")


print(
    """

Result by revset
================
"""
)

print('Revision:')
for idx, rev in enumerate(revs):
    sys.stdout.write('%i) ' % idx)
    sys.stdout.flush()
    printrevision(rev)

print()
print()

for ridx, rset in enumerate(revsets):
    print("revset #%i: %s" % (ridx, rset))
    printheader(variants, len(results), verbose=options.verbose, relative=True)
    ref = None
    for idx, data in enumerate(results):
        printresult(
            variants,
            idx,
            data[ridx],
            len(results),
            verbose=options.verbose,
            reference=ref,
        )
        ref = data[ridx]
    print()
