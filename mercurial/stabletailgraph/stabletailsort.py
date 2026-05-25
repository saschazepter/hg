# stabletailsort.py - stable ordering of revisions
#
# Copyright 2021-2023 Pacien TRAN-GIRARD <pacien.trangirard@pacien.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

"""
Stable-tail sort computation.

The "stable-tail sort", or STS, is a reverse topological ordering of the
ancestors of a node, which tends to share large suffixes with the stable-tail
sort of ancestors and other nodes, giving it its name.

Its properties should make it suitable for making chunks of ancestors with high
reuse and incrementality for example.

This module and implementation are experimental. Most functions are not yet
optimised to operate on large production graphs.

General Definition
==================

For readability, we will refer to stable-tail-sort through the STS acronym.

For clarity, the definition of the STS of a revision can be split into three
cases depending of its parents.

For a root revision, with no parents::

    sts(rev) == [rev]

For a linear revision, with a single parent::

    sts(rev) == [rev] + STS(parent)

For a merge, with two parents, we pick a "tail" parent and an "exclusive"
parent. The STS is then defined as::

    sts(REV) == [REV] + [sts(p_exclusive) - ancestors(p_tail)] sts(p_tail)


Definitions
===========

Revision Rank:
    The size of the subgraph defined by a revision. Or in other terms, the
    number of ancestors a revision has, itself included.

Exclusive Parent:
    The parent of a revision we iterate over first (after that revision) in the
    stable sort order. While some of its stable sort will be reused, most of it
    is typically not reused.

Exclusive Part:
    The part of a revision ancestry that isn't part of the "Tail Parent"
    ancestry (tail parent included). In the stable sort, all revisions in the
    exclusive part are iterated over before the "Tail parent".

    For linear revisions (and Oedipus merges), the exclusive part is empty and
    can be ignored.

Tail Parent:
    The parent of a revision we iterate over after the revision itself and its
    exclusive part. From that point, the STS of the initial revision and the
    STS of the "Tail Parent" will be identical.

Tail Part:
    The part of the revision ancestry that is also part of the "Tail Parent"
    ancestor.
"""

from __future__ import annotations

import itertools

from typing import Container, Iterator

from ..interfaces.types import (
    RevnumT,
)
from ..node import nullrev
from .. import ancestor


def _sorted_parents(cl, p1, p2):
    """
    Chooses and returns the pair (px, pt) from (p1, p2).

    Where
    "px" denotes the parent starting the "exclusive" part, and
    "pt" denotes the parent starting the "Tail" part.

    "px" is chosen as the parent with the lowest rank with the goal of
    minimising the size of the exclusive part and maximise the size of the
    tail part, hopefully reducing the overall complexity of the stable-tail
    sort.

    In case of equal ranks, the stable node ID is used as a tie-breaker.
    """
    r1, r2 = cl.fast_rank(p1), cl.fast_rank(p2)
    if r1 < r2:
        return (p1, p2)
    elif r1 > r2:
        return (p2, p1)
    elif cl.node(p1) < cl.node(p2):
        return (p1, p2)
    else:
        return (p2, p1)


def _nonoedipal_parent_revs(cl, rev):
    """
    Returns the non-œdipal parent pair of the given revision.

    An œdipal merge is a merge with parents p1, p2 with either
    p1 in ancestors(p2) or p2 in ancestors(p1).
    In the first case, p1 is the œdipal parent.
    In the second case, p2 is the œdipal parent.

    Œdipal edges start empty exclusive parts. They do not bring new ancestors.
    As such, they can be skipped when computing any topological sort or any
    iteration over the ancestors of a node.

    The œdipal edges are eliminated here using the rank information.
    """
    p1, p2 = cl.parentrevs(rev)
    if p1 == nullrev or cl.fast_rank(p2) == cl.fast_rank(rev) - 1:
        return p2, nullrev
    elif p2 == nullrev or cl.fast_rank(p1) == cl.fast_rank(rev) - 1:
        return p1, nullrev
    else:
        return p1, p2


def _parents(cl, rev):
    p1, p2 = _nonoedipal_parent_revs(cl, rev)
    if p2 == nullrev:
        return p1, p2

    return _sorted_parents(cl, p1, p2)


def stable_tail_sort(cl, head_rev):
    """
    Naive topological iterator of the ancestors given by the stable-tail sort.

    The stable-tail sort of a node "h" is defined as the sequence:
    sts(h) := [h] + excl(h) + sts(pt(h))
    where excl(h) := u for u in sts(px(h)) if u not in ancestors(pt(h))

    This implementation uses a call-stack whose size is
    O(number of open merges).

    As such, this implementation exists mainly as a defining reference.
    """
    cursor_rev = head_rev
    while cursor_rev != nullrev:
        yield cursor_rev

        px, pt = _parents(cl, cursor_rev)
        if pt == nullrev:
            cursor_rev = px
        else:
            tail_ancestors = ancestor.lazyancestors(
                cl.parentrevs, (pt,), inclusive=True
            )
            exclusive_ancestors = (
                a for a in stable_tail_sort(cl, px) if a not in tail_ancestors
            )

            # Notice that excl(cur) is disjoint from ancestors(pt),
            # so there is no double-counting:
            # rank(cur) = len([cur]) + len(excl(cur)) + rank(pt)
            excl_part_size = cl.fast_rank(cursor_rev) - cl.fast_rank(pt) - 1
            yield from itertools.islice(exclusive_ancestors, excl_part_size)
            cursor_rev = pt


def _exclusive_part_iter(
    revlog,
    exclusive_head: RevnumT,
    tail: Container[RevnumT],
) -> Iterator[RevnumT]:
    """yield the stable-tail-sort of exclusive_head, excluding tail

    This is equivalent to the following generator::

        (
            rev
            for rev in stable_tail_sort(exclusive_head)
            if rev not in tail
        )

    However it the version used in this function detect when all future elements
    of ``stable_tail_sort(exclusive_head)`` will be part of tail to exit early.

    This avoid iterating over all ancestors of ``exclusive_heads`` bringing the
    overall computational complexity closer to ``O(|::exclusive_heads -
    tail|)`` instead of ``O(|::exclusive_heads)``.

    IMPORTANT: if you start doing smart optimization to this function, keep a
    "_naive" copy to beused into `stable_tail_sort_naive`.
    """
    # Keep track of parents we have iterated over that are not in "tail" and that
    # we have not iterated over yet.
    #
    # As long at his set is not empty, we know that there remain ancestors of
    # "exclusive_head", that we need to iterate over.
    #
    # If this set is empty when our current iteration step inside "tail", we
    # know all future ancestors will also be part of tail and can exit early.
    dangling_parents = set()
    for current in stable_tail_sort(revlog, exclusive_head):
        dangling_parents.discard(current)
        parent_excl, parent_tail = _parents(revlog, current)
        if current in tail:
            # NOTE: if current is in the (excluded) tail and was the
            # parent_excl of something we could skip ahead faster, but we leave
            # this for a later optimization.  (Possibly only in Rust)
            if not dangling_parents:
                # if we don't have anything else to find, we exausted the
                # exclusive part.
                break
        else:
            yield current
            # NOTE: We should be able to only append parent_tail if the
            # parent_excl is non-null. However there are currently some bug in
            # the _parents function that prevent that. a fix for it is comming
            # soon.
            if parent_excl != nullrev and parent_excl not in tail:
                dangling_parents.add(parent_excl)
            if parent_tail != nullrev and parent_tail not in tail:
                dangling_parents.add(parent_tail)


def stable_tail_sort_naive(cl, head_rev):
    """
    Naive topological iterator of the ancestors given by the stable-tail sort.

    The stable-tail sort of a node "h" is defined as the sequence:
    sts(h) := [h] + excl(h) + sts(pt(h))
    where excl(h) := u for u in sts(px(h)) if u not in ancestors(pt(h))

    This implementation uses a call-stack whose size is
    O(number of open merges).

    As such, this implementation exists mainly as a defining reference.
    """
    cursor_rev = head_rev
    while cursor_rev != nullrev:
        yield cursor_rev

        parent_excl, parent_tail = _parents(cl, cursor_rev)
        if parent_excl == nullrev:
            cursor_rev = parent_tail
        else:
            tail_ancestors = ancestor.lazyancestors(
                cl.parentrevs,
                [parent_tail],
                inclusive=True,
            )
            yield from _exclusive_part_iter(cl, parent_excl, tail_ancestors)
            cursor_rev = parent_tail


def _find_all_leaps_naive(cl, head_rev):
    """
    Yields the leaps in the stable-tail sort of the given revision.

    A leap is a pair of revisions (source, target) consecutive in the
    stable-tail sort of a head, for which target != px(source).

    Leaps are yielded in the same order as encountered in the stable-tail sort,
    from head to root.
    """
    sts = stable_tail_sort(cl, head_rev)
    prev = next(sts)
    for current in sts:
        if current != _parents(cl, prev)[0]:
            yield (prev, current)

        prev = current


def _find_specific_leaps_naive(cl, head_rev):
    """
    Returns the specific leaps in the stable-tail sort of the given revision.

    Specific leaps are leaps appear in the stable-tail sort of a given
    revision, but not in the stable-tail sort of any of its ancestors.

    The final leaps (leading to the pt of the considered merge) are omitted.

    Only merge nodes can have associated specific leaps.

    This implementations uses the whole leap sets of the given revision and
    of its parents.
    """
    px, pt = _parents(cl, head_rev)
    if px == nullrev or pt == nullrev:
        return  # linear nodes cannot have specific leaps

    parents_leaps = set(_find_all_leaps_naive(cl, px))

    sts = stable_tail_sort_naive(cl, head_rev)
    prev = next(sts)
    for current in sts:
        if current == pt:
            break
        if current != _parents(cl, prev)[0]:
            leap = (prev, current)
            if leap not in parents_leaps:
                yield leap

        prev = current
