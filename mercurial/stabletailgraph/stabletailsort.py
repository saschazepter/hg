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
"""

import itertools
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
    tail part, hopefully reducing the overall complexity of the stable sort.

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


def _stable_tail_sort(cl, head_rev):
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

        p1, p2 = _nonoedipal_parent_revs(cl, cursor_rev)
        if p1 == nullrev:
            cursor_rev = p2
        elif p2 == nullrev:
            cursor_rev = p1
        else:
            px, pt = _sorted_parents(cl, p1, p2)

            tail_ancestors = ancestor.lazyancestors(
                cl.parentrevs, (pt,), inclusive=True
            )
            exclusive_ancestors = (
                a for a in _stable_tail_sort(cl, px) if a not in tail_ancestors
            )

            excl_part_size = cl.fast_rank(cursor_rev) - cl.fast_rank(pt) - 1
            yield from itertools.islice(exclusive_ancestors, excl_part_size)
            cursor_rev = pt
