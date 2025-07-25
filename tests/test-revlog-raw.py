# test revlog interaction about raw data (flagprocessor)


import hashlib
import sys

from mercurial import (
    encoding,
    revlog,
    revlogutils,
    transaction,
    vfs,
)

from mercurial.revlogutils import (
    config,
    constants,
    deltas,
    flagutil,
)


class _NoTransaction:
    """transaction like object to update the nodemap outside a transaction"""

    def __init__(self):
        self._postclose = {}

    def addpostclose(self, callback_id, callback_func):
        self._postclose[callback_id] = callback_func

    def registertmp(self, *args, **kwargs):
        pass

    def addbackup(self, *args, **kwargs):
        pass

    def add(self, *args, **kwargs):
        pass

    def addabort(self, *args, **kwargs):
        pass

    def _report(self, *args):
        pass


# TESTTMP is optional. This makes it convenient to run without run-tests.py
tvfs = vfs.vfs(encoding.environ.get(b'TESTTMP', b'/tmp'))

# Enable generaldelta otherwise revlog won't use delta as expected by the test
tvfs.options = {
    b'generaldelta': True,
    b'revlogv1': True,
    b'delta-config': config.DeltaConfig(sparse_revlog=True),
}


def abort(msg):
    print('abort: %s' % msg)
    # Return 0 so run-tests.py could compare the output.
    sys.exit()


# Register a revlog processor for flag EXTSTORED.
#
# It simply prepends a fixed header, and replaces '1' to 'i'. So it has
# insertion and replacement, and may be interesting to test revlog's line-based
# deltas.
_extheader = b'E\n'


def readprocessor(self, rawtext):
    # True: the returned text could be used to verify hash
    text = rawtext[len(_extheader) :].replace(b'i', b'1')
    return text, True


def writeprocessor(self, text):
    # False: the returned rawtext shouldn't be used to verify hash
    rawtext = _extheader + text.replace(b'1', b'i')
    return rawtext, False


def rawprocessor(self, rawtext):
    # False: do not verify hash. Only the content returned by "readprocessor"
    # can be used to verify hash.
    return False


flagutil.addflagprocessor(
    revlog.REVIDX_EXTSTORED, (readprocessor, writeprocessor, rawprocessor)
)

# Utilities about reading and appending revlog


def newtransaction():
    # A transaction is required to write revlogs
    report = lambda msg: None
    return transaction.transaction(report, tvfs, {'plain': tvfs}, b'journal')


def newrevlog(name=b'_testrevlog', recreate=False):
    if recreate:
        tvfs.tryunlink(name + b'.i')
    target = (constants.KIND_OTHER, b'test')
    rlog = revlog.revlog(tvfs, target=target, radix=name)
    return rlog


def appendrev(rlog, text, tr, isext=False, isdelta=True):
    """Append a revision. If isext is True, set the EXTSTORED flag so flag
    processor will be used (and rawtext is different from text). If isdelta is
    True, force the revision to be a delta, otherwise it's full text.
    """
    nextrev = len(rlog)
    p1 = rlog.node(nextrev - 1)
    p2 = rlog.nullid
    if isext:
        flags = revlog.REVIDX_EXTSTORED
    else:
        flags = revlog.REVIDX_DEFAULT_FLAGS
    # Change storedeltachains temporarily, to override revlog's delta decision
    rlog._storedeltachains = isdelta
    try:
        rlog.addrevision(text, tr, nextrev, p1, p2, flags=flags)
        return nextrev
    except Exception as ex:
        abort('rev %d: failed to append: %s' % (nextrev, ex))
    finally:
        # Restore storedeltachains. It is always True, see revlog.__init__
        rlog._storedeltachains = True


def addgroupcopy(rlog, tr, destname=b'_destrevlog', optimaldelta=True):
    """Copy revlog to destname using revlog.addgroup. Return the copied revlog.

    This emulates push or pull. They use changegroup. Changegroup requires
    repo to work. We don't have a repo, so a dummy changegroup is used.

    If optimaldelta is True, use optimized delta parent, so the destination
    revlog could probably reuse it. Otherwise it builds sub-optimal delta, and
    the destination revlog needs more work to use it.

    This exercises some revlog.addgroup (and revlog._addrevision(text=None))
    code path, which is not covered by "appendrev" alone.
    """

    class dummychangegroup:
        @staticmethod
        def deltachunk(pnode):
            pnode = pnode or rlog.nullid
            parentrev = rlog.rev(pnode)
            r = parentrev + 1
            if r >= len(rlog):
                return {}
            if optimaldelta:
                deltaparent = parentrev
            else:
                # suboptimal deltaparent
                deltaparent = min(0, parentrev)
            if not rlog._candelta(deltaparent, r):
                deltaparent = -1
            return revlogutils.InboundRevision(
                node=rlog.node(r),
                p1=pnode,
                p2=rlog.nullid,
                link_node=rlog.node(rlog.linkrev(r)),
                flags=rlog.flags(r),
                delta_base=rlog.node(deltaparent),
                delta=rlog.revdiff(deltaparent, r),
                sidedata=rlog.sidedata(r),
            )

        def deltaiter(self):
            chain = None
            for chunkdata in iter(lambda: self.deltachunk(chain), {}):
                chain = chunkdata.node
                yield chunkdata

    def linkmap(lnode):
        return rlog.rev(lnode)

    dlog = newrevlog(destname, recreate=True)
    dummydeltas = dummychangegroup().deltaiter()
    dlog.addgroup(dummydeltas, linkmap, tr)
    return dlog


def lowlevelcopy(rlog, tr, destname=b'_destrevlog'):
    """Like addgroupcopy, but use the low level revlog._addrevision directly.

    It exercises some code paths that are hard to reach easily otherwise.
    """
    dlog = newrevlog(destname, recreate=True)
    for r in rlog:
        p1 = rlog.node(r - 1)
        p2 = rlog.nullid
        if r == 0 or (rlog.flags(r) & revlog.REVIDX_EXTSTORED):
            text = rlog.rawdata(r)
            cachedelta = None
        else:
            # deltaparent cannot have EXTSTORED flag.
            deltaparent = max(
                [-1]
                + [
                    p
                    for p in range(r)
                    if rlog.flags(p) & revlog.REVIDX_EXTSTORED == 0
                ]
            )
            text = None
            cachedelta = revlogutils.CachedDelta(
                deltaparent,
                rlog.revdiff(deltaparent, r),
            )
        flags = rlog.flags(r)
        with dlog._writing(_NoTransaction()):
            dlog._addrevision(
                rlog.node(r),
                text,
                tr,
                r,
                p1,
                p2,
                flags,
                cachedelta,
            )
    return dlog


# Utilities to generate revisions for testing


def genbits(n):
    """Given a number n, generate (2 ** (n * 2) + 1) numbers in range(2 ** n).
    i.e. the generated numbers have a width of n bits.

    The combination of two adjacent numbers will cover all possible cases.
    That is to say, given any x, y where both x, and y are in range(2 ** n),
    there is an x followed immediately by y in the generated sequence.
    """
    m = 2**n

    # Gray Code. See https://en.wikipedia.org/wiki/Gray_code
    gray = lambda x: x ^ (x >> 1)
    reversegray = {gray(i): i for i in range(m)}

    # Generate (n * 2) bit gray code, yield lower n bits as X, and look for
    # the next unused gray code where higher n bits equal to X.

    # For gray codes whose higher bits are X, a[X] of them have been used.
    a = [0] * m

    # Iterate from 0.
    x = 0
    yield x
    for i in range(m * m):
        x = reversegray[x]
        y = gray(a[x] + x * m) & (m - 1)
        assert a[x] < m
        a[x] += 1
        x = y
        yield x


def gentext(rev):
    '''Given a revision number, generate dummy text'''
    return b''.join(b'%d\n' % j for j in range(-1, rev % 5))


def writecases(rlog, tr):
    """Write some revisions interested to the test.

    The test is interested in 3 properties of a revision:

        - Is it a delta or a full text? (isdelta)
          This is to catch some delta application issues.
        - Does it have a flag of EXTSTORED? (isext)
          This is to catch some flag processor issues. Especially when
          interacted with revlog deltas.
        - Is its text empty? (isempty)
          This is less important. It is intended to try to catch some careless
          checks like "if text" instead of "if text is None". Note: if flag
          processor is involved, raw text may be not empty.

    Write 65 revisions. So that all combinations of the above flags for
    adjacent revisions are covered. That is to say,

        len(set(
            (r.delta, r.ext, r.empty, (r+1).delta, (r+1).ext, (r+1).empty)
            for r in range(len(rlog) - 1)
           )) is 64.

    Where "r.delta", "r.ext", and "r.empty" are booleans matching properties
    mentioned above.

    Return expected [(text, rawtext)].
    """
    result = []
    for i, x in enumerate(genbits(3)):
        isdelta, isext, isempty = bool(x & 1), bool(x & 2), bool(x & 4)
        if isempty:
            text = b''
        else:
            text = gentext(i)
        rev = appendrev(rlog, text, tr, isext=isext, isdelta=isdelta)

        # Verify text, rawtext, and rawsize
        if isext:
            rawtext = writeprocessor(None, text)[0]
        else:
            rawtext = text
        if rlog.rawsize(rev) != len(rawtext):
            abort('rev %d: wrong rawsize' % rev)
        if rlog.revision(rev) != text:
            abort('rev %d: wrong text' % rev)
        if rlog.rawdata(rev) != rawtext:
            abort('rev %d: wrong rawtext' % rev)
        result.append((text, rawtext))

        # Verify flags like isdelta, isext work as expected
        # isdelta can be overridden to False if this or p1 has isext set
        if bool(rlog.deltaparent(rev) > -1) and not isdelta:
            abort('rev %d: isdelta is unexpected' % rev)
        if bool(rlog.flags(rev)) != isext:
            abort('rev %d: isext is ineffective' % rev)
    return result


# Main test and checking


def checkrevlog(rlog, expected):
    '''Check if revlog has expected contents. expected is [(text, rawtext)]'''
    # Test using different access orders. This could expose some issues
    # depending on revlog caching (see revlog._cache).
    for r0 in range(len(rlog) - 1):
        r1 = r0 + 1
        for revorder in [[r0, r1], [r1, r0]]:
            for raworder in [[True], [False], [True, False], [False, True]]:
                nlog = newrevlog()
                for rev in revorder:
                    for raw in raworder:
                        if raw:
                            t = nlog.rawdata(rev)
                        else:
                            t = nlog.revision(rev)
                        if t != expected[rev][int(raw)]:
                            abort(
                                'rev %d: corrupted %stext'
                                % (rev, raw and 'raw' or '')
                            )


slicingdata = [
    ([0, 1, 2, 3, 55, 56, 58, 59, 60], [[0, 1], [2], [58], [59, 60]], 10),
    ([0, 1, 2, 3, 55, 56, 58, 59, 60], [[0, 1], [2], [58], [59, 60]], 10),
    (
        [-1, 0, 1, 2, 3, 55, 56, 58, 59, 60],
        [[-1, 0, 1], [2], [58], [59, 60]],
        10,
    ),
]


def slicingtest(rlog):
    old_delta_config = rlog.delta_config
    old_data_config = rlog.data_config
    rlog.delta_config = rlog.delta_config.copy()
    rlog.data_config = rlog.data_config.copy()
    try:
        # the test revlog is small, we remove the floor under which we
        # slicing is diregarded.
        rlog.data_config.sr_min_gap_size = 0
        rlog.delta_config.sr_min_gap_size = 0
        for item in slicingdata:
            chain, expected, target = item
            result = deltas.slicechunk(rlog, chain, targetsize=target)
            result = list(result)
            if result != expected:
                print('slicing differ:')
                print('  chain: %s' % chain)
                print('  target: %s' % target)
                print('  expected: %s' % expected)
                print('  result:   %s' % result)
    finally:
        rlog.delta_config = old_delta_config
        rlog.data_config = old_data_config


def md5sum(s):
    return hashlib.md5(s).digest()


def _maketext(*coord):
    """create piece of text according to range of integers

    The test returned use a md5sum of the integer to make it less
    compressible"""
    pieces = []
    for start, size in coord:
        num = range(start, start + size)
        p = [md5sum(b'%d' % r) for r in num]
        pieces.append(b'\n'.join(p))
    return b'\n'.join(pieces) + b'\n'


data = [
    _maketext((0, 120), (456, 60)),
    _maketext((0, 120), (345, 60)),
    _maketext((0, 120), (734, 60)),
    _maketext((0, 120), (734, 60), (923, 45)),
    _maketext((0, 120), (734, 60), (234, 45)),
    _maketext((0, 120), (734, 60), (564, 45)),
    _maketext((0, 120), (734, 60), (361, 45)),
    _maketext((0, 120), (734, 60), (489, 45)),
    _maketext((0, 120), (123, 60)),
    _maketext((0, 120), (145, 60)),
    _maketext((0, 120), (104, 60)),
    _maketext((0, 120), (430, 60)),
    _maketext((0, 120), (430, 60), (923, 45)),
    _maketext((0, 120), (430, 60), (234, 45)),
    _maketext((0, 120), (430, 60), (564, 45)),
    _maketext((0, 120), (430, 60), (361, 45)),
    _maketext((0, 120), (430, 60), (489, 45)),
    _maketext((0, 120), (249, 60)),
    _maketext((0, 120), (832, 60)),
    _maketext((0, 120), (891, 60)),
    _maketext((0, 120), (543, 60)),
    _maketext((0, 120), (120, 60)),
    _maketext((0, 120), (60, 60), (768, 30)),
    _maketext((0, 120), (60, 60), (260, 30)),
    _maketext((0, 120), (60, 60), (450, 30)),
    _maketext((0, 120), (60, 60), (361, 30)),
    _maketext((0, 120), (60, 60), (886, 30)),
    _maketext((0, 120), (60, 60), (116, 30)),
    _maketext((0, 120), (60, 60), (567, 30), (629, 40)),
    _maketext((0, 120), (60, 60), (569, 30), (745, 40)),
    _maketext((0, 120), (60, 60), (777, 30), (700, 40)),
    _maketext((0, 120), (60, 60), (618, 30), (398, 40), (158, 10)),
]


def makesnapshot(tr):
    rl = newrevlog(name=b'_snaprevlog3', recreate=True)
    for i in data:
        appendrev(rl, i, tr)
    return rl


snapshots = [-1, 0, 6, 8, 11, 17, 19, 21, 25, 30]


def issnapshottest(rlog):
    result = []
    if rlog.issnapshot(-1):
        result.append(-1)
    for rev in rlog:
        if rlog.issnapshot(rev):
            result.append(rev)
    if snapshots != result:
        print('snapshot differ:')
        print('  expected: %s' % snapshots)
        print('  got:      %s' % result)


snapshotmapall = {0: {6, 8, 11, 17, 19, 25}, 8: {21}, -1: {0, 30}}
snapshotmap15 = {0: {17, 19, 25}, 8: {21}, -1: {30}}


def findsnapshottest(rlog):
    cache = deltas.SnapshotCache()
    cache.update(rlog)
    resultall = dict(cache.snapshots)
    if resultall != snapshotmapall:
        print('snapshot map  differ:')
        print('  expected: %s' % snapshotmapall)
        print('  got:      %s' % resultall)
    cache15 = deltas.SnapshotCache()
    cache15.update(rlog, 15)
    result15 = dict(cache15.snapshots)
    if result15 != snapshotmap15:
        print('snapshot map  differ:')
        print('  expected: %s' % snapshotmap15)
        print('  got:      %s' % result15)


def maintest():
    with newtransaction() as tr:
        rl = newrevlog(recreate=True)
        expected = writecases(rl, tr)
        checkrevlog(rl, expected)
        print('local test passed')
        # Copy via revlog.addgroup
        rl1 = addgroupcopy(rl, tr)
        checkrevlog(rl1, expected)
        rl2 = addgroupcopy(rl, tr, optimaldelta=False)
        checkrevlog(rl2, expected)
        print('addgroupcopy test passed')
        # Copy via revlog.clone
        rl3 = newrevlog(name=b'_destrevlog3', recreate=True)
        rl.clone(tr, rl3)
        checkrevlog(rl3, expected)
        print('clone test passed')
        # Copy via low-level revlog._addrevision
        rl4 = lowlevelcopy(rl, tr)
        checkrevlog(rl4, expected)
        print('lowlevelcopy test passed')
        slicingtest(rl)
        print('slicing test passed')
        rl5 = makesnapshot(tr)
        issnapshottest(rl5)
        print('issnapshot test passed')
        findsnapshottest(rl5)
        print('findsnapshot test passed')


try:
    maintest()
except Exception as ex:
    abort('crashed: %s' % ex)
