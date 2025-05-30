# dagop.py - graph ancestry and topology algorithm for revset
#
# Copyright 2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This module focus on simple graph algorithm without much knownledge of the
# rest of the Mercurial API, for richer functions see
# `mercurial.utils.dag_util`.

from __future__ import annotations

import heapq

from .node import nullrev

# possible maximum depth between null and wdir()
maxlogdepth = 0x80000000


def descendantrevs(revs, revsfn, parentrevsfn):
    """Generate revision number descendants in revision order.

    Yields revision numbers starting with a child of some rev in
    ``revs``. Results are ordered by revision number and are
    therefore topological. Each revision is not considered a descendant
    of itself.

    ``revsfn`` is a callable that with no argument iterates over all
    revision numbers and with a ``start`` argument iterates over revision
    numbers beginning with that value.

    ``parentrevsfn`` is a callable that receives a revision number and
    returns an iterable of parent revision numbers, whose values may include
    nullrev.
    """
    first = min(revs)

    if first == nullrev:
        for rev in revsfn():
            yield rev
        return

    seen = set(revs)
    for rev in revsfn(start=first + 1):
        for prev in parentrevsfn(rev):
            if prev != nullrev and prev in seen:
                seen.add(rev)
                yield rev
                break


def _reachablerootspure(pfunc, minroot, roots, heads, includepath):
    """See revlog.reachableroots"""
    if not roots:
        return []
    roots = set(roots)
    visit = list(heads)
    reachable = set()
    seen = {}
    # prefetch all the things! (because python is slow)
    reached = reachable.add
    dovisit = visit.append
    nextvisit = visit.pop
    # open-code the post-order traversal due to the tiny size of
    # sys.getrecursionlimit()
    while visit:
        rev = nextvisit()
        if rev in roots:
            reached(rev)
            if not includepath:
                continue
        parents = pfunc(rev)
        seen[rev] = parents
        for parent in parents:
            if parent >= minroot and parent not in seen:
                dovisit(parent)
    if not reachable:
        return reachable
    if not includepath:
        return reachable
    for rev in sorted(seen):
        for parent in seen[rev]:
            if parent in reachable:
                reached(rev)
    return reachable


def toposort(revs, parentsfunc, firstbranch=()):
    """Yield revisions from heads to roots one (topo) branch at a time.

    This function aims to be used by a graph generator that wishes to minimize
    the number of parallel branches and their interleaving.

    Example iteration order (numbers show the "true" order in a changelog):

      o  4
      |
      o  1
      |
      | o  3
      | |
      | o  2
      |/
      o  0

    Note that the ancestors of merges are understood by the current
    algorithm to be on the same branch. This means no reordering will
    occur behind a merge.
    """

    ### Quick summary of the algorithm
    #
    # This function is based around a "retention" principle. We keep revisions
    # in memory until we are ready to emit a whole branch that immediately
    # "merges" into an existing one. This reduces the number of parallel
    # branches with interleaved revisions.
    #
    # During iteration revs are split into two groups:
    # A) revision already emitted
    # B) revision in "retention". They are stored as different subgroups.
    #
    # for each REV, we do the following logic:
    #
    #   1) if REV is a parent of (A), we will emit it. If there is a
    #   retention group ((B) above) that is blocked on REV being
    #   available, we emit all the revisions out of that retention
    #   group first.
    #
    #   2) else, we'll search for a subgroup in (B) awaiting for REV to be
    #   available, if such subgroup exist, we add REV to it and the subgroup is
    #   now awaiting for REV.parents() to be available.
    #
    #   3) finally if no such group existed in (B), we create a new subgroup.
    #
    #
    # To bootstrap the algorithm, we emit the tipmost revision (which
    # puts it in group (A) from above).

    revs.sort(reverse=True)

    # Set of parents of revision that have been emitted. They can be considered
    # unblocked as the graph generator is already aware of them so there is no
    # need to delay the revisions that reference them.
    #
    # If someone wants to prioritize a branch over the others, pre-filling this
    # set will force all other branches to wait until this branch is ready to be
    # emitted.
    unblocked = set(firstbranch)

    # list of groups waiting to be displayed, each group is defined by:
    #
    #   (revs:    lists of revs waiting to be displayed,
    #    blocked: set of that cannot be displayed before those in 'revs')
    #
    # The second value ('blocked') correspond to parents of any revision in the
    # group ('revs') that is not itself contained in the group. The main idea
    # of this algorithm is to delay as much as possible the emission of any
    # revision.  This means waiting for the moment we are about to display
    # these parents to display the revs in a group.
    #
    # This first implementation is smart until it encounters a merge: it will
    # emit revs as soon as any parent is about to be emitted and can grow an
    # arbitrary number of revs in 'blocked'. In practice this mean we properly
    # retains new branches but gives up on any special ordering for ancestors
    # of merges. The implementation can be improved to handle this better.
    #
    # The first subgroup is special. It corresponds to all the revision that
    # were already emitted. The 'revs' lists is expected to be empty and the
    # 'blocked' set contains the parents revisions of already emitted revision.
    #
    # You could pre-seed the <parents> set of groups[0] to a specific
    # changesets to select what the first emitted branch should be.
    groups = [([], unblocked)]
    pendingheap = []
    pendingset = set()

    heapq.heapify(pendingheap)
    heappop = heapq.heappop
    heappush = heapq.heappush
    for currentrev in revs:
        # Heap works with smallest element, we want highest so we invert
        if currentrev not in pendingset:
            heappush(pendingheap, -currentrev)
            pendingset.add(currentrev)
        # iterates on pending rev until after the current rev have been
        # processed.
        rev = None
        while rev != currentrev:
            rev = -heappop(pendingheap)
            pendingset.remove(rev)

            # Seek for a subgroup blocked, waiting for the current revision.
            matching = [i for i, g in enumerate(groups) if rev in g[1]]

            if matching:
                # The main idea is to gather together all sets that are blocked
                # on the same revision.
                #
                # Groups are merged when a common blocking ancestor is
                # observed. For example, given two groups:
                #
                # revs [5, 4] waiting for 1
                # revs [3, 2] waiting for 1
                #
                # These two groups will be merged when we process
                # 1. In theory, we could have merged the groups when
                # we added 2 to the group it is now in (we could have
                # noticed the groups were both blocked on 1 then), but
                # the way it works now makes the algorithm simpler.
                #
                # We also always keep the oldest subgroup first. We can
                # probably improve the behavior by having the longest set
                # first. That way, graph algorithms could minimise the length
                # of parallel lines their drawing. This is currently not done.
                targetidx = matching.pop(0)
                trevs, tparents = groups[targetidx]
                for i in matching:
                    gr = groups[i]
                    trevs.extend(gr[0])
                    tparents |= gr[1]
                # delete all merged subgroups (except the one we kept)
                # (starting from the last subgroup for performance and
                # sanity reasons)
                for i in reversed(matching):
                    del groups[i]
            else:
                # This is a new head. We create a new subgroup for it.
                targetidx = len(groups)
                groups.append(([], {rev}))

            gr = groups[targetidx]

            # We now add the current nodes to this subgroups. This is done
            # after the subgroup merging because all elements from a subgroup
            # that relied on this rev must precede it.
            #
            # we also update the <parents> set to include the parents of the
            # new nodes.
            if rev == currentrev:  # only display stuff in rev
                gr[0].append(rev)
            gr[1].remove(rev)
            parents = [p for p in parentsfunc(rev) if p > nullrev]
            gr[1].update(parents)
            for p in parents:
                if p not in pendingset:
                    pendingset.add(p)
                    heappush(pendingheap, -p)

            # Look for a subgroup to display
            #
            # When unblocked is empty (if clause), we were not waiting for any
            # revisions during the first iteration (if no priority was given) or
            # if we emitted a whole disconnected set of the graph (reached a
            # root).  In that case we arbitrarily take the oldest known
            # subgroup. The heuristic could probably be better.
            #
            # Otherwise (elif clause) if the subgroup is blocked on
            # a revision we just emitted, we can safely emit it as
            # well.
            if not unblocked:
                if len(groups) > 1:  # display other subset
                    targetidx = 1
                    gr = groups[1]
            elif not gr[1] & unblocked:
                gr = None

            if gr is not None:
                # update the set of awaited revisions with the one from the
                # subgroup
                unblocked |= gr[1]
                # output all revisions in the subgroup
                yield from gr[0]
                # delete the subgroup that you just output
                # unless it is groups[0] in which case you just empty it.
                if targetidx:
                    del groups[targetidx]
                else:
                    gr[0][:] = []
    # Check if we have some subgroup waiting for revisions we are not going to
    # iterate over
    for g in groups:
        yield from g[0]


def headrevs(revs, parentsfn):
    """Resolve the set of heads from a set of revisions.

    Receives an iterable of revision numbers and a callbable that receives a
    revision number and returns an iterable of parent revision numbers, possibly
    including nullrev.

    Returns a set of revision numbers that are DAG heads within the passed
    subset.

    ``nullrev`` is never included in the returned set, even if it is provided in
    the input set.
    """
    headrevs = set(revs)
    parents = {nullrev}
    up = parents.update

    for rev in revs:
        up(parentsfn(rev))
    headrevs.difference_update(parents)
    return headrevs


def headrevsdiff(parentsfn, start, stop):
    """Compute how the set of heads changed between
    revisions `start-1` and `stop-1`.
    """
    parents = set()

    heads_added = set()
    heads_removed = set()

    for rev in range(stop - 1, start - 1, -1):
        if rev in parents:
            parents.remove(rev)
        else:
            heads_added.add(rev)
        for p in parentsfn(rev):
            parents.add(p)

    # now `parents` is the collection of candidate removed heads
    rev = start - 1
    while parents:
        if rev in parents:
            heads_removed.add(rev)
            parents.remove(rev)

        for p in parentsfn(rev):
            parents.discard(p)
        rev = rev - 1

    return (heads_removed, heads_added)


def headrevssubset(revsfn, parentrevsfn, startrev=None, stoprevs=None):
    """Returns the set of all revs that have no children with control.

    ``revsfn`` is a callable that with no arguments returns an iterator over
    all revision numbers in topological order. With a ``start`` argument, it
    returns revision numbers starting at that number.

    ``parentrevsfn`` is a callable receiving a revision number and returns an
    iterable of parent revision numbers, where values can include nullrev.

    ``startrev`` is a revision number at which to start the search.

    ``stoprevs`` is an iterable of revision numbers that, when encountered,
    will stop DAG traversal beyond them. Parents of revisions in this
    collection will be heads.
    """
    if startrev is None:
        startrev = nullrev

    stoprevs = set(stoprevs or [])

    reachable = {startrev}
    heads = {startrev}

    for rev in revsfn(start=startrev + 1):
        for prev in parentrevsfn(rev):
            if prev in reachable:
                if rev not in stoprevs:
                    reachable.add(rev)
                heads.add(rev)

            if prev in heads and prev not in stoprevs:
                heads.remove(prev)

    return heads


def linearize(revs, parentsfn):
    """Linearize and topologically sort a list of revisions.

    The linearization process tries to create long runs of revs where a child
    rev comes immediately after its first parent. This is done by visiting the
    heads of the revs in inverse topological order, and for each visited rev,
    visiting its second parent, then its first parent, then adding the rev
    itself to the output list.

    Returns a list of revision numbers.
    """
    visit = list(sorted(headrevs(revs, parentsfn), reverse=True))
    finished = set()
    result = []

    while visit:
        rev = visit.pop()
        if rev < 0:
            rev = -rev - 1

            if rev not in finished:
                result.append(rev)
                finished.add(rev)

        else:
            visit.append(-rev - 1)

            for prev in parentsfn(rev):
                if prev == nullrev or prev not in revs or prev in finished:
                    continue

                visit.append(prev)

    assert len(result) == len(revs)

    return result
