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
    exclusive part. From that point, the STS of the initial revision and the STS
    of the "Tail Parent" will be identical.

Tail Part:
    The part of the revision ancestry that is also part of the "Tail Parent"
    ancestor.

Stable Tail Range:
    A (head, size) pair that encodes a group of revisions. "head" is a revision,
    while "size" in a positive, non-null integer. Together they encode the set
    of revisions as:

        The "size" first elements of "sts(head)".

    The ordering of revisions in that group is the same as `sts(heads)`.

    In Python terms this would be::

        Range(head, size) == stable_tail_sort(head)[:size]

Exclusive Splits:
    A way of encoding the exclusive part of a revision as a series of "Stable
    Tail Range". It offers a compact way of expressing the discontinuity of the
    order of revisions from the exclusive part created by the exclusion of
    ancestors common with the "Tail".

Revision's Power:
    Each revision has a "Power" based on its rank and the rank of its parent's
    tail.

    The maximum power value a revision can have is log_2(rank). And the
    distribution of the power value follows a logarithmic rule.

Canonical ancestor:
    The canonical ancestor of `rev` is the first revision traveling the graph
    from "Tail Parent" to "Tail Parent" of `rev` that as a power higher than
    `rev`.

    Given the property of a revision's power, this means a revision of rank
    `rank` has a chain of canonical ancestors of maximum length "log_2(`rank`)".

    In addition, nodes with higher power are more likely to be chosen as
    canonical ancestors and have a larger canonical part.

Canonical Part:
    The prefix of a revision's stable tail sort before the canonical ancestor.

    It can expressed by ``Range(rev, canonical_length)``. Where
    ``canonical_length = rev.rank() - canonical_ancestor.rank``

Minimum Canonical Rank
    Given a revision `rev`, this is the lowest rank of all revisions in the
    Canonical Part of `rev`.
"""

from __future__ import annotations

import itertools

from typing import Container, Iterator

from ..interfaces.types import (
    RevnumT,
)
from ..node import hex, nullrev
from .. import ancestor


def _sorted_parents(idx, p1, p2):
    """
    Chooses and returns the pair (pt, px) from (p1, p2).

    Where
    "px" denotes the parent starting the "exclusive" part, and
    "pt" denotes the parent starting the "Tail" part.

    "px" is chosen as the parent with the lowest rank with the goal of
    minimizing the size of the exclusive part and maximize the size of the
    tail part, hopefully reducing the overall complexity of the stable-tail
    sort.

    In case of equal ranks, the stable node ID is used as a tie-breaker.
    """
    r1, r2 = idx.rank(p1), idx.rank(p2)
    if r1 > r2:
        return (p1, p2)
    elif r1 < r2:
        return (p2, p1)
    elif idx.node(p1) < idx.node(p2):
        return (p2, p1)
    else:
        return (p1, p2)


def _nonoedipal_parent_revs(idx, rev):
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
    assert hasattr(idx, "rank"), "This function take an index, not a revlog"
    p1, p2 = idx.parents(rev)
    next_rank = idx.rank(rev) - 1
    if p1 == nullrev or idx.rank(p2) == next_rank:
        return p2, nullrev
    elif p2 == nullrev or idx.rank(p1) == next_rank:
        return p1, nullrev
    else:
        return p1, p2


def _parents(idx, rev: RevnumT) -> tuple[RevnumT, RevnumT]:
    """returns the pair (pt, px) from (p1, p2)."""
    p1, p2 = _nonoedipal_parent_revs(idx, rev)
    if p2 == nullrev:
        return p1, p2

    return _sorted_parents(idx, p1, p2)


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

        pt, px = _parents(cl.index, cursor_rev)
        if px != nullrev:
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


def computed_excl_splits(revlog, rev: RevnumT) -> list[tuple[RevnumT, int]]:
    """compute the exclusive split of a revision on the fly

    This can be slow and is intended for debug and validation only.
    """
    pt, px = _parents(revlog.index, rev)
    if px == nullrev:
        return []
    else:
        return list(_compute_excl_splits(revlog, px, pt))


def _compute_excl_splits(
    revlog,
    exclusive_head: RevnumT,
    tail_head: RevnumT,
) -> Iterator[tuple[RevnumT, int]]:
    """yield the exclusive splits from exclusive and tail parents"""
    tail = revlog.ancestors([tail_head], inclusive=True)
    revs = _exclusive_part_iter(revlog, exclusive_head, tail)
    yield from _group_by_range(revlog, revs)


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
        parent_tail, parent_excl = _parents(revlog.index, current)
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
            # NOTE: At first, one may assumes that we can not do this logic
            # only for the "tail" parent of merge, as we have no guarantee that
            # the STS of the exclusive head will iterate of a parent of
            # `current` next.
            #
            # Indeed the next iteration could jump somewhere else in the
            # ancestry of exclusive heads. So one parent not might be
            # iterated over next. (in addition of the tail-parent a merge that will not
            # be iterated over next for sure). We call this parent
            # "next-parent" for the rest of this explanation.
            #
            # However the only reason for such jump to happens is for another
            # child of "next-parent" to exist later in the STS. And this gives us two cases :
            #
            # - If that child it part of `tail`, then that next-parent is also
            #   part of `tail` and we can ignore next-parent.
            # - If next-parent is not part of `tail`, then none of its children
            #   are. Such child will be iterated over later, and `next-parent`
            #   will be processed.
            if parent_excl != nullrev:
                assert parent_tail != nullrev
                if parent_tail not in tail:
                    dangling_parents.add(parent_tail)


def _group_by_range(
    revlog,
    revs: Iterator[RevnumT],
) -> Iterator[tuple[RevnumT, int]]:
    """turn an iteration of revision into equivalent Stable Tail Range

    This is typically used to compute the "exclusive splits" for a merge.
    """
    # The first revision, will be the head of our first Range
    current_head = next(revs, None)
    if current_head is None:
        return
    # We will synchroniously iterate other that revision own stable_tail_sort
    # to detect any divergence from the main iteration.
    current_iter = stable_tail_sort(revlog, current_head)
    current_length = 1  # that range contains one revision already
    next(current_iter)
    for current in revs:
        # If the revision from the iterator we are "grouping" diverged from the
        # stable-tail-sort of the current "head" revision, the range we are
        # currently using is no longer suitable to express that iteration.
        #
        # So we can emit the Range we had so far and we must create a new Range
        # using that first diverging revision as its head.
        if current != next(current_iter, None):
            assert current_head > nullrev
            assert current_length > 0
            yield (current_head, current_length)
            # creating the new range, and tracking the STS of its new head for
            # divergence.
            current_head = current
            current_iter = stable_tail_sort(revlog, current)
            current_length = 0
            next(current_iter)
        current_length += 1
    # the iteration is over, if we have any "in progress" Range, they need to
    # be emitted.
    if current_head is not None:
        assert current_head > nullrev
        assert current_length > 0
        yield (current_head, current_length)


def _find_canon_ancestor(index, rank, parent_tail):
    """Compute the canonical ancestor

    The canonical ancestor is the first revision from the chain of tail's
    parent canonical ancestor that has higher power than rev.

    Given the property of revision power, this means a revision of rank "rank"
    have a the chain of canonical ancestors of maximum length "log_2(rank)"
    """
    assert rank > 0
    if parent_tail == nullrev:
        return nullrev
    tail_rank = index.rank(parent_tail)
    assert tail_rank > 0
    assert rank > tail_rank, (rank, tail_rank)
    pow_rev = _power2(rank, tail_rank)
    candidate = parent_tail
    while candidate != nullrev and _power2_rev(index, candidate) < pow_rev:
        candidate = _parents(index, candidate)[0]
    return candidate


def _power2_rev(index, rev: RevnumT) -> int:
    """The power of two associated with a revision.

    It is computed a the index of the highest bit that different from the
    revision rank and the parent_tail rank. The maximum power value a revision
    can have is log_2(rank). And the distribution of the power value follow a
    logarithmic rule.

    Nodes with higher power are more likely to be chosen as canonical
    ancestors and have a larger canonical part.
    """
    if rev == nullrev:
        return -1
    rank = index.rank(rev)
    parent_tail = _parents(index, rev)[1]
    tail_rank = index.rank(parent_tail)
    return _power2(rank, tail_rank)


def _power2(high, low):
    """the highest different bit betwent high and low value
    >>> _power2(4, 3)
    2
    >>> _power2(4, 2)
    2
    >>> _power2(10, 5)
    3
    >>> _power2(10, 8)
    1
    >>> _power2(10, 2)
    3
    >>> _power2(100, 99)
    2
    >>> _power2(100, 80)
    5
    >>> _power2(100, 40)
    6
    >>> _power2(1000, 999)
    3
    >>> _power2(1000, 900)
    6
    >>> _power2(1000, 800)
    7
    >>> _power2(1000, 400)
    9
    >>> _power2(1050, 1049)
    1
    >>> _power2(1050, 1000)
    10
    >>> _power2(1050, 800)
    10
    >>> _power2(1050, 400)
    10
    """
    assert (high > low) and (low >= 0), (high, low)
    return int.bit_length(high ^ low) - 1


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

        parent_tail, parent_excl = _parents(cl.index, cursor_rev)
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


def _format_node(index, rev: RevnumT) -> bytes:
    return hex(index.node(rev))


def _format_rev(index, rev: RevnumT) -> bytes:
    return b"%d" % rev


def debug_info(ui, revlog, rev: RevnumT, display_revs: bool = False):
    """display various stable-tail information for a given revision

    (We could make this templatable for flexibility, but having it exist at all
    is the first priority at the time of writing)
    """
    index = revlog.index

    if display_revs:
        display = _format_rev
    else:
        display = _format_node

    parent_tail, parent_excl = _parents(index, rev)
    p1, p2 = index.parents(rev)

    rank = index.rank(rev)
    canon_anc = _find_canon_ancestor(index, rank, parent_tail)
    canon_rank = index.rank(canon_anc)
    canon_size = rank - canon_rank
    rev_sts = stable_tail_sort_naive(revlog, rev)
    canon_part = itertools.islice(rev_sts, canon_size)
    min_rank = min(index.rank(r) for r in canon_part)

    ui.writenoi18n(b"%s\n" % display(index, rev))
    ui.writenoi18n(b"- rank: %d\n" % rank)
    ui.writenoi18n(b"- pow2: %d\n" % _power2_rev(index, rev))
    if parent_excl != nullrev:
        ui.writenoi18n(b"- exclusive-part:\n")
        ui.writenoi18n(b"  - parent: %s\n" % display(index, parent_excl))
        ui.writenoi18n(b"    - rank: %d\n" % index.rank(parent_excl))
        ui.writenoi18n(b"    - pow2: %d\n" % _power2_rev(index, parent_excl))
        if parent_excl == p1:
            ui.writenoi18n(b"    - pidx: p1\n")
        if parent_excl == p2:
            ui.writenoi18n(b"    - pidx: p2\n")
        excl_size = index.rank(rev) - index.rank(parent_tail) - 1
        ui.writenoi18n(b"  - size: %d\n" % excl_size)
        ui.writenoi18n(b"  - splits:\n")
        for head, length in computed_excl_splits(revlog, rev):
            ui.writenoi18n(b"    - head:   %s\n" % display(index, head))
            ui.writenoi18n(b"      length: %d\n" % length)
    if parent_tail != nullrev:
        ui.writenoi18n(b"- tail-part:\n")
        ui.writenoi18n(b"  - parent: %s\n" % display(index, parent_tail))
        ui.writenoi18n(b"    - rank: %d\n" % index.rank(parent_tail))
        ui.writenoi18n(b"    - pow2: %d\n" % _power2_rev(index, parent_tail))
        if parent_tail == p1:
            ui.writenoi18n(b"    - pidx: p1\n")
        if parent_tail == p2:
            ui.writenoi18n(b"    - pidx: p2\n")
    ui.writenoi18n(b"- canonical-part:\n")
    ui.writenoi18n(b"  - ancestor: %s\n" % display(index, canon_anc))
    if canon_anc != nullrev:
        ui.writenoi18n(b"    - rank:   %d\n" % canon_rank)
        ui.writenoi18n(b"    - pow2:   %d\n" % _power2_rev(index, canon_anc))
    ui.writenoi18n(b"  - size:     %d\n" % canon_size)
    ui.writenoi18n(b"  - min-rank: %d\n" % min_rank)
