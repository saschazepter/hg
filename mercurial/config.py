# config.py - configuration parsing for Mercurial
#
#  Copyright 2009 Olivia Mackall <olivia@selenic.com> and others
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import errno
import os
import typing

from .i18n import _
from . import (
    encoding,
    error,
    util,
)

if typing.TYPE_CHECKING:
    from .interfaces.types import (
        CfgRemapT,
        CfgSectionsT,
    )

if typing.TYPE_CHECKING:
    # config hold tuple of (value, source, config_level)
    _ItemT = tuple[bytes, bytes, int]

    _SectionT = util.cowsortdict[bytes, _ItemT]
    _DataT = dict[bytes, _SectionT]

    # backup for missing value is (section, key)
    # backup for existing value is (section, key, *_ItemT)
    _BackupT = tuple[bytes, bytes] | tuple[bytes, bytes, bytes, bytes, int]


# Distance between the levels of two sources read one after the other.
#
# Consecutive sources are spaced out, leaving room to insert a source in
# between two others afterwards.
SOURCE_LEVEL_STEP = 10


class config:
    def __init__(self, data: config | None = None):
        self._current_source_level: int = 0
        self._data: _DataT = {}
        self._unset: list[tuple[bytes, bytes]] = []
        # levels of every source we ever saw, see `_register_source`
        #
        # Hold a set of levels, because a source with include will spawn
        # multiple levels.
        self._source_levels: dict[bytes, set[int]] = {}
        if data:
            for k, base in data._data.items():
                v: _SectionT = base.copy()
                self._data[k] = v
            self._source_levels = {
                source: set(levels)
                for source, levels in data._source_levels.items()
            }
            next_level = data._current_source_level + SOURCE_LEVEL_STEP
            self._current_source_level = next_level

    def new_source(self) -> None:
        """increment the source counter

        This is used to define source priority when reading"""
        self._current_source_level += SOURCE_LEVEL_STEP

    def _register_source(self, source: bytes) -> None:
        """record that `source` was seen at the current source level

        Every source is recorded, including the ones that provided no value
        at all (an empty configuration file for example), so that the
        priority of a source is known without having to find an item coming
        from it.

        >>> cfg = config()
        >>> cfg.new_source()
        >>> cfg.parse(
        ...     b'file-a',
        ...     b'[one]\\n'
        ...     b'key = a\\n',
        ... )
        >>> cfg.new_source()
        >>> cfg.parse(b'empty-file', b'')
        >>> cfg.new_source()
        >>> cfg.set(b'ui', b'editor', b'vi', b'$EDITOR')
        >>> for src, lvls in sorted(cfg._source_levels.items()):
        ...     print(src, lvls)
        b'$EDITOR' {30}
        b'empty-file' {20}
        b'file-a' {10}


        Reading a source again records the new level too:

        >>> cfg.new_source()
        >>> cfg.parse(
        ...     b'file-a',
        ...     b'[two]\\n'
        ...     b'key = b\\n',
        ... )
        >>> sorted(cfg._source_levels[b'file-a'])
        [10, 40]


        Reading a source spans several levels when it includes another one,
        the included source sitting in between:

        (the actual include logic is dealt with by `read`, not `parse`, but
        `read` access the read file systen, so we have to simulate it. redoing
        some of the work. This is "okay" as this test make sure "duplicated"
        source are recorded multiple time.)

        >>> cfg = config()
        >>> def include(path, remap=None, sections=None):
        ...     cfg.new_source()
        ...     cfg.parse(
        ...         path,
        ...         b'[one]\\n'
        ...         b'key = from-include\\n',
        ...     )
        ...     cfg.new_source()
        >>> cfg.new_source()
        >>> cfg.parse(
        ...     b'file-a',
        ...     b'%include file-b\\n'
        ...     b'[one]\\n'
        ...     b'key = a\\n',
        ...     include=include,
        ... )
        >>> sorted(cfg._source_levels[b'file-a'])
        [10, 30]
        >>> sorted(cfg._source_levels[b'file-b'])
        [20]

        Each include is accounted for, so a source including two others
        spans four levels, two of them its own:

        >>> cfg = config()
        >>> cfg.new_source()
        >>> cfg.parse(
        ...     b'file-a',
        ...     b'%include file-b\\n'
        ...     b'[one]\\n'
        ...     b'key = a\\n'
        ...     b'%include file-c\\n',
        ...     include=include,
        ... )
        >>> sorted(cfg._source_levels[b'file-a'])
        [10, 30, 50]
        >>> sorted(cfg._source_levels[b'file-b'])
        [20]
        >>> sorted(cfg._source_levels[b'file-c'])
        [40]


        Values set without a source are not recorded:

        >>> cfg.set(b'one', b'key', b'c')
        >>> sorted(cfg._source_levels)
        [b'file-a', b'file-b', b'file-c']
        """
        if not source:
            return
        levels = self._source_levels.setdefault(source, set())
        levels.add(self._current_source_level)

    def copy(self) -> config:
        return config(self)

    def __contains__(self, section: bytes) -> bool:
        return section in self._data

    def hasitem(self, section: bytes, item: bytes) -> bool:
        return item in self._data.get(section, {})

    def __getitem__(self, section: bytes) -> dict[bytes, _ItemT]:
        return self._data.get(section, {})

    def __iter__(self) -> typing.Iterator[bytes]:
        yield from self.sections()

    def update(self, src: config) -> None:
        current_level = self._current_source_level
        current_level += SOURCE_LEVEL_STEP
        for s, n in src._unset:
            ds = self._data.get(s, None)
            if ds is not None and n in ds:
                self._data[s] = ds.preparewrite()
                del self._data[s][n]
        # import the value from `src`, all config level are shifted by
        # `current_level` to ensure the imported value overwrite the
        # pre-existing one.
        for s in src:
            ds = self._data.get(s, None)
            if ds:
                self._data[s] = ds.preparewrite()
            else:
                self._data[s] = util.cowsortdict()
            for k, v in src._data[s].items():
                value, source, level = v
                level += current_level
                self._data[s][k] = (value, source, level)
        # now that the value are imported, we need to also import the
        # `source_levels` value. Shifted in the same way.
        for source_name, source_levels in src._source_levels.items():
            shifted = {level + current_level for level in source_levels}
            self._source_levels.setdefault(source_name, set()).update(shifted)
        # now adjust the next level to be above everything we just imported.
        next_level = current_level + src._current_source_level
        next_level += SOURCE_LEVEL_STEP
        self._current_source_level = next_level

    def _get(self, section: bytes, item: bytes) -> _ItemT | None:
        return self._data.get(section, {}).get(item)

    def get(
        self,
        section: bytes,
        item: bytes,
        default: bytes | None = None,
    ) -> bytes | None:
        result = self._get(section, item)
        if result is None:
            return default
        return result[0]

    def backup(self, section: bytes, key: bytes) -> _BackupT:
        """return a tuple allowing restore to reinstall a previous value

        The main reason we need it is because it handles the "no data" case.
        """
        try:
            item = self._data[section][key]
        except KeyError:
            return (section, key)
        else:
            return (section, key) + item

    def source(self, section: bytes, item: bytes) -> bytes:
        result = self._get(section, item)
        if result is None:
            return b""
        return result[1]

    def level(self, section: bytes, item: bytes) -> int | None:
        result = self._get(section, item)
        if result is None:
            return None
        return result[2]

    def sections(self) -> list[bytes]:
        return sorted(self._data.keys())

    def items(self, section: bytes) -> list[tuple[bytes, bytes]]:
        items = self._data.get(section, {}).items()
        return [(k, v[0]) for (k, v) in items]

    def set(
        self,
        section: bytes,
        item: bytes,
        value: bytes,
        source: bytes = b"",
    ) -> None:
        """install `value` for `section.item`, at the current source level"""
        assert not isinstance(
            section, str
        ), b'config section may not be unicode strings on Python 3'
        assert not isinstance(
            item, str
        ), b'config item may not be unicode strings on Python 3'
        assert not isinstance(
            value, str
        ), b'config values may not be unicode strings on Python 3'
        self._register_source(source)
        self._set_item(section, item, value, source)

    def _set_item(
        self,
        section: bytes,
        item: bytes,
        value: bytes,
        source: bytes,
    ) -> None:
        """install `value` for `section.item`, at the current source level

        Internal function, use `set(…)` instead.
        """
        if section not in self:
            self._data[section] = util.cowsortdict()
        else:
            self._data[section] = self._data[section].preparewrite()
        self._data[section][item] = (value, source, self._current_source_level)

    def alter(self, section: bytes, key: bytes, new_value: bytes) -> None:
        """alter a value without altering its source or level

        This method is meant to be used by `ui.fixconfig` only."""
        item = self._data[section][key]
        size = len(item)
        new_item = (new_value,) + item[1:]
        assert len(new_item) == size
        self._data[section][key] = new_item

    def restore(self, data: _BackupT) -> None:
        """restore data returned by self.backup"""
        if len(data) != 2:
            # restore old data
            section, key = data[:2]
            item = data[2:]
            self._data[section] = self._data[section].preparewrite()
            self._data[section][key] = item
        else:
            # no data before, remove everything
            #
            # (the range usage ([:2]) helps pytype and `restore` is not used
            # often enough for the performance impact to matter.)
            section, item = data[:2]
            if section in self._data:
                self._data[section].pop(item, None)

    def parse(
        self,
        src: bytes,
        data: bytes,
        sections: CfgSectionsT | None = None,
        remap: CfgRemapT | None = None,
        include=None,
    ) -> None:
        sectionre = util.re.compile(br'\[([^\[]+)\]')
        itemre = util.re.compile(br'([^=\s][^=]*?)\s*=\s*(.*\S|)')
        contre = util.re.compile(br'\s+(\S|\S.*\S)\s*$')
        emptyre = util.re.compile(br'(;|#|\s*$)')
        commentre = util.re.compile(br'(;|#)')
        unsetre = util.re.compile(br'%unset\s+(\S+)')
        includere = util.re.compile(br'%include\s+(\S|\S.*\S)\s*$')
        section = b""
        item = None
        line = 0
        cont = False

        self._register_source(src)

        if remap:
            section = remap.get(section, section)

        for l in data.splitlines(True):
            line += 1
            if line == 1 and l.startswith(b'\xef\xbb\xbf'):
                # Someone set us up the BOM
                l = l[3:]
            if cont:
                if commentre.match(l):
                    continue
                m = contre.match(l)
                if m:
                    if sections and section not in sections:
                        continue
                    v = self.get(section, item) + b"\n" + m.group(1)
                    self._set_item(section, item, v, b"%s:%d" % (src, line))
                    continue
                item = None
                cont = False
            m = includere.match(l)

            if m and include:
                expanded = util.expandpath(m.group(1))
                try:
                    include(expanded, remap=remap, sections=sections)
                except OSError as inst:
                    if inst.errno != errno.ENOENT:
                        raise error.ConfigError(
                            _(b"cannot include %s (%s)")
                            % (expanded, encoding.strtolocal(inst.strerror)),
                            b"%s:%d" % (src, line),
                        )
                # the include consumed levels of its own, the rest of `src`
                # belongs to a new one.
                self._register_source(src)
                continue
            if emptyre.match(l):
                continue
            m = sectionre.match(l)
            if m:
                section = m.group(1)
                if remap:
                    section = remap.get(section, section)
                if section not in self:
                    self._data[section] = util.cowsortdict()
                continue
            m = itemre.match(l)
            if m:
                item = m.group(1)
                cont = True
                if sections and section not in sections:
                    continue
                self._set_item(
                    section,
                    item,
                    m.group(2),
                    b"%s:%d" % (src, line),
                )
                continue
            m = unsetre.match(l)
            if m:
                name = m.group(1)
                if sections and section not in sections:
                    continue
                if self.get(section, name) is not None:
                    self._data[section] = self._data[section].preparewrite()
                    del self._data[section][name]
                self._unset.append((section, name))
                continue

            message = l.rstrip()
            if l.startswith(b' '):
                message = b"unexpected leading whitespace: %s" % message
            raise error.ConfigError(message, (b"%s:%d" % (src, line)))

    def serialize(self) -> bytes:
        """serialize the config content to bytes

        The output can be parsed back into an equivalent config object.

        (except for "%include" and "%unset" which are not visible to the
        config object so far.)

        Values holding newlines are emitted as continuation lines.

        ### Basic tests
        >>> cfg = config()
        >>> cfg.set(b'ui', b'username', b'Babar')
        >>> cfg.set(b'ui', b'editor', b'emacs')
        >>> cfg.set(b'alias', b'log-x', b'log -G')
        >>> print(cfg.serialize().decode('ascii'), end='')
        [alias]
        log-x = log -G
        [ui]
        editor = emacs
        username = Babar

        ### Multi-line tests
        >>> cfg.set(b'ui', b'multi-line', b'the first line\\nand another one')
        >>> print(cfg.serialize().decode('ascii'), end='')
        [alias]
        log-x = log -G
        [ui]
        editor = emacs
        multi-line = the first line
          and another one
        username = Babar

        ### Round trip test
        >>> round_tripped = config()
        >>> round_tripped.parse(b'<serialized>', cfg.serialize())
        >>> round_tripped.serialize() == cfg.serialize()
        True
        """
        chunks = []
        for section in self.sections():
            chunks.append(b"[%s]\n" % section)
            for key, value in sorted(self.items(section)):
                value = value.replace(b'\n', b'\n  ')
                chunks.append(b"%s = %s\n" % (key, value))
        return b"".join(chunks)

    def read(
        self,
        path: bytes,
        fp=None,
        sections: CfgSectionsT | None = None,
        remap: CfgRemapT | None = None,
    ) -> None:
        self.new_source()
        if not fp:
            fp = util.posixfile(path, b'rb')
        assert (
            getattr(fp, 'mode', 'rb') == 'rb'
        ), b'config files must be opened in binary mode, got fp=%r mode=%r' % (
            fp,
            fp.mode,
        )

        dir = os.path.dirname(path)

        def include(
            rel: bytes,
            remap: CfgRemapT | None,
            sections: CfgSectionsT | None,
        ) -> None:
            abs = os.path.normpath(os.path.join(dir, rel))
            self.read(abs, remap=remap, sections=sections)
            # anything after the include has a higher level
            self.new_source()

        self.parse(
            path, fp.read(), sections=sections, remap=remap, include=include
        )


def parse_single_arg(spec: bytes) -> tuple[bytes, bytes, bytes]:
    """parse a ``section.name=value`` specification into a triplet

    Whitespaces around the ``section.name`` part and around the value are
    stripped.

    A ``ValueError`` is raised for malformed specifications.

    >>> parse_single_arg(b'ui.username=Babar')
    (b'ui', b'username', b'Babar')
    >>> parse_single_arg(b' ui.username = Babar the king ')
    (b'ui', b'username', b'Babar the king')

    The name part may contain dots and the value may be empty:

    >>> parse_single_arg(b'alias.log.short=')
    (b'alias', b'log.short', b'')

    Malformed specifications are rejected:

    >>> parse_single_arg(b'ui.username')
    Traceback (most recent call last):
        ...
    ValueError: malformed config specification: b'ui.username'
    >>> parse_single_arg(b'username=Babar')
    Traceback (most recent call last):
        ...
    ValueError: malformed config specification: b'username=Babar'
    >>> parse_single_arg(b'.username=Babar')
    Traceback (most recent call last):
        ...
    ValueError: malformed config specification: b'.username=Babar'
    """
    if b"=" not in spec:
        raise ValueError('malformed config specification: %r' % spec)
    key, value = spec.split(b'=', 1)
    key = key.strip()
    if b'.' not in key:
        raise ValueError('malformed config specification: %r' % spec)
    section, name = key.split(b'.', 1)
    if not section or not name:
        raise ValueError('malformed config specification: %r' % spec)
    return (section, name, value.strip())
