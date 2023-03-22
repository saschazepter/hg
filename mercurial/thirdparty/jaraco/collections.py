# adapted from jaraco.collections 3.9

import collections


class Projection(collections.abc.Mapping):
    """
    Project a set of keys over a mapping

    >>> sample = {'a': 1, 'b': 2, 'c': 3}
    >>> prj = Projection(['a', 'c', 'd'], sample)
    >>> prj == {'a': 1, 'c': 3}
    True

    Keys should only appear if they were specified and exist in the space.

    >>> sorted(list(prj.keys()))
    ['a', 'c']

    Attempting to access a key not in the projection
    results in a KeyError.

    >>> prj['b']
    Traceback (most recent call last):
    ...
    KeyError: 'b'

    Use the projection to update another dict.

    >>> target = {'a': 2, 'b': 2}
    >>> target.update(prj)
    >>> target == {'a': 1, 'b': 2, 'c': 3}
    True

    Also note that Projection keeps a reference to the original dict, so
    if you modify the original dict, that could modify the Projection.

    >>> del sample['a']
    >>> dict(prj)
    {'c': 3}
    """

    def __init__(self, keys, space):
        self._keys = tuple(keys)
        self._space = space

    def __getitem__(self, key):
        if key not in self._keys:
            raise KeyError(key)
        return self._space[key]

    def __iter__(self):
        return iter(set(self._keys).intersection(self._space))

    def __len__(self):
        return len(tuple(iter(self)))
