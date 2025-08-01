# hg.py - repository classes for mercurial
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
# Copyright 2006 Vadim Gelfer <vadim.gelfer@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import stat

from .i18n import _
from .node import (
    short,
)

from . import (
    error,
    localrepo,
    lock,
    merge as mergemod,
    scmutil,
    util,
    verify as verifymod,
)
from .cmd_impls import (
    clone as clone_impl,
    incoming as inc_impl,
    outgoing as out_impl,
    update as up_impl,
)
from .repo import factory as repo_factory
from .utils import (
    urlutil,
)


release = lock.release


def addbranchrevs(lrepo, *args, **kwargs):
    msg = b'``hg.addbranchrevs(...)` moved to `urlutil.add_branch_revs(...)`'
    lrepo.ui.deprecwarn(msg, b'7.3')
    return urlutil.add_branch_revs(lrepo, *args, **kwargs)


# a list of (ui, repo) functions called for wire peer initialization
wirepeersetupfuncs = repo_factory.wirepeersetupfuncs
repo_schemes = repo_factory.repo_schemes
peer_schemes = repo_factory.peer_schemes


def islocal(repo: bytes) -> bool:
    util.nouideprecwarn(
        b'hg.islocal(path), moved to repo.factor.is_local(path)', b'7.3'
    )
    return repo_factory.is_local(repo)


def openpath(*args, **kwargs):
    msg = b'`hg.openpath(...)` moved to scmutil.open_path(...)'
    util.nouideprecwarn(msg, b'7.3')
    return scmutil.open_path(*args, **kwargs)


def peer(uiorrepo, *args, **kwargs):
    ui = getattr(uiorrepo, 'ui', uiorrepo)
    msg = b'``hg.peer(...)` moved to `repo.factory.peer(...)`'
    ui.deprecwarn(msg, b'7.3')
    return repo_factory.peer(uiorrepo, *args, **kwargs)


def repository(uiorrepo, *args, **kwargs):
    ui = getattr(uiorrepo, 'ui', uiorrepo)
    msg = b'``hg.repository(...)` moved to `repo.factory.repository(...)`'
    ui.deprecwarn(msg, b'7.3')
    return repo_factory.repository(uiorrepo, *args, **kwargs)


def defaultdest(source):
    msg = b'hg.defaultdest(src), moved to cmd_impls.clone.default_dest(src)'
    util.nouideprecwarn(msg, b'7.3')
    return clone_impl.default_dest(source)


def share(ui, *args, **kwargs):
    msg = b'``hg.share(...)` moved to `cmd_impls.clone.share(...)`'
    ui.deprecwarn(msg, b'7.3')
    return clone_impl.share(ui, *args, **kwargs)


def unshare(ui, *args, **kwargs):
    msg = b'``hg.unshare(...)` moved to `cmd_impls.clone.unshare(...)`'
    ui.deprecwarn(msg, b'7.3')
    return clone_impl.unshare(ui, *args, **kwargs)


def clone(ui, *args, **kwargs):
    msg = b'``hg.clone(...)` moved to `cmd_impls.clone.clone(...)`'
    ui.deprecwarn(msg, b'7.3')
    return clone_impl.clone(ui, *args, **kwargs)


def sharedreposource(repo):
    """Returns repository object for source repository of a shared repo.

    If repo is not a shared repository, returns None.
    """
    if repo.sharedpath == repo.path:
        return None

    if hasattr(repo, 'srcrepo') and repo.srcrepo:
        return repo.srcrepo

    # the sharedpath always ends in the .hg; we want the path to the repo
    source = repo.vfs.split(repo.sharedpath)[0]
    srcurl, branches = urlutil.parseurl(source)
    srcrepo = repo_factory.repository(repo.ui, srcurl)
    repo.srcrepo = srcrepo
    return srcrepo


# Recomputing caches is often slow on big repos, so copy them.
def _copycache(srcrepo, dstcachedir, fname):
    """copy a cache from srcrepo to destcachedir (if it exists)"""
    srcfname = srcrepo.cachevfs.join(fname)
    dstfname = os.path.join(dstcachedir, fname)
    if os.path.exists(srcfname):
        if not os.path.exists(dstcachedir):
            os.mkdir(dstcachedir)
        util.copyfile(srcfname, dstfname)


def updaterepo(repo, node, overwrite, updatecheck=None):
    """Update the working directory to node.

    When overwrite is set, changes are clobbered, merged else

    returns stats (see pydoc mercurial.merge_utils.update.apply_updates)"""
    repo.ui.deprecwarn(
        b'prefer merge.update() or merge.clean_update() over hg.updaterepo()',
        b'5.7',
    )
    return mergemod._update(
        repo,
        node,
        branchmerge=False,
        force=overwrite,
        labels=[b'working copy', b'destination'],
        updatecheck=updatecheck,
    )


def update(repo, *args, **kwargs):
    msg = b'``hg.update(...)` moved to `cmd_impls.update.update(...)`'
    repo.ui.deprecwarn(msg, b'7.3')
    return up_impl.update(*args, **kwargs)


def updatetotally(ui, *args, **kwargs):
    msg = b'``hg.updatetotally` moved to `cmd_impls.update.update_totally`'
    ui.deprecwarn(msg, b'7.3')
    return up_impl.update_totally(*args, **kwargs)


def clean(repo, *args, **kwargs):
    msg = b'``hg.clean(...)` moved to `cmd_impls.update.clean(...)`'
    repo.ui.deprecwarn(msg, b'7.3')
    return up_impl.clean(*args, **kwargs)


def merge(ctx, *args, **kwargs):
    msg = b'``hg.merge(...)` moved to `cmd_impls.update.merge(...)`'
    ctx.repo().ui.deprecwarn(msg, b'7.3')
    return up_impl.merge(*args, **kwargs)


def abortmerge(ui, *args, **kwargs):
    msg = b'``hg.abortmerge(...)` moved to `cmd_impls.update.abortmerge(...)`'
    ui.deprecwarn(msg, b'7.3')
    return up_impl.abort_merge(*args, **kwargs)


def outgoing(ui, *args, **kwargs):
    msg = b'``hg.outgoing(...)` moved to `cmd_impls.outgoing.outgoing(...)`'
    ui.deprecwarn(msg, b'7.3')
    return out_impl.outgoing(ui, *args, **kwargs)


def incoming(ui, *args, **kwargs):
    return inc_impl.incoming(ui, *args, **kwargs)


def verify(repo, level=None):
    """verify the consistency of a repository"""
    ret = verifymod.verify(repo, level=level)

    # Broken subrepo references in hidden csets don't seem worth worrying about,
    # since they can't be pushed/pulled, and --hidden can be used if they are a
    # concern.

    # pathto() is needed for -R case
    revs = repo.revs(
        b"filelog(%s)", util.pathto(repo.root, repo.getcwd(), b'.hgsubstate')
    )

    if revs:
        repo.ui.status(_(b'checking subrepo links\n'))
        for rev in revs:
            ctx = repo[rev]
            try:
                for subpath in ctx.substate:
                    try:
                        ret = (
                            ctx.sub(subpath, allowcreate=False).verify() or ret
                        )
                    except error.RepoError as e:
                        repo.ui.warn(b'%d: %s\n' % (rev, e))
            except Exception:
                repo.ui.warn(
                    _(b'.hgsubstate is corrupt in revision %s\n')
                    % short(ctx.node())
                )

    return ret


# Files of interest
# Used to check if the repository has changed looking at mtime and size of
# these files.
foi: list[tuple[str, bytes]] = [
    ('spath', b'00changelog.i'),
    ('spath', b'phaseroots'),  # ! phase can change content at the same size
    ('spath', b'obsstore'),
    ('path', b'bookmarks'),  # ! bookmark can change content at the same size
]


class cachedlocalrepo:
    """Holds a localrepository that can be cached and reused."""

    def __init__(self, repo):
        """Create a new cached repo from an existing repo.

        We assume the passed in repo was recently created. If the
        repo has changed between when it was created and when it was
        turned into a cache, it may not refresh properly.
        """
        assert isinstance(repo, localrepo.localrepository)
        self._repo = repo
        self._state, self.mtime = self._repostate()
        self._filtername = repo.filtername

    def fetch(self):
        """Refresh (if necessary) and return a repository.

        If the cached instance is out of date, it will be recreated
        automatically and returned.

        Returns a tuple of the repo and a boolean indicating whether a new
        repo instance was created.
        """
        # We compare the mtimes and sizes of some well-known files to
        # determine if the repo changed. This is not precise, as mtimes
        # are susceptible to clock skew and imprecise filesystems and
        # file content can change while maintaining the same size.

        state, mtime = self._repostate()
        if state == self._state:
            return self._repo, False

        repo = repo_factory.repository(self._repo.baseui, self._repo.url())
        if self._filtername:
            self._repo = repo.filtered(self._filtername)
        else:
            self._repo = repo.unfiltered()
        self._state = state
        self.mtime = mtime

        return self._repo, True

    def _repostate(self):
        state = []
        maxmtime = -1
        for attr, fname in foi:
            prefix = getattr(self._repo, attr)
            p = os.path.join(prefix, fname)
            try:
                st = os.stat(p)
            except OSError:
                st = os.stat(prefix)
            state.append((st[stat.ST_MTIME], st.st_size))
            maxmtime = max(maxmtime, st[stat.ST_MTIME])

        return tuple(state), maxmtime

    def copy(self):
        """Obtain a copy of this class instance.

        A new localrepository instance is obtained. The new instance should be
        completely independent of the original.
        """
        repo = repo_factory.repository(self._repo.baseui, self._repo.origroot)
        if self._filtername:
            repo = repo.filtered(self._filtername)
        else:
            repo = repo.unfiltered()
        c = cachedlocalrepo(repo)
        c._state = self._state
        c.mtime = self.mtime
        return c
