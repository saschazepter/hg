# repo.data_filter - encode and decode filters of the working copy files
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from typing import (
    Callable,
)

from ..interfaces.types import (
    HgPathT,
    MatcherT,
    RepoT,
    UiT,
)
from ..interfaces import (
    repository as i_repo,
)

from .. import (
    match as matchmod,
    pycompat,
)
from ..utils import procutil

FilterFnT = Callable[..., bytes]
"""A filter function

It is called as `fn(data, params, ui=ui, repo=repo, filename=path)` and returns
the filtered data.
"""

_FilterEntryT = tuple[MatcherT, FilterFnT, bytes]
"""A pattern matcher, the filter function it selects, and its parameters"""


def _load_filters(
    ui: UiT,
    root: bytes,
    data_filters: dict[bytes, FilterFnT],
    section: bytes,
) -> list[_FilterEntryT]:
    """build the filters configured in a config section"""
    l = []
    for pat, cmd in ui.configitems(section):
        if cmd == b'!':
            continue
        mf = matchmod.match(root, b'', [pat], warn=ui.warn)
        fn = None
        params = cmd
        for name, filterfn in data_filters.items():
            if cmd.startswith(name):
                fn = filterfn
                params = cmd[len(name) :].lstrip()
                break
        if not fn:
            fn = lambda s, c, **kwargs: procutil.filter(s, c)
            fn.__name__ = 'commandfilter'
        # Wrap old filters not supporting keyword arguments
        if not pycompat.getargspec(fn)[2]:
            oldfn = fn
            fn = lambda s, c, oldfn=oldfn, **kwargs: oldfn(s, c)
            fn.__name__ = 'compat-' + oldfn.__name__
        l.append((mf, fn, params))
    return l


class DataFilter(i_repo.IDataFilter):
    """the encode and decode filters of the working copy files

    Built by `load`, it never changes: the repository drops it when the config
    or the registered filters change.
    """

    @classmethod
    def load(
        cls,
        ui: UiT,
        root: bytes,
        data_filters: dict[bytes, FilterFnT],
    ) -> DataFilter | None:
        """build the encode and decode filters configured for the working copy

        The `[encode]` and `[decode]` config sections map file patterns to
        filter commands. A command starting with the name of a filter
        registered through `repo.adddatafilter` runs that filter, with the rest
        of the command as parameters. Any other command runs in a shell, see
        `procutil.filter`.

        Returns None when no filter is configured, the common case, so that
        callers can skip the filtering entirely.
        """
        encode_filters = _load_filters(ui, root, data_filters, b'encode')
        decode_filters = _load_filters(ui, root, data_filters, b'decode')
        if not encode_filters and not decode_filters:
            return None
        return cls(encode_filters, decode_filters)

    def __init__(
        self,
        encode_filters: list[_FilterEntryT],
        decode_filters: list[_FilterEntryT],
    ) -> None:
        self._encode_filters = encode_filters
        self._decode_filters = decode_filters

    def _filter(
        self,
        filters: list[_FilterEntryT],
        repo: RepoT,
        path: HgPathT,
        data: bytes,
    ) -> bytes:
        """run the data through the first of the filters matching the path"""
        for mf, fn, cmd in filters:
            if mf(path):
                repo.ui.debug(
                    b"filtering %s through %s\n"
                    % (path, cmd or pycompat.sysbytes(fn.__name__))
                )
                data = fn(data, cmd, ui=repo.ui, repo=repo, filename=path)
                break

        return data

    def encode(self, repo: RepoT, path: HgPathT, decoded_data: bytes) -> bytes:
        """turn the content of a working copy file into the one to store

        The repository is the one the filters are called with.
        """
        return self._filter(self._encode_filters, repo, path, decoded_data)

    def decode(self, repo: RepoT, path: HgPathT, encoded_data: bytes) -> bytes:
        """turn stored content into the one of a working copy file

        The repository is the one the filters are called with.
        """
        return self._filter(self._decode_filters, repo, path, encoded_data)

    def has_filter(self, path: HgPathT) -> bool:
        """whether an encode or decode filter applies to this path

        The content of the working copy file may then differ from the stored
        one.
        """
        for filters in (self._encode_filters, self._decode_filters):
            for mf, fn, cmd in filters:
                if mf(path):
                    return True
        return False
