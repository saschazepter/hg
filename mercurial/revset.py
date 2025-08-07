# revset.py - revision set queries for mercurial
#
# Copyright 2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from .i18n import _
from .node import (
    nullrev,
    wdirrev,
)
from . import (
    dagop,
    error,
    registrar,
    revsetlang,
    scmutil,
    smartset,
    tables,
)
from .utils import (
    dag_util,
)


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items.

    See `mercurial.initialization` for details"""


# helpers for processing parsed tree
getsymbol = revsetlang.getsymbol
getstring = revsetlang.getstring
getinteger = revsetlang.getinteger
getboolean = revsetlang.getboolean
getlist = revsetlang.getlist
getintrange = revsetlang.getintrange
getargs = revsetlang.getargs
getargsdict = revsetlang.getargsdict

baseset = smartset.baseset
generatorset = smartset.generatorset
spanset = smartset.spanset
fullreposet = smartset.fullreposet

# revisions not included in all(), but populated if specified
_virtualrevs = (nullrev, wdirrev)

# Constants for ordering requirement, used in getset():
#
# If 'define', any nested functions and operations MAY change the ordering of
# the entries in the set (but if changes the ordering, it MUST ALWAYS change
# it). If 'follow', any nested functions and operations MUST take the ordering
# specified by the first operand to the '&' operator.
#
# For instance,
#
#   X & (Y | Z)
#   ^   ^^^^^^^
#   |   follow
#   define
#
# will be evaluated as 'or(y(x()), z(x()))', where 'x()' can change the order
# of the entries in the set, but 'y()', 'z()' and 'or()' shouldn't.
#
# 'any' means the order doesn't matter. For instance,
#
#   (X & !Y) | ancestors(Z)
#         ^              ^
#         any            any
#
# For 'X & !Y', 'X' decides the order and 'Y' is subtracted from 'X', so the
# order of 'Y' does not matter. For 'ancestors(Z)', Z's order does not matter
# since 'ancestors' does not care about the order of its argument.
#
# Currently, most revsets do not care about the order, so 'define' is
# equivalent to 'follow' for them, and the resulting order is based on the
# 'subset' parameter passed down to them:
#
#   m = revset.match(...)
#   m(repo, subset, order=defineorder)
#           ^^^^^^
#      For most revsets, 'define' means using the order this subset provides
#
# There are a few revsets that always redefine the order if 'define' is
# specified: 'sort(X)', 'reverse(X)', 'x:y'.
anyorder = b'any'  # don't care the order, could be even random-shuffled
defineorder = b'define'  # ALWAYS redefine, or ALWAYS follow the current order
followorder = b'follow'  # MUST follow the current order

symbols = tables.revset_symbol_table
safesymbols = tables.safe_revset_symbols

predicate = registrar.revsetpredicate(
    tables.revset_symbol_table,
    tables.safe_revset_symbols,
)

# helpers


def getset(repo, subset, x, order=defineorder):
    if not x:
        raise error.ParseError(_(b"missing argument"))
    return methods[x[0]](repo, subset, *x[1:], order=order)


# operator methods


def stringset(repo, subset, x, order):
    if not x:
        raise error.ParseError(_(b"empty string is not a valid revision"))
    x = scmutil.intrev(scmutil.revsymbol(repo, x))
    if x in subset or x in _virtualrevs and isinstance(subset, fullreposet):
        return baseset([x])
    return baseset()


def rawsmartset(repo, subset, x, order):
    """argument is already a smartset, use that directly"""
    if order == followorder:
        return subset & x
    else:
        return x & subset


def raw_node_set(repo, subset, x, order):
    """argument is a list of nodeid, resolve and use them"""
    nodes = _ordered_node_set(repo, x)
    if order == followorder:
        return subset & nodes
    else:
        return nodes & subset


def _ordered_node_set(repo, nodes):
    if not nodes:
        return baseset()
    to_rev = repo.changelog.index.rev
    return baseset([to_rev(r) for r in nodes])


def rangeset(repo, subset, x, y, order):
    m = getset(repo, fullreposet(repo), x)
    n = getset(repo, fullreposet(repo), y)

    if not m or not n:
        return baseset()
    return _makerangeset(repo, subset, m.first(), n.last(), order)


def rangeall(repo, subset, x, order):
    assert x is None
    return _makerangeset(repo, subset, 0, repo.changelog.tiprev(), order)


def rangepre(repo, subset, y, order):
    # ':y' can't be rewritten to '0:y' since '0' may be hidden
    n = getset(repo, fullreposet(repo), y)
    if not n:
        return baseset()
    return _makerangeset(repo, subset, 0, n.last(), order)


def rangepost(repo, subset, x, order):
    m = getset(repo, fullreposet(repo), x)
    if not m:
        return baseset()
    return _makerangeset(
        repo, subset, m.first(), repo.changelog.tiprev(), order
    )


def _makerangeset(repo, subset, m, n, order):
    if m == n:
        r = baseset([m])
    elif n == wdirrev:
        r = spanset(repo, m, len(repo)) + baseset([n])
    elif m == wdirrev:
        r = baseset([m]) + spanset(repo, repo.changelog.tiprev(), n - 1)
    elif m < n:
        r = spanset(repo, m, n + 1)
    else:
        r = spanset(repo, m, n - 1)

    if order == defineorder:
        return r & subset
    else:
        # carrying the sorting over when possible would be more efficient
        return subset & r


def dagrange(repo, subset, x, y, order):
    r = fullreposet(repo)
    xs = dag_util.reachableroots(
        repo, getset(repo, r, x), getset(repo, r, y), includepath=True
    )
    return subset & xs


def andset(repo, subset, x, y, order):
    if order == anyorder:
        yorder = anyorder
    else:
        yorder = followorder
    return getset(repo, getset(repo, subset, x, order), y, yorder)


def andsmallyset(repo, subset, x, y, order):
    # 'andsmally(x, y)' is equivalent to 'and(x, y)', but faster when y is small
    if order == anyorder:
        yorder = anyorder
    else:
        yorder = followorder
    return getset(repo, getset(repo, subset, y, yorder), x, order)


def differenceset(repo, subset, x, y, order):
    return getset(repo, subset, x, order) - getset(repo, subset, y, anyorder)


def _orsetlist(repo, subset, xs, order):
    assert xs
    if len(xs) == 1:
        return getset(repo, subset, xs[0], order)
    p = len(xs) // 2
    a = _orsetlist(repo, subset, xs[:p], order)
    b = _orsetlist(repo, subset, xs[p:], order)
    return a + b


def orset(repo, subset, x, order):
    xs = getlist(x)
    if not xs:
        return baseset()
    if order == followorder:
        # slow path to take the subset order
        return subset & _orsetlist(repo, fullreposet(repo), xs, anyorder)
    else:
        return _orsetlist(repo, subset, xs, order)


def notset(repo, subset, x, order):
    return subset - getset(repo, subset, x, anyorder)


def relationset(repo, subset, x, y, order):
    # this is pretty basic implementation of 'x#y' operator, still
    # experimental so undocumented. see the wiki for further ideas.
    # https://www.mercurial-scm.org/wiki/RevsetOperatorPlan
    rel = getsymbol(y)
    if rel in relations:
        return relations[rel](repo, subset, x, rel, order)

    relnames = [r for r in relations.keys() if len(r) > 1]
    raise error.UnknownIdentifier(rel, relnames)


def _splitrange(a, b):
    """Split range with bounds a and b into two ranges at 0 and return two
    tuples of numbers for use as startdepth and stopdepth arguments of
    revancestors and revdescendants.

    >>> _splitrange(-10, -5)     # [-10:-5]
    ((5, 11), (None, None))
    >>> _splitrange(5, 10)       # [5:10]
    ((None, None), (5, 11))
    >>> _splitrange(-10, 10)     # [-10:10]
    ((0, 11), (0, 11))
    >>> _splitrange(-10, 0)      # [-10:0]
    ((0, 11), (None, None))
    >>> _splitrange(0, 10)       # [0:10]
    ((None, None), (0, 11))
    >>> _splitrange(0, 0)        # [0:0]
    ((0, 1), (None, None))
    >>> _splitrange(1, -1)       # [1:-1]
    ((None, None), (None, None))
    """
    ancdepths = (None, None)
    descdepths = (None, None)
    if a == b == 0:
        ancdepths = (0, 1)
    if a < 0:
        ancdepths = (-min(b, 0), -a + 1)
    if b > 0:
        descdepths = (max(a, 0), b + 1)
    return ancdepths, descdepths


def generationsrel(repo, subset, x, rel, order):
    z = (b'rangeall', None)
    return generationssubrel(repo, subset, x, rel, z, order)


def generationssubrel(repo, subset, x, rel, z, order):
    # TODO: rewrite tests, and drop startdepth argument from ancestors() and
    # descendants() predicates
    a, b = getintrange(
        z,
        _(b'relation subscript must be an integer or a range'),
        _(b'relation subscript bounds must be integers'),
        deffirst=-(dagop.maxlogdepth - 1),
        deflast=+(dagop.maxlogdepth - 1),
    )
    (ancstart, ancstop), (descstart, descstop) = _splitrange(a, b)

    if ancstart is None and descstart is None:
        return baseset()

    revs = getset(repo, fullreposet(repo), x)
    if not revs:
        return baseset()

    if ancstart is not None and descstart is not None:
        s = dag_util.revancestors(repo, revs, False, ancstart, ancstop)
        s += dag_util.revdescendants(repo, revs, False, descstart, descstop)
    elif ancstart is not None:
        s = dag_util.revancestors(repo, revs, False, ancstart, ancstop)
    elif descstart is not None:
        s = dag_util.revdescendants(repo, revs, False, descstart, descstop)

    return subset & s


def relsubscriptset(repo, subset, x, y, z, order):
    # this is pretty basic implementation of 'x#y[z]' operator, still
    # experimental so undocumented. see the wiki for further ideas.
    # https://www.mercurial-scm.org/wiki/RevsetOperatorPlan
    rel = getsymbol(y)
    if rel in subscriptrelations:
        return subscriptrelations[rel](repo, subset, x, rel, z, order)

    relnames = [r for r in subscriptrelations.keys() if len(r) > 1]
    raise error.UnknownIdentifier(rel, relnames)


def subscriptset(repo, subset, x, y, order):
    raise error.ParseError(_(b"can't use a subscript in this context"))


def listset(repo, subset, *xs, **opts):
    raise error.ParseError(
        _(b"can't use a list in this context"),
        hint=_(b'see \'hg help "revsets.x or y"\''),
    )


def keyvaluepair(repo, subset, k, v, order):
    raise error.ParseError(_(b"can't use a key-value pair in this context"))


def func(repo, subset, a, b, order):
    f = getsymbol(a)
    if f in symbols:
        func = symbols[f]
        if getattr(func, '_takeorder', False):
            return func(repo, subset, b, order)
        return func(repo, subset, b)

    keep = lambda fn: getattr(fn, '__doc__', None) is not None

    syms = [s for (s, fn) in symbols.items() if keep(fn)]
    raise error.UnknownIdentifier(f, syms)


@predicate(b'p1([set])', safe=True)
def p1(repo, subset, x):
    """First parent of changesets in set, or the working directory."""
    if x is None:
        p = repo[x].p1().rev()
        if p >= 0:
            return subset & baseset([p])
        return baseset()

    ps = set()
    cl = repo.changelog
    for r in getset(repo, fullreposet(repo), x):
        try:
            ps.add(cl.parentrevs(r)[0])
        except error.WdirUnsupported:
            ps.add(repo[r].p1().rev())
    ps -= {nullrev}
    # XXX we should turn this into a baseset instead of a set, smartset may do
    # some optimizations from the fact this is a baseset.
    return subset & ps


@predicate(b'p2([set])', safe=True)
def p2(repo, subset, x):
    """Second parent of changesets in set, or the working directory."""
    if x is None:
        ps = repo[x].parents()
        try:
            p = ps[1].rev()
            if p >= 0:
                return subset & baseset([p])
            return baseset()
        except IndexError:
            return baseset()

    ps = set()
    cl = repo.changelog
    for r in getset(repo, fullreposet(repo), x):
        try:
            ps.add(cl.parentrevs(r)[1])
        except error.WdirUnsupported:
            parents = repo[r].parents()
            if len(parents) == 2:
                ps.add(parents[1])
    ps -= {nullrev}
    # XXX we should turn this into a baseset instead of a set, smartset may do
    # some optimizations from the fact this is a baseset.
    return subset & ps


def parentpost(repo, subset, x, order):
    return p1(repo, subset, x)


def _childrenspec(repo, subset, x, n, order):
    """Changesets that are the Nth child of a changeset
    in set.
    """
    cs = set()
    for r in getset(repo, fullreposet(repo), x):
        for i in range(n):
            c = repo[r].children()
            if len(c) == 0:
                break
            if len(c) > 1:
                raise error.RepoLookupError(
                    _(b"revision in set has more than one child")
                )
            r = c[0].rev()
        else:
            cs.add(r)
    return subset & cs


def parentspec(repo, subset, x, n, order):
    """``set^0``
    The set.
    ``set^1`` (or ``set^``), ``set^2``
    First or second parent, respectively, of all changesets in set.
    """
    try:
        n = int(n[1])
        if n not in (0, 1, 2):
            raise ValueError
    except (TypeError, ValueError):
        raise error.ParseError(_(b"^ expects a number 0, 1, or 2"))
    ps = set()
    cl = repo.changelog
    for r in getset(repo, fullreposet(repo), x):
        if n == 0:
            ps.add(r)
        elif n == 1:
            try:
                ps.add(cl.parentrevs(r)[0])
            except error.WdirUnsupported:
                ps.add(repo[r].p1().rev())
        else:
            try:
                parents = cl.parentrevs(r)
                if parents[1] != nullrev:
                    ps.add(parents[1])
            except error.WdirUnsupported:
                parents = repo[r].parents()
                if len(parents) == 2:
                    ps.add(parents[1].rev())
    return subset & ps


def ancestorspec(repo, subset, x, n, order):
    """``set~n``
    Changesets that are the Nth ancestor (first parents only) of a changeset
    in set.
    """
    n = getinteger(n, _(b"~ expects a number"))
    if n < 0:
        # children lookup
        return _childrenspec(repo, subset, x, -n, order)
    ps = set()
    cl = repo.changelog
    for r in getset(repo, fullreposet(repo), x):
        for i in range(n):
            try:
                r = cl.parentrevs(r)[0]
            except error.WdirUnsupported:
                r = repo[r].p1().rev()
        ps.add(r)
    return subset & ps


methods = {
    b"range": rangeset,
    b"rangeall": rangeall,
    b"rangepre": rangepre,
    b"rangepost": rangepost,
    b"dagrange": dagrange,
    b"string": stringset,
    b"symbol": stringset,
    b"and": andset,
    b"andsmally": andsmallyset,
    b"or": orset,
    b"not": notset,
    b"difference": differenceset,
    b"relation": relationset,
    b"relsubscript": relsubscriptset,
    b"subscript": subscriptset,
    b"list": listset,
    b"keyvalue": keyvaluepair,
    b"func": func,
    b"ancestor": ancestorspec,
    b"parent": parentspec,
    b"parentpost": parentpost,
    b"smartset": rawsmartset,
    b"nodeset": raw_node_set,
}

relations = {
    b"g": generationsrel,
    b"generations": generationsrel,
}

subscriptrelations = {
    b"g": generationssubrel,
    b"generations": generationssubrel,
}


def lookupfn(repo):
    def fn(symbol):
        try:
            return scmutil.isrevsymbol(repo, symbol)
        except error.AmbiguousPrefixLookupError:
            raise error.InputError(
                b'ambiguous revision identifier: %s' % symbol
            )

    return fn


def match(ui, spec, lookup=None):
    """Create a matcher for a single revision spec"""
    return matchany(ui, [spec], lookup=lookup)


def matchany(ui, specs, lookup=None, localalias=None):
    """Create a matcher that will include any revisions matching one of the
    given specs

    If lookup function is not None, the parser will first attempt to handle
    old-style ranges, which may contain operator characters.

    If localalias is not None, it is a dict {name: definitionstring}. It takes
    precedence over [revsetalias] config section.
    """
    if not specs:

        def mfunc(repo, subset=None):
            return baseset()

        return mfunc
    if not all(specs):
        raise error.ParseError(_(b"empty query"))
    if len(specs) == 1:
        tree = revsetlang.parse(specs[0], lookup)
    else:
        tree = (
            b'or',
            (b'list',) + tuple(revsetlang.parse(s, lookup) for s in specs),
        )

    aliases = []
    warn = None
    if ui:
        aliases.extend(ui.configitems(b'revsetalias'))
        warn = ui.warn
    if localalias:
        aliases.extend(localalias.items())
    if aliases:
        tree = revsetlang.expandaliases(tree, aliases, warn=warn)
    tree = revsetlang.foldconcat(tree)
    tree = revsetlang.analyze(tree)
    tree = revsetlang.optimize(tree)
    return makematcher(tree)


def makematcher(tree):
    """Create a matcher from an evaluatable tree"""

    def mfunc(repo, subset=None, order=None):
        if order is None:
            if subset is None:
                order = defineorder  # 'x'
            else:
                order = followorder  # 'subset & x'
        if subset is None:
            subset = fullreposet(repo)
        return getset(repo, subset, tree, order)

    return mfunc


# tell hggettext to extract docstrings from these functions:
i18nfunctions = symbols.values()
