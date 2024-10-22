# rcutil.py - utilities about config paths, special config sections etc.
#
#  Copyright Mercurial Contributors
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os

from typing import (
    Dict,
    List,
    Optional,
    Tuple,
    Union,
)

from .. import (
    encoding,
    localrepo,
    pycompat,
    requirements as requirementsmod,
    util,
    vfs,
)

from ..utils import resourceutil

if pycompat.iswindows:
    from .. import scmwindows as scmplatform
else:
    from .. import scmposix as scmplatform

fallbackpager = scmplatform.fallbackpager
systemrcpath = scmplatform.systemrcpath
userrcpath = scmplatform.userrcpath

ConfigItemT = Tuple[bytes, bytes, bytes, bytes]
ResourceIDT = Tuple[bytes, bytes]
FileRCT = bytes
ComponentT = Tuple[
    bytes,
    Union[
        List[ConfigItemT],
        FileRCT,
        ResourceIDT,
    ],
]


def _expandrcpath(path: bytes) -> List[FileRCT]:
    '''path could be a file or a directory. return a list of file paths'''
    p = util.expandpath(path)
    if os.path.isdir(p):
        join = os.path.join
        return sorted(
            join(p, f) for f, k in util.listdir(p) if f.endswith(b'.rc')
        )
    return [p]


def envrcitems(env: Optional[Dict[bytes, bytes]] = None) -> List[ConfigItemT]:
    """Return [(section, name, value, source)] config items.

    The config items are extracted from environment variables specified by env,
    used to override systemrc, but not userrc.

    If env is not provided, encoding.environ will be used.
    """
    if env is None:
        env = encoding.environ
    checklist = [
        (b'EDITOR', b'ui', b'editor'),
        (b'VISUAL', b'ui', b'editor'),
        (b'PAGER', b'pager', b'pager'),
    ]
    result = []
    for envname, section, configname in checklist:
        if envname not in env:
            continue
        result.append((section, configname, env[envname], b'$%s' % envname))
    return result


def default_rc_resources() -> List[ResourceIDT]:
    """return rc resource IDs in defaultrc"""
    rsrcs = resourceutil.contents(b'mercurial.defaultrc')
    return [
        (b'mercurial.defaultrc', r)
        for r in sorted(rsrcs)
        if resourceutil.is_resource(b'mercurial.defaultrc', r)
        and r.endswith(b'.rc')
    ]


def rccomponents() -> List[ComponentT]:
    """return an ordered [(type, obj)] about where to load configs.

    respect $HGRCPATH. if $HGRCPATH is empty, only .hg/hgrc of current repo is
    used. if $HGRCPATH is not set, the platform default will be used.

    if a directory is provided, *.rc files under it will be used.

    type could be either 'path', 'items' or 'resource'. If type is 'path',
    obj is a string, and is the config file path. if type is 'items', obj is a
    list of (section, name, value, source) that should fill the config directly.
    If type is 'resource', obj is a tuple of (package name, resource name).
    """
    envrc = (b'items', envrcitems())

    if b'HGRCPATH' in encoding.environ:
        # assume HGRCPATH is all about user configs so environments can be
        # overridden.
        _rccomponents = [envrc]
        for p in encoding.environ[b'HGRCPATH'].split(pycompat.ospathsep):
            if not p:
                continue
            _rccomponents.extend((b'path', p) for p in _expandrcpath(p))
    else:
        _rccomponents = [(b'resource', r) for r in default_rc_resources()]

        normpaths = lambda paths: [
            (b'path', os.path.normpath(p)) for p in paths
        ]
        _rccomponents.extend(normpaths(systemrcpath()))
        _rccomponents.append(envrc)
        _rccomponents.extend(normpaths(userrcpath()))
    return _rccomponents


def _shared_source_component(path: bytes) -> List[FileRCT]:
    """if the current repository is shared one, this tries to read
    .hg/hgrc of shared source if we are in share-safe mode

    This should be called before reading .hg/hgrc or the main repo
    as that overrides config set in shared source"""
    try:
        with open(os.path.join(path, b".hg", b"requires"), "rb") as fp:
            requirements = set(fp.read().splitlines())
            if not (
                requirementsmod.SHARESAFE_REQUIREMENT in requirements
                and requirementsmod.SHARED_REQUIREMENT in requirements
            ):
                return []
            hgvfs = vfs.vfs(os.path.join(path, b".hg"))
            sharedvfs = localrepo._getsharedvfs(hgvfs, requirements)
            return [sharedvfs.join(b"hgrc")]
    except IOError:
        pass
    return []


def repo_components(repo_path: bytes) -> List[FileRCT]:
    """return the list of config file to read for a repository"""
    components = []
    components.extend(_shared_source_component(repo_path))
    components.append(os.path.join(repo_path, b".hg", b"hgrc"))
    components.append(os.path.join(repo_path, b".hg", b"hgrc-not-shared"))
    return components


def defaultpagerenv() -> Dict[bytes, bytes]:
    """return a dict of default environment variables and their values,
    intended to be set before starting a pager.
    """
    return {b'LESS': b'FRX', b'LV': b'-c'}


def use_repo_hgrc() -> bool:
    """True if repositories `.hg/hgrc` config should be read"""
    return b'HGRCSKIPREPO' not in encoding.environ
