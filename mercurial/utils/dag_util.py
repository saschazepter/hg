# dagop.py - graph ancestry and topology algorithm for revset
#
# Copyright 2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This module focus on more advance graph  function with much knownledge of the
# rest of the Mercurial API, for simpler functions see
# `mercurial.dagop`.

from __future__ import annotations

import heapq
import typing

from ..thirdparty import attr

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

from ..node import nullrev
from .. import (
    error,
    mdiff,
    patch,
    pycompat,
    scmutil,
    smartset,
)

baseset = smartset.baseset
generatorset = smartset.generatorset

# possible maximum depth between null and wdir()
maxlogdepth = 0x80000000


def _walkrevtree(pfunc, revs, startdepth, stopdepth, reverse):
    """Walk DAG using 'pfunc' from the given 'revs' nodes

    'pfunc(rev)' should return the parent/child revisions of the given 'rev'
    if 'reverse' is True/False respectively.

    Scan ends at the stopdepth (exlusive) if specified. Revisions found
    earlier than the startdepth are omitted.
    """
    if startdepth is None:
        startdepth = 0
    if stopdepth is None:
        stopdepth = maxlogdepth
    if stopdepth == 0:
        return
    if stopdepth < 0:
        raise error.ProgrammingError(b'negative stopdepth')
    if reverse:
        heapsign = -1  # max heap
    else:
        heapsign = +1  # min heap

    # load input revs lazily to heap so earlier revisions can be yielded
    # without fully computing the input revs
    revs.sort(reverse)
    irevs = iter(revs)
    pendingheap = []  # [(heapsign * rev, depth), ...] (i.e. lower depth first)

    inputrev = next(irevs, None)
    if inputrev is not None:
        heapq.heappush(pendingheap, (heapsign * inputrev, 0))

    lastrev = None
    while pendingheap:
        currev, curdepth = heapq.heappop(pendingheap)
        currev = heapsign * currev
        if currev == inputrev:
            inputrev = next(irevs, None)
            if inputrev is not None:
                heapq.heappush(pendingheap, (heapsign * inputrev, 0))
        # rescan parents until curdepth >= startdepth because queued entries
        # of the same revision are iterated from the lowest depth
        foundnew = currev != lastrev
        if foundnew and curdepth >= startdepth:
            lastrev = currev
            yield currev
        pdepth = curdepth + 1
        if foundnew and pdepth < stopdepth:
            for prev in pfunc(currev):
                if prev != nullrev:
                    heapq.heappush(pendingheap, (heapsign * prev, pdepth))


def filectxancestors(fctxs, followfirst=False):
    """Like filectx.ancestors(), but can walk from multiple files/revisions,
    and includes the given fctxs themselves

    Yields (rev, {fctx, ...}) pairs in descending order.
    """
    visit = {}
    visitheap = []

    def addvisit(fctx):
        rev = scmutil.intrev(fctx)
        if rev not in visit:
            visit[rev] = set()
            heapq.heappush(visitheap, -rev)  # max heap
        visit[rev].add(fctx)

    if followfirst:
        cut = 1
    else:
        cut = None

    for c in fctxs:
        addvisit(c)
    while visit:
        currev = -(heapq.heappop(visitheap))
        curfctxs = visit.pop(currev)
        yield currev, curfctxs
        for c in curfctxs:
            for parent in c.parents()[:cut]:
                addvisit(parent)
    assert not visitheap


def filerevancestors(fctxs, followfirst=False):
    """Like filectx.ancestors(), but can walk from multiple files/revisions,
    and includes the given fctxs themselves

    Returns a smartset.
    """
    gen = (rev for rev, _cs in filectxancestors(fctxs, followfirst))
    return generatorset(gen, iterasc=False)


def _genrevancestors(repo, revs, followfirst, startdepth, stopdepth, cutfunc):
    if followfirst:
        cut = 1
    else:
        cut = None
    cl = repo.changelog

    def plainpfunc(rev):
        try:
            return cl.parentrevs(rev)[:cut]
        except error.WdirUnsupported:
            return (pctx.rev() for pctx in repo[rev].parents()[:cut])

    if cutfunc is None:
        pfunc = plainpfunc
    else:
        pfunc = lambda rev: [r for r in plainpfunc(rev) if not cutfunc(r)]
        revs = revs.filter(lambda rev: not cutfunc(rev))
    return _walkrevtree(pfunc, revs, startdepth, stopdepth, reverse=True)


def revancestors(
    repo, revs, followfirst=False, startdepth=None, stopdepth=None, cutfunc=None
):
    r"""Like revlog.ancestors(), but supports additional options, includes
    the given revs themselves, and returns a smartset

    Scan ends at the stopdepth (exlusive) if specified. Revisions found
    earlier than the startdepth are omitted.

    If cutfunc is provided, it will be used to cut the traversal of the DAG.
    When cutfunc(X) returns True, the DAG traversal stops - revision X and
    X's ancestors in the traversal path will be skipped. This could be an
    optimization sometimes.

    Note: if Y is an ancestor of X, cutfunc(X) returning True does not
    necessarily mean Y will also be cut. Usually cutfunc(Y) also wants to
    return True in this case. For example,

        D     # revancestors(repo, D, cutfunc=lambda rev: rev == B)
        |\    # will include "A", because the path D -> C -> A was not cut.
        B C   # If "B" gets cut, "A" might want to be cut too.
        |/
        A
    """
    gen = _genrevancestors(
        repo, revs, followfirst, startdepth, stopdepth, cutfunc
    )
    return generatorset(gen, iterasc=False)


def _genrevdescendants(repo, revs, followfirst):
    if followfirst:
        cut = 1
    else:
        cut = None

    cl = repo.changelog
    first = revs.min()
    if first == nullrev:
        # Are there nodes with a null first parent and a non-null
        # second one? Maybe. Do we care? Probably not.
        yield first
        for i in cl:
            yield i
    else:
        seen = set(revs)
        for i in cl.revs(first):
            if i in seen:
                yield i
                continue
            for x in cl.parentrevs(i)[:cut]:
                if x != nullrev and x in seen:
                    seen.add(i)
                    yield i
                    break


def _builddescendantsmap(repo, startrev, followfirst):
    """Build map of 'rev -> child revs', offset from startrev"""
    cl = repo.changelog
    descmap = [[] for _rev in range(startrev, len(cl))]
    for currev in cl.revs(startrev + 1):
        p1rev, p2rev = cl.parentrevs(currev)
        if p1rev >= startrev:
            descmap[p1rev - startrev].append(currev)
        if not followfirst and p2rev != nullrev and p2rev >= startrev:
            descmap[p2rev - startrev].append(currev)
    return descmap


def _genrevdescendantsofdepth(repo, revs, followfirst, startdepth, stopdepth):
    startrev = revs.min()
    descmap = _builddescendantsmap(repo, startrev, followfirst)

    def pfunc(rev):
        return descmap[rev - startrev]

    return _walkrevtree(pfunc, revs, startdepth, stopdepth, reverse=False)


def revdescendants(repo, revs, followfirst, startdepth=None, stopdepth=None):
    """Like revlog.descendants() but supports additional options, includes
    the given revs themselves, and returns a smartset

    Scan ends at the stopdepth (exlusive) if specified. Revisions found
    earlier than the startdepth are omitted.
    """
    if startdepth is None and (stopdepth is None or stopdepth >= maxlogdepth):
        gen = _genrevdescendants(repo, revs, followfirst)
    else:
        gen = _genrevdescendantsofdepth(
            repo, revs, followfirst, startdepth, stopdepth
        )
    return generatorset(gen, iterasc=True)


class subsetparentswalker:
    r"""Scan adjacent ancestors in the graph given by the subset

    This computes parent-child relations in the sub graph filtered by
    a revset. Primary use case is to draw a revisions graph.

    In the following example, we consider that the node 'f' has edges to all
    ancestor nodes, but redundant paths are eliminated. The edge 'f'->'b'
    is eliminated because there is a path 'f'->'c'->'b' for example.

          - d - e -
         /         \
        a - b - c - f

    If the node 'c' is filtered out, the edge 'f'->'b' is activated.

          - d - e -
         /         \
        a - b -(c)- f

    Likewise, if 'd' and 'e' are filtered out, this edge is fully eliminated
    since there is a path 'f'->'c'->'b'->'a' for 'f'->'a'.

           (d) (e)

        a - b - c - f

    Implementation-wise, 'f' is passed down to 'a' as unresolved through the
    'f'->'e'->'d'->'a' path, whereas we do also remember that 'f' has already
    been resolved while walking down the 'f'->'c'->'b'->'a' path. When
    processing the node 'a', the unresolved 'f'->'a' path is eliminated as
    the 'f' end is marked as resolved.

    Ancestors are searched from the tipmost revision in the subset so the
    results can be cached. You should specify startrev to narrow the search
    space to ':startrev'.
    """

    def __init__(self, repo, subset, startrev=None):
        if startrev is not None:
            subset = repo.revs(b'%d:null', startrev) & subset

        # equivalent to 'subset = subset.sorted(reverse=True)', but there's
        # no such function.
        fastdesc = subset.fastdesc
        if fastdesc:
            desciter = fastdesc()
        else:
            if not subset.isdescending() and not subset.istopo():
                subset = smartset.baseset(subset)
                subset.sort(reverse=True)
            desciter = iter(subset)

        self._repo = repo
        self._changelog = repo.changelog
        self._subset = subset

        # scanning state (see _scanparents):
        self._tovisit = []
        self._pendingcnt = {}
        self._pointers = {}
        self._parents = {}
        self._inputhead = nullrev  # reassigned by self._advanceinput()
        self._inputtail = desciter
        self._bottomrev = nullrev
        self._advanceinput()

    def parentsset(self, rev):
        """Look up parents of the given revision in the subset, and returns
        as a smartset"""
        return smartset.baseset(self.parents(rev))

    def parents(self, rev):
        """Look up parents of the given revision in the subset

        The returned revisions are sorted by parent index (p1/p2).
        """
        self._scanparents(rev)
        return [r for _c, r in sorted(self._parents.get(rev, []))]

    def _parentrevs(self, rev):
        try:
            revs = self._changelog.parentrevs(rev)
            if revs[-1] == nullrev:
                return revs[:-1]
            return revs
        except error.WdirUnsupported:
            return tuple(pctx.rev() for pctx in self._repo[None].parents())

    def _advanceinput(self):
        """Advance the input iterator and set the next revision to _inputhead"""
        if self._inputhead < nullrev:
            return
        try:
            self._inputhead = next(self._inputtail)
        except StopIteration:
            self._bottomrev = self._inputhead
            self._inputhead = nullrev - 1

    def _scanparents(self, stoprev):
        """Scan ancestors until the parents of the specified stoprev are
        resolved"""

        # 'tovisit' is the queue of the input revisions and their ancestors.
        # It will be populated incrementally to minimize the initial cost
        # of computing the given subset.
        #
        # For to-visit revisions, we keep track of
        # - the number of the unresolved paths: pendingcnt[rev],
        # - dict of the unresolved descendants and chains: pointers[rev][0],
        # - set of the already resolved descendants: pointers[rev][1].
        #
        # When a revision is visited, 'pointers[rev]' should be popped and
        # propagated to its parents accordingly.
        #
        # Once all pending paths have been resolved, 'pendingcnt[rev]' becomes
        # 0 and 'parents[rev]' contains the unsorted list of parent revisions
        # and p1/p2 chains (excluding linear paths.) The p1/p2 chains will be
        # used as a sort key preferring p1. 'len(chain)' should be the number
        # of merges between two revisions.

        subset = self._subset
        tovisit = self._tovisit  # heap queue of [-rev]
        pendingcnt = self._pendingcnt  # {rev: count} for visited revisions
        pointers = self._pointers  # {rev: [{unresolved_rev: chain}, resolved]}
        parents = self._parents  # {rev: [(chain, rev)]}

        while tovisit or self._inputhead >= nullrev:
            if pendingcnt.get(stoprev) == 0:
                return

            # feed greater revisions from input set to queue
            if not tovisit:
                heapq.heappush(tovisit, -self._inputhead)
                self._advanceinput()
            while self._inputhead >= -tovisit[0]:
                heapq.heappush(tovisit, -self._inputhead)
                self._advanceinput()

            rev = -heapq.heappop(tovisit)
            if rev < self._bottomrev:
                return
            if rev in pendingcnt and rev not in pointers:
                continue  # already visited

            curactive = rev in subset
            pendingcnt.setdefault(rev, 0)  # mark as visited
            if curactive:
                assert rev not in parents
                parents[rev] = []
            unresolved, resolved = pointers.pop(rev, ({}, set()))

            if curactive:
                # reached to active rev, resolve pending descendants' parents
                for r, c in unresolved.items():
                    pendingcnt[r] -= 1
                    assert pendingcnt[r] >= 0
                    if r in resolved:
                        continue  # eliminate redundant path
                    parents[r].append((c, rev))
                    # mark the descendant 'r' as resolved through this path if
                    # there are still pending pointers. the 'resolved' set may
                    # be concatenated later at a fork revision.
                    if pendingcnt[r] > 0:
                        resolved.add(r)
                unresolved.clear()
                # occasionally clean resolved markers. otherwise the set
                # would grow indefinitely.
                resolved = {r for r in resolved if pendingcnt[r] > 0}

            parentrevs = self._parentrevs(rev)
            bothparentsactive = all(p in subset for p in parentrevs)

            # set up or propagate tracking pointers if
            # - one of the parents is not active,
            # - or descendants' parents are unresolved.
            if not bothparentsactive or unresolved or resolved:
                if len(parentrevs) <= 1:
                    # can avoid copying the tracking pointer
                    parentpointers = [(unresolved, resolved)]
                else:
                    parentpointers = [
                        (unresolved, resolved),
                        (unresolved.copy(), resolved.copy()),
                    ]
                    # 'rev' is a merge revision. increment the pending count
                    # as the 'unresolved' dict will be duplicated, and append
                    # p1/p2 code to the existing chains.
                    for r in unresolved:
                        pendingcnt[r] += 1
                        parentpointers[0][0][r] += b'1'
                        parentpointers[1][0][r] += b'2'
                for i, p in enumerate(parentrevs):
                    assert p < rev
                    heapq.heappush(tovisit, -p)
                    if p in pointers:
                        # 'p' is a fork revision. concatenate tracking pointers
                        # and decrement the pending count accordingly.
                        knownunresolved, knownresolved = pointers[p]
                        unresolved, resolved = parentpointers[i]
                        for r, c in unresolved.items():
                            if r in knownunresolved:
                                # unresolved at both paths
                                pendingcnt[r] -= 1
                                assert pendingcnt[r] > 0
                                # take shorter chain
                                knownunresolved[r] = min(c, knownunresolved[r])
                            else:
                                knownunresolved[r] = c
                        # simply propagate the 'resolved' set as deduplicating
                        # 'unresolved' here would be slightly complicated.
                        knownresolved.update(resolved)
                    else:
                        pointers[p] = parentpointers[i]

            # then, populate the active parents directly and add the current
            # 'rev' to the tracking pointers of the inactive parents.
            # 'pointers[p]' may be optimized out if both parents are active.
            chaincodes = [b''] if len(parentrevs) <= 1 else [b'1', b'2']
            if curactive and bothparentsactive:
                for i, p in enumerate(parentrevs):
                    c = chaincodes[i]
                    parents[rev].append((c, p))
                    # no need to mark 'rev' as resolved since the 'rev' should
                    # be fully resolved (i.e. pendingcnt[rev] == 0)
                assert pendingcnt[rev] == 0
            elif curactive:
                for i, p in enumerate(parentrevs):
                    unresolved, resolved = pointers[p]
                    assert rev not in unresolved
                    c = chaincodes[i]
                    if p in subset:
                        parents[rev].append((c, p))
                        # mark 'rev' as resolved through this path
                        resolved.add(rev)
                    else:
                        pendingcnt[rev] += 1
                        unresolved[rev] = c
                assert 0 < pendingcnt[rev] <= 2


def reachableroots(repo, roots, heads, includepath=False):
    """See revlog.reachableroots"""
    if not roots:
        return baseset()
    minroot = roots.min()
    roots = list(roots)
    heads = list(heads)
    revs = repo.changelog.reachableroots(minroot, heads, roots, includepath)
    revs = baseset(revs)
    revs.sort()
    return revs


def _changesrange(fctx1, fctx2, linerange2, diffopts):
    """Return `(diffinrange, linerange1)` where `diffinrange` is True
    if diff from fctx2 to fctx1 has changes in linerange2 and
    `linerange1` is the new line range for fctx1.
    """
    blocks = mdiff.allblocks(fctx1.data(), fctx2.data(), diffopts)
    filteredblocks, linerange1 = mdiff.blocksinrange(blocks, linerange2)
    diffinrange = any(stype == b'!' for _, stype in filteredblocks)
    return diffinrange, linerange1


def blockancestors(fctx, fromline, toline, followfirst=False):
    """Yield ancestors of `fctx` with respect to the block of lines within
    `fromline`-`toline` range.
    """
    diffopts = patch.diffopts(fctx._repo.ui)
    fctx = fctx.introfilectx()
    visit = {(fctx.linkrev(), fctx.filenode()): (fctx, (fromline, toline))}
    while visit:
        c, linerange2 = visit.pop(max(visit))
        pl = c.parents()
        if followfirst:
            pl = pl[:1]
        if not pl:
            # The block originates from the initial revision.
            yield c, linerange2
            continue
        inrange = False
        for p in pl:
            inrangep, linerange1 = _changesrange(p, c, linerange2, diffopts)
            inrange = inrange or inrangep
            if linerange1[0] == linerange1[1]:
                # Parent's linerange is empty, meaning that the block got
                # introduced in this revision; no need to go futher in this
                # branch.
                continue
            # Set _descendantrev with 'c' (a known descendant) so that, when
            # _adjustlinkrev is called for 'p', it receives this descendant
            # (as srcrev) instead possibly topmost introrev.
            p._descendantrev = c.rev()
            visit[p.linkrev(), p.filenode()] = p, linerange1
        if inrange:
            yield c, linerange2


def blockdescendants(fctx, fromline, toline):
    """Yield descendants of `fctx` with respect to the block of lines within
    `fromline`-`toline` range.
    """
    # First possibly yield 'fctx' if it has changes in range with respect to
    # its parents.
    try:
        c, linerange1 = next(blockancestors(fctx, fromline, toline))
    except StopIteration:
        pass
    else:
        if c == fctx:
            yield c, linerange1

    diffopts = patch.diffopts(fctx._repo.ui)
    fl = fctx.filelog()
    seen = {fctx.filerev(): (fctx, (fromline, toline))}
    for i in fl.descendants([fctx.filerev()]):
        c = fctx.filectx(i)
        inrange = False
        for x in fl.parentrevs(i):
            try:
                p, linerange2 = seen[x]
            except KeyError:
                # nullrev or other branch
                continue
            inrangep, linerange1 = _changesrange(c, p, linerange2, diffopts)
            inrange = inrange or inrangep
            # If revision 'i' has been seen (it's a merge) and the line range
            # previously computed differs from the one we just got, we take the
            # surrounding interval. This is conservative but avoids loosing
            # information.
            if i in seen and seen[i][1] != linerange1:
                lbs, ubs = zip(linerange1, seen[i][1])
                linerange1 = min(lbs), max(ubs)
            seen[i] = c, linerange1
        if inrange:
            yield c, linerange1


@attr.s(slots=True, frozen=True)
class annotateline:
    fctx = attr.ib()
    lineno = attr.ib()
    # Whether this annotation was the result of a skip-annotate.
    skip = attr.ib(default=False)
    text = attr.ib(default=None)


@attr.s(slots=True, frozen=True)
class _annotatedfile:
    # list indexed by lineno - 1
    fctxs = attr.ib()
    linenos = attr.ib()
    skips = attr.ib()
    # full file content
    text = attr.ib()


def _countlines(text):
    if text.endswith(b"\n"):
        return text.count(b"\n")
    return text.count(b"\n") + int(bool(text))


def _decoratelines(text, fctx):
    n = _countlines(text)
    linenos = pycompat.rangelist(1, n + 1)
    return _annotatedfile([fctx] * n, linenos, [False] * n, text)


def _annotatepair(parents, childfctx, child, skipchild, diffopts):
    r"""
    Given parent and child fctxes and annotate data for parents, for all lines
    in either parent that match the child, annotate the child with the parent's
    data.

    Additionally, if `skipchild` is True, replace all other lines with parent
    annotate data as well such that child is never blamed for any lines.

    See test-annotate.py for unit tests.
    """
    pblocks = [
        (parent, mdiff.allblocks(parent.text, child.text, opts=diffopts))
        for parent in parents
    ]

    if skipchild:
        # Need to iterate over the blocks twice -- make it a list
        pblocks = [(p, list(blocks)) for (p, blocks) in pblocks]
    # Mercurial currently prefers p2 over p1 for annotate.
    # TODO: change this?
    for parent, blocks in pblocks:
        for (a1, a2, b1, b2), t in blocks:
            # Changed blocks ('!') or blocks made only of blank lines ('~')
            # belong to the child.
            if t == b'=':
                child.fctxs[b1:b2] = parent.fctxs[a1:a2]
                child.linenos[b1:b2] = parent.linenos[a1:a2]
                child.skips[b1:b2] = parent.skips[a1:a2]

    if skipchild:
        # Now try and match up anything that couldn't be matched,
        # Reversing pblocks maintains bias towards p2, matching above
        # behavior.
        pblocks.reverse()

        # The heuristics are:
        # * Work on blocks of changed lines (effectively diff hunks with -U0).
        # This could potentially be smarter but works well enough.
        # * For a non-matching section, do a best-effort fit. Match lines in
        #   diff hunks 1:1, dropping lines as necessary.
        # * Repeat the last line as a last resort.

        # First, replace as much as possible without repeating the last line.
        remaining = [(parent, []) for parent, _blocks in pblocks]
        for idx, (parent, blocks) in enumerate(pblocks):
            for (a1, a2, b1, b2), _t in blocks:
                if a2 - a1 >= b2 - b1:
                    for bk in range(b1, b2):
                        if child.fctxs[bk] == childfctx:
                            ak = min(a1 + (bk - b1), a2 - 1)
                            child.fctxs[bk] = parent.fctxs[ak]
                            child.linenos[bk] = parent.linenos[ak]
                            child.skips[bk] = True
                else:
                    remaining[idx][1].append((a1, a2, b1, b2))

        # Then, look at anything left, which might involve repeating the last
        # line.
        for parent, blocks in remaining:
            for a1, a2, b1, b2 in blocks:
                for bk in range(b1, b2):
                    if child.fctxs[bk] == childfctx:
                        ak = min(a1 + (bk - b1), a2 - 1)
                        child.fctxs[bk] = parent.fctxs[ak]
                        child.linenos[bk] = parent.linenos[ak]
                        child.skips[bk] = True
    return child


def annotate(base, parents, skiprevs=None, diffopts=None) -> list[annotateline]:
    """Core algorithm for filectx.annotate()

    `parents(fctx)` is a function returning a list of parent filectxs.
    """

    # This algorithm would prefer to be recursive, but Python is a
    # bit recursion-hostile. Instead we do an iterative
    # depth-first search.

    # 1st DFS pre-calculates pcache and needed
    visit = [base]
    pcache = {}
    needed = {base: 1}
    while visit:
        f = visit.pop()
        if f in pcache:
            continue
        pl = parents(f)
        pcache[f] = pl
        for p in pl:
            needed[p] = needed.get(p, 0) + 1
            if p not in pcache:
                visit.append(p)

    # 2nd DFS does the actual annotate
    visit[:] = [base]
    hist = {}
    while visit:
        f = visit[-1]
        if f in hist:
            visit.pop()
            continue

        ready = True
        pl = pcache[f]
        for p in pl:
            if p not in hist:
                ready = False
                visit.append(p)
        if ready:
            visit.pop()
            curr = _decoratelines(f.data(), f)
            skipchild = False
            if skiprevs is not None:
                skipchild = f._changeid in skiprevs
            curr = _annotatepair(
                [hist[p] for p in pl], f, curr, skipchild, diffopts
            )
            for p in pl:
                if needed[p] == 1:
                    del hist[p]
                    del needed[p]
                else:
                    needed[p] -= 1

            hist[f] = curr
            del pcache[f]

    a = hist[base]
    return [
        annotateline(*r)
        for r in zip(a.fctxs, a.linenos, a.skips, mdiff.splitnewlines(a.text))
    ]
