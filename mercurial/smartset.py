# smartset.py - data structure for revision set
#
# Copyright 2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations
import typing

from . import (
    encoding,
    error,
    pycompat,
    util,
)
from .utils import stringutil

if typing.TYPE_CHECKING:
    from typing import Callable, Iterable, Iterator
    from .interfaces.types import RepoT, RevnumT


def _typename(o):
    return pycompat.sysbytes(type(o).__name__).lstrip(b'_')


class abstractsmartset:
    def __nonzero__(self) -> bool:
        """True if the smartset is not empty"""
        raise NotImplementedError()

    __bool__ = __nonzero__

    def __contains__(self, rev: RevnumT) -> bool:
        """provide fast membership testing"""
        raise NotImplementedError()

    def __iter__(self) -> Iterator[RevnumT]:
        """iterate the set in the order it is supposed to be iterated"""
        raise NotImplementedError()

    # Attributes containing a function to perform a fast iteration in a given
    # direction. A smartset can have none, one, or both defined.
    #
    # Default value is None instead of a function returning None to avoid
    # initializing an iterator just for testing if a fast method exists.
    fastasc: Callable[[], Iterator[RevnumT]] | None = None
    fastdesc: Callable[[], Iterator[RevnumT]] | None = None

    def isascending(self) -> bool:
        """True if the set will iterate in ascending order"""
        raise NotImplementedError()

    def isdescending(self) -> bool:
        """True if the set will iterate in descending order"""
        raise NotImplementedError()

    def istopo(self) -> bool:
        """True if the set will iterate in topographical order"""
        raise NotImplementedError()

    def min(self) -> RevnumT | None:
        """return the minimum element in the set"""
        if self.fastasc is None:
            v = min(self)
        else:
            for v in self.fastasc():
                break
            else:
                raise ValueError(b'arg is an empty sequence')
        self.min = lambda: v
        return v

    def max(self) -> RevnumT | None:
        """return the maximum element in the set"""
        if self.fastdesc is None:
            return max(self)
        else:
            for v in self.fastdesc():
                break
            else:
                raise ValueError(b'arg is an empty sequence')
        self.max = lambda: v
        return v

    def first(self) -> RevnumT | None:
        """return the first element in the set (user iteration perspective)

        Return None if the set is empty"""
        raise NotImplementedError()

    def last(self) -> RevnumT | None:
        """return the last element in the set (user iteration perspective)

        Return None if the set is empty"""
        raise NotImplementedError()

    def __len__(self) -> int:
        """return the length of the smartsets

        This can be expensive on smartset that could be lazy otherwise."""
        raise NotImplementedError()

    def reverse(self):
        """reverse the expected iteration order"""
        raise NotImplementedError()

    def sort(self, reverse: bool = False):
        """get the set to iterate in an ascending or descending order"""
        raise NotImplementedError()

    def __and__(self, other: abstractsmartset) -> abstractsmartset:
        """Returns a new object with the intersection of the two collections.

        This is part of the mandatory API for smartset."""
        if isinstance(other, fullreposet):
            return self
        return self.filter(other.__contains__, condrepr=other, cache=False)

    def __add__(self, other: abstractsmartset) -> abstractsmartset:
        """Returns a new object with the union of the two collections.

        This is part of the mandatory API for smartset."""
        return addset(self, other)

    def __sub__(self, other: abstractsmartset) -> abstractsmartset:
        """Returns a new object with the substraction of the two collections.

        This is part of the mandatory API for smartset."""
        c = other.__contains__
        return self.filter(
            lambda r: not c(r), condrepr=(b'<not %r>', other), cache=False
        )

    def filter(
        self,
        condition: Callable[[RevnumT], bool],
        condrepr=None,
        cache: bool = True,
    ) -> abstractsmartset:
        """Returns this smartset filtered by condition as a new smartset.

        `condition` is a callable which takes a revision number and returns a
        boolean. Optional `condrepr` provides a printable representation of
        the given `condition`.

        This is part of the mandatory API for smartset."""
        # builtin cannot be cached. but do not needs to
        if cache and hasattr(condition, '__code__'):
            condition = util.cachefunc(condition)
        return filteredset(self, condition, condrepr)

    def slice(self, start: int, stop: int) -> abstractsmartset:
        """Return a new smartset that contains a subset of this set.

        This is like list[start:stop] semantics, except that start and stop
        cannot be negative.
        """
        if start < 0 or stop < 0:
            raise error.ProgrammingError(b'negative index not allowed')
        return self._slice(start, stop)

    def _slice(self, start: int, stop: int) -> abstractsmartset:
        # sub classes may override this. start and stop must not be negative,
        # but start > stop is allowed, which should be an empty set.
        ys = []
        it = iter(self)
        for x in range(start):
            y = next(it, None)
            if y is None:
                break
        for x in range(stop - start):
            y = next(it, None)
            if y is None:
                break
            ys.append(y)
        return baseset(ys, datarepr=(b'slice=%d:%d %r', start, stop, self))


class baseset(abstractsmartset):
    """Basic data structure that represents a revset and contains the basic
    operation that it should be able to perform.

    Every method in this class should be implemented by any smartset class.

    This class could be constructed by an (unordered) set, or an (ordered)
    list-like object. If a set is provided, it'll be sorted lazily.

    >>> x = [4, 0, 7, 6]
    >>> y = [5, 6, 7, 3]

    Construct by a set:
    >>> xs = baseset(set(x))
    >>> ys = baseset(set(y))
    >>> [list(i) for i in [xs + ys, xs & ys, xs - ys]]
    [[0, 4, 6, 7, 3, 5], [6, 7], [0, 4]]
    >>> [type(i).__name__ for i in [xs + ys, xs & ys, xs - ys]]
    ['addset', 'baseset', 'baseset']

    Construct by a list-like:
    >>> xs = baseset(x)
    >>> ys = baseset(i for i in y)
    >>> [list(i) for i in [xs + ys, xs & ys, xs - ys]]
    [[4, 0, 7, 6, 5, 3], [7, 6], [4, 0]]
    >>> [type(i).__name__ for i in [xs + ys, xs & ys, xs - ys]]
    ['addset', 'filteredset', 'filteredset']

    Populate "_set" fields in the lists so set optimization may be used:
    >>> [1 in xs, 3 in ys]
    [False, True]

    Without sort(), results won't be changed:
    >>> [list(i) for i in [xs + ys, xs & ys, xs - ys]]
    [[4, 0, 7, 6, 5, 3], [7, 6], [4, 0]]
    >>> [type(i).__name__ for i in [xs + ys, xs & ys, xs - ys]]
    ['addset', 'filteredset', 'filteredset']

    With sort(), set optimization could be used:
    >>> xs.sort(reverse=True)
    >>> [list(i) for i in [xs + ys, xs & ys, xs - ys]]
    [[7, 6, 4, 0, 5, 3], [7, 6], [4, 0]]
    >>> [type(i).__name__ for i in [xs + ys, xs & ys, xs - ys]]
    ['addset', 'baseset', 'baseset']

    >>> ys.sort()
    >>> [list(i) for i in [xs + ys, xs & ys, xs - ys]]
    [[7, 6, 4, 0, 3, 5], [7, 6], [4, 0]]
    >>> [type(i).__name__ for i in [xs + ys, xs & ys, xs - ys]]
    ['addset', 'baseset', 'baseset']

    istopo is preserved across set operations
    >>> xs = baseset(set(x), istopo=True)
    >>> rs = xs & ys
    >>> type(rs).__name__
    'baseset'
    >>> rs._istopo
    True

    Slicing:
    >>> xs = baseset([3, 1, 9])
    >>> list(xs.slice(0, 0))
    []
    >>> list(xs.slice(0, 3))
    [3, 1, 9]
    >>> list(xs.slice(0, 1))
    [3]
    >>> list(xs.slice(1, 3))
    [1, 9]
    >>> list(xs.slice(1, 0))
    []
    >>> list(xs.slice(2, 5))
    [9]
    """

    def __init__(
        self, data: Iterable[RevnumT] = (), datarepr=None, istopo: bool = False
    ):
        """
        datarepr: a tuple of (format, obj, ...), a function or an object that
                  provides a printable representation of the given data.
        """
        self._ascending = None
        self._istopo = istopo
        if isinstance(data, set):
            # converting set to list has a cost, do it lazily
            self._set = data
            # set has no order we pick one for stability purpose
            self._ascending = True
        else:
            if not isinstance(data, list):
                data = list(data)
            self._list = data
        self._datarepr = datarepr

    @util.propertycache
    def _set(self) -> set[RevnumT]:
        return set(self._list)

    @util.propertycache
    def _asclist(self) -> list[RevnumT]:
        asclist = self._list[:]
        asclist.sort()
        return asclist

    @util.propertycache
    def _list(self) -> list[RevnumT]:
        # _list is only lazily constructed if we have _set
        assert '_set' in self.__dict__
        return list(self._set)

    def __iter__(self) -> Iterator[RevnumT]:
        if self._ascending is None:
            return iter(self._list)
        elif self._ascending:
            return iter(self._asclist)
        else:
            return reversed(self._asclist)

    def fastasc(self) -> Iterator[RevnumT]:
        return iter(self._asclist)

    def fastdesc(self) -> Iterator[RevnumT]:
        return reversed(self._asclist)

    @util.propertycache
    def __contains__(self) -> Callable[[RevnumT], bool]:
        return self._set.__contains__

    def __nonzero__(self) -> bool:
        return bool(len(self))

    __bool__ = __nonzero__

    def sort(self, reverse: bool = False):
        self._ascending = not bool(reverse)
        self._istopo = False

    def reverse(self):
        if self._ascending is None:
            self._list.reverse()
        else:
            self._ascending = not self._ascending
        self._istopo = False

    def __len__(self) -> int:
        if '_list' in self.__dict__:
            return len(self._list)
        else:
            return len(self._set)

    def isascending(self) -> bool:
        """Returns True if the collection is ascending order, False if not.

        This is part of the mandatory API for smartset."""
        if len(self) <= 1:
            return True
        return self._ascending is not None and self._ascending

    def isdescending(self) -> bool:
        """Returns True if the collection is descending order, False if not.

        This is part of the mandatory API for smartset."""
        if len(self) <= 1:
            return True
        return self._ascending is not None and not self._ascending

    def istopo(self) -> bool:
        """Is the collection is in topographical order or not.

        This is part of the mandatory API for smartset."""
        if len(self) <= 1:
            return True
        return self._istopo

    def first(self) -> RevnumT | None:
        if self:
            if self._ascending is None:
                return self._list[0]
            elif self._ascending:
                return self._asclist[0]
            else:
                return self._asclist[-1]
        return None

    def last(self) -> RevnumT | None:
        if self:
            if self._ascending is None:
                return self._list[-1]
            elif self._ascending:
                return self._asclist[-1]
            else:
                return self._asclist[0]
        return None

    def _fastsetop(self, other: abstractsmartset, op: str) -> abstractsmartset:
        # try to use native set operations as fast paths
        if (
            type(other) is baseset
            and '_set' in other.__dict__
            and '_set' in self.__dict__
            and self._ascending is not None
        ):
            s = baseset(
                data=getattr(self._set, op)(other._set), istopo=self._istopo
            )
            s._ascending = self._ascending
        else:
            s = getattr(super(), op)(other)
        return s

    def __and__(self, other: abstractsmartset) -> abstractsmartset:
        return self._fastsetop(other, '__and__')

    def __sub__(self, other: abstractsmartset) -> abstractsmartset:
        return self._fastsetop(other, '__sub__')

    def _slice(self, start: int, stop: int) -> abstractsmartset:
        # creating new list should be generally cheaper than iterating items
        if self._ascending is None:
            return baseset(self._list[start:stop], istopo=self._istopo)

        data = self._asclist
        if not self._ascending:
            start, stop = max(len(data) - stop, 0), max(len(data) - start, 0)
        s = baseset(data[start:stop], istopo=self._istopo)
        s._ascending = self._ascending
        return s

    @encoding.strmethod
    def __repr__(self) -> bytes:
        d = {None: b'', False: b'-', True: b'+'}[self._ascending]
        s = stringutil.buildrepr(self._datarepr)
        if not s:
            l = self._list
            # if _list has been built from a set, it might have a different
            # order from one python implementation to another.
            # We fallback to the sorted version for a stable output.
            if self._ascending is not None:
                l = self._asclist
            s = pycompat.byterepr(l)
        return b'<%s%s %s>' % (_typename(self), d, s)


class filteredset(abstractsmartset):
    """Duck type for baseset class which iterates lazily over the revisions in
    the subset and contains a function which tests for membership in the
    revset
    """

    def __init__(
        self,
        subset: abstractsmartset,
        condition: Callable[[RevnumT], bool] = lambda x: True,
        condrepr=None,
    ):
        """
        condition: a function that decide whether a revision in the subset
                   belongs to the revset or not.
        condrepr: a tuple of (format, obj, ...), a function or an object that
                  provides a printable representation of the given condition.
        """
        self._subset = subset
        self._condition = condition
        self._condrepr = condrepr

    def __contains__(self, x: RevnumT) -> bool:
        return x in self._subset and self._condition(x)

    def __iter__(self) -> Iterator[RevnumT]:
        return self._iterfilter(self._subset)

    def _iterfilter(self, it: Iterable[RevnumT]) -> Iterator[RevnumT]:
        cond = self._condition
        for x in it:
            if cond(x):
                yield x

    @property
    def fastasc(self) -> Callable[[], Iterator[RevnumT]] | None:
        it = self._subset.fastasc
        if it is None:
            return None
        return lambda: self._iterfilter(it())

    @property
    def fastdesc(self) -> Callable[[], Iterator[RevnumT]] | None:
        it = self._subset.fastdesc
        if it is None:
            return None
        return lambda: self._iterfilter(it())

    def __nonzero__(self) -> bool:
        fast = None
        candidates = [
            self.fastasc if self.isascending() else None,
            self.fastdesc if self.isdescending() else None,
            self.fastasc,
            self.fastdesc,
        ]
        for candidate in candidates:
            if candidate is not None:
                fast = candidate
                break

        if fast is not None:
            it = fast()
        else:
            it = self

        for r in it:
            return True
        return False

    __bool__ = __nonzero__

    def __len__(self) -> int:
        # Basic implementation to be changed in future patches.
        # until this gets improved, we use generator expression
        # here, since list comprehensions are free to call __len__ again
        # causing infinite recursion
        l = baseset(r for r in self)
        return len(l)

    def sort(self, reverse: bool = False):
        self._subset.sort(reverse=reverse)

    def reverse(self):
        self._subset.reverse()

    def isascending(self) -> bool:
        return self._subset.isascending()

    def isdescending(self) -> bool:
        return self._subset.isdescending()

    def istopo(self) -> bool:
        return self._subset.istopo()

    def first(self) -> RevnumT | None:
        for x in self:
            return x
        return None

    def last(self) -> RevnumT | None:
        it = None
        if self.isascending():
            it = self.fastdesc
        elif self.isdescending():
            it = self.fastasc
        if it is not None:
            for x in it():
                return x
            return None  # empty case
        else:
            x = None
            for x in self:
                pass
            return x

    @encoding.strmethod
    def __repr__(self) -> bytes:
        xs = [pycompat.byterepr(self._subset)]
        s = stringutil.buildrepr(self._condrepr)
        if s:
            xs.append(s)
        return b'<%s %s>' % (_typename(self), b', '.join(xs))


def _iterordered(ascending: bool, iter1: Iterator, iter2: Iterator) -> Iterator:
    """produce an ordered iteration from two iterators with the same order

    The ascending is used to indicated the iteration direction.
    """
    choice = max
    if ascending:
        choice = min

    val1 = None
    val2 = None
    try:
        # Consume both iterators in an ordered way until one is empty
        while True:
            if val1 is None:
                val1 = next(iter1)
            if val2 is None:
                val2 = next(iter2)
            n = choice(val1, val2)
            yield n
            if val1 == n:
                val1 = None
            if val2 == n:
                val2 = None
    except StopIteration:
        # Flush any remaining values and consume the other one
        it = iter2
        if val1 is not None:
            yield val1
            it = iter1
        elif val2 is not None:
            # might have been equality and both are empty
            yield val2
        yield from it


class addset(abstractsmartset):
    """Represent the addition of two sets

    Wrapper structure for lazily adding two structures without losing much
    performance on the __contains__ method

    If the ascending attribute is set, that means the two structures are
    ordered in either an ascending or descending way. Therefore, we can add
    them maintaining the order by iterating over both at the same time

    >>> xs = baseset([0, 3, 2])
    >>> ys = baseset([5, 2, 4])

    >>> rs = addset(xs, ys)
    >>> bool(rs), 0 in rs, 1 in rs, 5 in rs, rs.first(), rs.last()
    (True, True, False, True, 0, 4)
    >>> rs = addset(xs, baseset([]))
    >>> bool(rs), 0 in rs, 1 in rs, rs.first(), rs.last()
    (True, True, False, 0, 2)
    >>> rs = addset(baseset([]), baseset([]))
    >>> bool(rs), 0 in rs, rs.first(), rs.last()
    (False, False, None, None)

    iterate unsorted:
    >>> rs = addset(xs, ys)
    >>> # (use generator because pypy could call len())
    >>> list(x for x in rs)  # without _genlist
    [0, 3, 2, 5, 4]
    >>> assert not rs._genlist
    >>> len(rs)
    5
    >>> [x for x in rs]  # with _genlist
    [0, 3, 2, 5, 4]
    >>> assert rs._genlist

    iterate ascending:
    >>> rs = addset(xs, ys, ascending=True)
    >>> # (use generator because pypy could call len())
    >>> list(x for x in rs), list(x for x in rs.fastasc())  # without _asclist
    ([0, 2, 3, 4, 5], [0, 2, 3, 4, 5])
    >>> assert not rs._asclist
    >>> len(rs)
    5
    >>> [x for x in rs], [x for x in rs.fastasc()]
    ([0, 2, 3, 4, 5], [0, 2, 3, 4, 5])
    >>> assert rs._asclist

    iterate descending:
    >>> rs = addset(xs, ys, ascending=False)
    >>> # (use generator because pypy could call len())
    >>> list(x for x in rs), list(x for x in rs.fastdesc())  # without _asclist
    ([5, 4, 3, 2, 0], [5, 4, 3, 2, 0])
    >>> assert not rs._asclist
    >>> len(rs)
    5
    >>> [x for x in rs], [x for x in rs.fastdesc()]
    ([5, 4, 3, 2, 0], [5, 4, 3, 2, 0])
    >>> assert rs._asclist

    iterate ascending without fastasc:
    >>> rs = addset(xs, generatorset(ys), ascending=True)
    >>> assert rs.fastasc is None
    >>> [x for x in rs]
    [0, 2, 3, 4, 5]

    iterate descending without fastdesc:
    >>> rs = addset(generatorset(xs), ys, ascending=False)
    >>> assert rs.fastdesc is None
    >>> [x for x in rs]
    [5, 4, 3, 2, 0]
    """

    def __init__(
        self,
        revs1: abstractsmartset,
        revs2: abstractsmartset,
        ascending: bool | None = None,
    ):
        self._r1 = revs1
        self._r2 = revs2
        self._iter = None
        self._ascending = ascending
        self._genlist = None
        self._asclist = None

    def __len__(self) -> int:
        return len(self._list)

    def __nonzero__(self) -> bool:
        return bool(self._r1) or bool(self._r2)

    __bool__ = __nonzero__

    @util.propertycache
    def _list(self) -> baseset:
        if not self._genlist:
            self._genlist = baseset(iter(self))
        return self._genlist

    def __iter__(self) -> Iterator[RevnumT]:
        """Iterate over both collections without repeating elements

        If the ascending attribute is not set, iterate over the first one and
        then over the second one checking for membership on the first one so we
        dont yield any duplicates.

        If the ascending attribute is set, iterate over both collections at the
        same time, yielding only one value at a time in the given order.
        """
        if self._ascending is None:
            if self._genlist:
                return iter(self._genlist)

            def arbitraryordergen():
                for r in self._r1:
                    yield r
                inr1 = self._r1.__contains__
                for r in self._r2:
                    if not inr1(r):
                        yield r

            return arbitraryordergen()
        # try to use our own fast iterator if it exists
        self._trysetasclist()
        if self._ascending:
            attr = 'fastasc'
        else:
            attr = 'fastdesc'
        it = getattr(self, attr)
        if it is not None:
            return it()
        # maybe half of the component supports fast
        # get iterator for _r1
        iter1 = getattr(self._r1, attr)
        if iter1 is None:
            # let's avoid side effect (not sure it matters)
            iter1 = iter(sorted(self._r1, reverse=not self._ascending))
        else:
            iter1 = iter1()
        # get iterator for _r2
        iter2 = getattr(self._r2, attr)
        if iter2 is None:
            # let's avoid side effect (not sure it matters)
            iter2 = iter(sorted(self._r2, reverse=not self._ascending))
        else:
            iter2 = iter2()
        return _iterordered(self._ascending, iter1, iter2)

    def _trysetasclist(self):
        """populate the _asclist attribute if possible and necessary"""
        if self._genlist is not None and self._asclist is None:
            self._asclist = sorted(self._genlist)

    @property
    def fastasc(self) -> Callable[[], Iterator[RevnumT]] | None:
        self._trysetasclist()
        if self._asclist is not None:
            return self._asclist.__iter__
        iter1 = self._r1.fastasc
        iter2 = self._r2.fastasc
        if None in (iter1, iter2):
            return None
        return lambda: _iterordered(True, iter1(), iter2())

    @property
    def fastdesc(self) -> Callable[[], Iterator[RevnumT]] | None:
        self._trysetasclist()
        if self._asclist is not None:
            return self._asclist.__reversed__
        iter1 = self._r1.fastdesc
        iter2 = self._r2.fastdesc
        if None in (iter1, iter2):
            return None
        return lambda: _iterordered(False, iter1(), iter2())

    def __contains__(self, x: RevnumT) -> bool:
        return x in self._r1 or x in self._r2

    def sort(self, reverse: bool = False):
        """Sort the added set

        For this we use the cached list with all the generated values and if we
        know they are ascending or descending we can sort them in a smart way.
        """
        self._ascending = not reverse

    def isascending(self) -> bool:
        return self._ascending is not None and self._ascending

    def isdescending(self) -> bool:
        return self._ascending is not None and not self._ascending

    def istopo(self) -> bool:
        # not worth the trouble asserting if the two sets combined are still
        # in topographical order. Use the sort() predicate to explicitly sort
        # again instead.
        return False

    def reverse(self):
        if self._ascending is None:
            self._list.reverse()
        else:
            self._ascending = not self._ascending

    def first(self) -> RevnumT | None:
        for x in self:
            return x
        return None

    def last(self) -> RevnumT | None:
        self.reverse()
        val = self.first()
        self.reverse()
        return val

    @encoding.strmethod
    def __repr__(self) -> bytes:
        d = {None: b'', False: b'-', True: b'+'}[self._ascending]
        return b'<%s%s %r, %r>' % (_typename(self), d, self._r1, self._r2)


class generatorset(abstractsmartset):
    """Wrap a generator for lazy iteration

    Wrapper structure for generators that provides lazy membership and can
    be iterated more than once.
    When asked for membership it generates values until either it finds the
    requested one or has gone through all the elements in the generator

    It is recommended to pass preserve_order=True. This may become the default
    in the future. For legacy reasons, the default is False, which is equivalent
    to passing True followed by calling sort().

    Basic operations with iterasc=None:

    >>> xs = generatorset([3, 1, 9], iterasc=None, preserve_order=True)
    >>> xs.first(), xs.last()
    (3, 9)
    >>> xs.isascending(), xs.isdescending()
    (False, False)
    >>> len(xs)
    3
    >>> list(xs)
    [3, 1, 9]
    >>> xs.reverse()
    >>> list(xs)
    [9, 1, 3]
    >>> xs.sort()
    >>> list(xs)
    [1, 3, 9]
    >>> xs.reverse()
    >>> list(xs)
    [9, 3, 1]

    Basic operations with iterasc=True:

    >>> xs = generatorset([1, 3, 9], iterasc=True, preserve_order=True)
    >>> xs.first(), xs.last()
    (1, 9)
    >>> xs.isascending(), xs.isdescending()
    (True, False)
    >>> len(xs)
    3
    >>> list(xs)
    [1, 3, 9]
    >>> xs.reverse()
    >>> list(xs)
    [9, 3, 1]
    >>> xs.sort()
    >>> list(xs)
    [1, 3, 9]
    >>> xs.reverse()
    >>> list(xs)
    [9, 3, 1]

    Basic operations with iterasc=False:

    >>> xs = generatorset([9, 3, 1], iterasc=False, preserve_order=True)
    >>> xs.first(), xs.last()
    (9, 1)
    >>> xs.isascending(), xs.isdescending()
    (False, True)
    >>> len(xs)
    3
    >>> list(xs)
    [9, 3, 1]
    >>> xs.reverse()
    >>> list(xs)
    [1, 3, 9]
    >>> xs.sort()
    >>> list(xs)
    [1, 3, 9]
    >>> xs.reverse()
    >>> list(xs)
    [9, 3, 1]

    Slicing:

    >>> xs = generatorset([1, 3, 9], iterasc=True, preserve_order=True)
    >>> list(xs.slice(0, 0))
    []
    >>> list(xs.slice(0, 3))
    [1, 3, 9]
    >>> list(xs.slice(0, 1))
    [1]
    >>> list(xs.slice(1, 3))
    [3, 9]
    >>> list(xs.slice(1, 0))
    []
    >>> list(xs.slice(2, 5))
    [9]

    Calling reverse() only affects new iterators, not existing ones:

    >>> xs = generatorset([3, 1, 9], iterasc=None, preserve_order=True)
    >>> it = iter(xs)
    >>> next(it)
    3
    >>> xs.reverse()
    >>> next(it)
    1
    >>> list(xs)
    [9, 1, 3]
    >>> list(it)
    [9]

    Calling sort() only affects new iterators, not existing ones:

    >>> xs = generatorset([3, 1, 9], iterasc=None, preserve_order=True)
    >>> it = iter(xs)
    >>> next(it)
    3
    >>> xs.sort()
    >>> next(it)
    1
    >>> list(xs)
    [1, 3, 9]
    >>> list(it)
    [9]

    If iterasc is incorrect, the result will be wrong:

    >>> xs = generatorset([0, 2, 1], iterasc=True, preserve_order=True)
    >>> xs.sort()  # no-op
    >>> list(xs)
    [0, 2, 1]
    >>> list(xs)  # cached
    [0, 2, 1]

    Passing preserve_order=False is equivalent to calling sort():

    >>> list(generatorset([0, 2, 1], preserve_order=False))
    [0, 1, 2]
    """

    def __new__(
        cls,
        gen,
        iterasc: bool | None = None,
        preserve_order: bool = False,
    ):
        if iterasc is None:
            typ = cls
        elif iterasc:
            typ = _generatorsetasc
        else:
            typ = _generatorsetdesc

        return super().__new__(typ)

    def __init__(
        self,
        gen,
        iterasc: bool | None = None,
        preserve_order: bool = False,
    ):
        """
        gen: a generator producing the values for the generatorset.
        iterasc: True if gen is ascending, False if descending, None if unknown
        preserve_order: True to yield values in the same order as gen;
            otherwise, yields values in ascending order (note that if iterasc
            is not True, this requires exhausting gen before yielding anything)
        """
        # Make sure self._gen is an iterator, not an iterable. Otherwise, each
        # _consumegen would operate on an fresh iterator from the start.
        self._gen = iter(gen)
        self._asclist = None
        self._cache = {}
        self._genlist = []
        self._finished = False
        if preserve_order:
            self._ascending = iterasc
        else:
            self._ascending = True

    def __nonzero__(self) -> bool:
        # Do not use 'for r in self' because it will enforce the iteration
        # order (default ascending), possibly unrolling a whole descending
        # iterator.
        if self._genlist:
            return True
        for r in self._consumegen():
            return True
        return False

    __bool__ = __nonzero__

    def __contains__(self, x: RevnumT) -> bool:
        if x in self._cache:
            return self._cache[x]

        # Use new values only, as existing values would be cached.
        for l in self._consumegen():
            if l == x:
                return True

        self._cache[x] = False
        return False

    def __iter__(self) -> Iterator[RevnumT]:
        if self._ascending is None:
            return self._iterator()
        if self._ascending:
            it = self.fastasc
        else:
            it = self.fastdesc
        if it is not None:
            return it()
        # we need to consume the iterator
        for x in self._consumegen():
            pass
        # recall the same code
        return iter(self)

    def _iterator(self) -> Iterator[RevnumT]:
        if self._finished:
            return iter(self._genlist)

        # We have to use this complex iteration strategy to allow multiple
        # iterations at the same time. We need to be able to catch revision
        # removed from _consumegen and added to genlist in another instance.
        #
        # Getting rid of it would provide an about 15% speed up on this
        # iteration.
        genlist = self._genlist
        nextgen = self._consumegen()
        _len, _next = len, next  # cache global lookup

        def gen():
            i = 0
            while True:
                if i < _len(genlist):
                    yield genlist[i]
                else:
                    try:
                        yield _next(nextgen)
                    except StopIteration:
                        return
                i += 1

        return gen()

    def _consumegen(self) -> Iterator[RevnumT]:
        cache = self._cache
        genlist = self._genlist.append
        for item in self._gen:
            cache[item] = True
            genlist(item)
            yield item
        if not self._finished:
            self._finished = True
        # Only sort _genlist if we need to. If sort() is called later, it will
        # find that fastasc/fastdesc are None and call _consumegen() again.
        if self._ascending is not None:
            self._set_fast_methods()

    def _set_fast_methods(self):
        if self._asclist is None:
            asc = self._genlist[:]
            asc.sort()
            self._asclist = asc
            self.fastasc = asc.__iter__
            self.fastdesc = asc.__reversed__

    def __len__(self) -> int:
        for x in self._consumegen():
            pass
        return len(self._genlist)

    def sort(self, reverse: bool = False):
        self._ascending = not reverse

    def reverse(self):
        if self._ascending is None:
            for x in self._consumegen():
                pass
            # make a copy to avoid intefering with ongoing iterations
            self._genlist = self._genlist[::-1]
        else:
            self._ascending = not self._ascending

    def isascending(self) -> bool:
        return self._ascending is not None and self._ascending

    def isdescending(self) -> bool:
        return self._ascending is not None and not self._ascending

    def istopo(self) -> bool:
        # We don't know if the generator is in topographical order.
        return False

    def first(self) -> RevnumT | None:
        if self._ascending is None:
            it = self._iterator
        elif self._ascending:
            it = self.fastasc
        else:
            it = self.fastdesc
        if it is None:
            # we need to consume all and try again
            for x in self._consumegen():
                pass
            return self.first()
        return next(it(), None)

    def last(self) -> RevnumT | None:
        if self._ascending is None:
            for x in self._consumegen():
                pass
            if self._genlist:
                return self._genlist[-1]
            return None
        if self._ascending:
            it = self.fastdesc
        else:
            it = self.fastasc
        if it is None:
            # we need to consume all and try again
            for x in self._consumegen():
                pass
            return self.last()
        return next(it(), None)

    @encoding.strmethod
    def __repr__(self) -> bytes:
        d = {None: b'~', False: b'-', True: b'+'}[self._ascending]
        return b'<%s%s>' % (_typename(self), d)


class _generatorsetasc(generatorset):
    """Special case of generatorset optimized for ascending generators."""

    fastasc = generatorset._iterator

    def __contains__(self, x: RevnumT) -> bool:
        if x in self._cache:
            return self._cache[x]

        # Use new values only, as existing values would be cached.
        for l in self._consumegen():
            if l == x:
                return True
            if l > x:
                break

        self._cache[x] = False
        return False

    def _set_fast_methods(self):
        self.fastasc = self._genlist.__iter__
        self.fastdesc = self._genlist.__reversed__


class _generatorsetdesc(generatorset):
    """Special case of generatorset optimized for descending generators."""

    fastdesc = generatorset._iterator

    def __contains__(self, x: RevnumT) -> bool:
        if x in self._cache:
            return self._cache[x]

        # Use new values only, as existing values would be cached.
        for l in self._consumegen():
            if l == x:
                return True
            if l < x:
                break

        self._cache[x] = False
        return False

    def _set_fast_methods(self):
        self.fastasc = self._genlist.__reversed__
        self.fastdesc = self._genlist.__iter__


def spanset(repo: RepoT, start: int = 0, end: int | None = None):
    """Create a spanset that represents a range of repository revisions

    start: first revision included the set (default to 0)
    end:   first revision excluded (last+1) (default to len(repo))

    Spanset will be descending if `end` < `start`.
    """
    if end is None:
        end = len(repo)
    ascending = start <= end
    if not ascending:
        start, end = end + 1, start + 1
    return _spanset(start, end, ascending, repo.changelog.filteredrevs)


class _spanset(abstractsmartset):
    """Duck type for baseset class which represents a range of revisions and
    can work lazily and without having all the range in memory

    Note that spanset(x, y) behave almost like range(x, y) except for two
    notable points:
    - when x < y it will be automatically descending,
    - revision filtered with this repoview will be skipped.

    """

    def __init__(self, start: int, end: int, ascending: bool, hiddenrevs):
        self._start = start
        self._end = end
        self._ascending = ascending
        self._hiddenrevs = hiddenrevs

    def sort(self, reverse: bool = False):
        self._ascending = not reverse

    def reverse(self):
        self._ascending = not self._ascending

    def istopo(self) -> bool:
        # not worth the trouble asserting if the two sets combined are still
        # in topographical order. Use the sort() predicate to explicitly sort
        # again instead.
        return False

    def _iterfilter(self, iterrange: Iterable[RevnumT]) -> Iterator[RevnumT]:
        s = self._hiddenrevs
        for r in iterrange:
            if r not in s:
                yield r

    def __iter__(self) -> Iterator[RevnumT]:
        if self._ascending:
            return self.fastasc()
        else:
            return self.fastdesc()

    def fastasc(self) -> Iterator[RevnumT]:
        iterrange = range(self._start, self._end)
        if self._hiddenrevs:
            return self._iterfilter(iterrange)
        return iter(iterrange)

    def fastdesc(self) -> Iterator[RevnumT]:
        iterrange = range(self._end - 1, self._start - 1, -1)
        if self._hiddenrevs:
            return self._iterfilter(iterrange)
        return iter(iterrange)

    def __contains__(self, rev: RevnumT) -> bool:
        hidden = self._hiddenrevs
        return (self._start <= rev < self._end) and not (
            hidden and rev in hidden
        )

    def __nonzero__(self) -> bool:
        for r in self:
            return True
        return False

    __bool__ = __nonzero__

    def __len__(self) -> int:
        if not self._hiddenrevs:
            return abs(self._end - self._start)
        else:
            count = 0
            start = self._start
            end = self._end
            for rev in self._hiddenrevs:
                if (end < rev <= start) or (start <= rev < end):
                    count += 1
            return abs(self._end - self._start) - count

    def isascending(self) -> bool:
        return self._ascending

    def isdescending(self) -> bool:
        return not self._ascending

    def first(self) -> RevnumT | None:
        if self._ascending:
            it = self.fastasc
        else:
            it = self.fastdesc
        for x in it():
            return x
        return None

    def last(self) -> RevnumT | None:
        if self._ascending:
            it = self.fastdesc
        else:
            it = self.fastasc
        for x in it():
            return x
        return None

    def _slice(self, start: int, stop: int) -> abstractsmartset:
        if self._hiddenrevs:
            # unoptimized since all hidden revisions in range has to be scanned
            return super()._slice(start, stop)
        if self._ascending:
            x = min(self._start + start, self._end)
            y = min(self._start + stop, self._end)
        else:
            x = max(self._end - stop, self._start)
            y = max(self._end - start, self._start)
        return _spanset(x, y, self._ascending, self._hiddenrevs)

    @encoding.strmethod
    def __repr__(self) -> bytes:
        d = {False: b'-', True: b'+'}[self._ascending]
        return b'<%s%s %d:%d>' % (_typename(self), d, self._start, self._end)


class fullreposet(_spanset):
    """a set containing all revisions in the repo

    This class exists to host special optimization and magic to handle virtual
    revisions such as "null".
    """

    def __init__(self, repo: RepoT):
        super().__init__(0, len(repo), True, repo.changelog.filteredrevs)

    def __and__(self, other: abstractsmartset) -> abstractsmartset:
        """As self contains the whole repo, all of the other set should also be
        in self. Therefore `self & other = other`.

        This boldly assumes the other contains valid revs only.
        """
        # other not a smartset, make is so
        if not hasattr(other, 'isascending'):
            # filter out hidden revision
            # (this boldly assumes all smartset are pure)
            #
            # `other` was used with "&", let's assume this is a set like
            # object.
            other = baseset(other)

        if self._hiddenrevs:
            other = other - self._hiddenrevs

        other.sort(reverse=self.isdescending())
        return other
