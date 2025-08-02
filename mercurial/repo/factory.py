# repo.factory - class to find and create repository and peers
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import stat

from ..i18n import _
from .. import (
    bundlerepo,
    error,
    extensions,
    httppeer,
    localrepo,
    sshpeer,
    statichttprepo,
    unionrepo,
    util,
)
from ..utils import (
    stringutil,
    urlutil,
)


class LocalFactory:
    """thin wrapper to dispatch between localrepo and bundle repo"""

    @staticmethod
    def islocal(path: bytes) -> bool:
        path = util.expandpath(urlutil.urllocalpath(path))
        return not _isfile(path)

    @staticmethod
    def instance(ui, path, *args, **kwargs):
        path = util.expandpath(urlutil.urllocalpath(path))
        if _isfile(path):
            cls = bundlerepo
        else:
            cls = localrepo
        return cls.instance(ui, path, *args, **kwargs)


# a list of (ui, repo) functions called for wire peer initialization
wirepeersetupfuncs = []


repo_schemes = {
    b'bundle': bundlerepo,
    b'union': unionrepo,
    b'file': LocalFactory,
}

peer_schemes = {
    b'http': httppeer,
    b'https': httppeer,
    b'ssh': sshpeer,
    b'static-http': statichttprepo,
}


def _remoteui(src, opts):
    """build a remote ui from ui or repo and opts"""
    if hasattr(src, 'baseui'):  # looks like a repository
        dst = src.baseui.copy()  # drop repo-specific config
        src = src.ui  # copy target options from repo
    else:  # assume it's a global ui object
        dst = src.copy()  # keep all global options

    # copy ssh-specific options
    for o in b'ssh', b'remotecmd':
        v = opts.get(o) or src.config(b'ui', o)
        if v:
            dst.setconfig(b"ui", o, v, b'copied')

    # copy bundle-specific options
    r = src.config(b'bundle', b'mainreporoot')
    if r:
        dst.setconfig(b'bundle', b'mainreporoot', r, b'copied')

    # copy selected local settings to the remote ui
    for sect in (b'auth', b'hostfingerprints', b'hostsecurity', b'http_proxy'):
        for key, val in src.configitems(sect):
            dst.setconfig(sect, key, val, b'copied')
    v = src.config(b'web', b'cacerts')
    if v:
        dst.setconfig(b'web', b'cacerts', util.expandpath(v), b'copied')

    return dst


def peer(
    uiorrepo,
    opts,
    path,
    create=False,
    intents=None,
    createopts=None,
    remotehidden=False,
):
    '''return a repository peer for the specified path'''
    ui = getattr(uiorrepo, 'ui', uiorrepo)
    rui = _remoteui(uiorrepo, opts)
    if hasattr(path, 'url'):
        # this is already a urlutil.path object
        peer_path = path
    else:
        peer_path = urlutil.path(ui, None, rawloc=path, validate_path=False)
    scheme = peer_path.url.scheme  # pytype: disable=attribute-error
    if scheme in peer_schemes:
        cls = peer_schemes[scheme]
        peer = cls.make_peer(
            rui,
            peer_path,
            create,
            intents=intents,
            createopts=createopts,
            remotehidden=remotehidden,
        )
        _setup_repo_or_peer(rui, peer)
    else:
        # this is a repository
        repo_path = peer_path.loc  # pytype: disable=attribute-error
        if not repo_path:
            repo_path = peer_path.rawloc  # pytype: disable=attribute-error
        repo = repository(
            rui,
            repo_path,
            create,
            intents=intents,
            createopts=createopts,
        )
        peer = repo.peer(path=peer_path, remotehidden=remotehidden)
    return peer


def _setup_repo_or_peer(ui, obj, presetupfuncs=None):
    ui = getattr(obj, "ui", ui)
    for f in presetupfuncs or []:
        f(ui, obj)
    ui.log(b'extension', b'- executing reposetup hooks\n')
    with util.timedcm('all reposetup') as allreposetupstats:
        for name, module in extensions.extensions(ui):
            ui.log(b'extension', b'  - running reposetup for %s\n', name)
            hook = getattr(module, 'reposetup', None)
            if hook:
                with util.timedcm('reposetup %r', name) as stats:
                    hook(ui, obj)
                msg = b'  > reposetup for %s took %s\n'
                ui.log(b'extension', msg, name, stats)
    ui.log(b'extension', b'> all reposetup took %s\n', allreposetupstats)
    if not obj.local():
        for f in wirepeersetupfuncs:
            f(ui, obj)


def repository(
    ui,
    path=b'',
    create=False,
    presetupfuncs=None,
    intents=None,
    createopts=None,
):
    """return a repository object for the specified path"""
    scheme = urlutil.url(path).scheme
    if scheme is None:
        scheme = b'file'
    cls = repo_schemes.get(scheme)
    if cls is None:
        if scheme in peer_schemes:
            raise error.Abort(_(b"repository '%s' is not local") % path)
        cls = LocalFactory
    repo = cls.instance(
        ui,
        path,
        create,
        intents=intents,
        createopts=createopts,
    )
    _setup_repo_or_peer(ui, repo, presetupfuncs=presetupfuncs)
    return repo.filtered(b'visible')


def _isfile(path):
    try:
        # we use os.stat() directly here instead of os.path.isfile()
        # because the latter started returning `False` on invalid path
        # exceptions starting in 3.8 and we care about handling
        # invalid paths specially here.
        st = os.stat(path)
    except ValueError as e:
        msg = stringutil.forcebytestr(e)
        raise error.Abort(_(b'invalid path %s: %s') % (path, msg))
    except OSError:
        return False
    else:
        return stat.S_ISREG(st.st_mode)
