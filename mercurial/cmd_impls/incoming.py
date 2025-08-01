# incoming.py - high level implementation for incoming
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
# Copyright 2006 Vadim Gelfer <vadim.gelfer@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import posixpath

from ..i18n import _

from .. import (
    bundlerepo,
    error,
    logcmdutil,
)
from ..repo import factory as repo_factory
from ..utils import (
    urlutil,
)


def _incoming(
    displaychlist,
    subreporecurse,
    ui,
    repo,
    source,
    opts,
    buffered=False,
    subpath=None,
):
    """
    Helper for incoming / gincoming.
    displaychlist gets called with
        (remoterepo, incomingchangesetlist, displayer) parameters,
    and is supposed to contain only code that can't be unified.
    """
    srcs = urlutil.get_pull_paths(repo, ui, [source])
    srcs = list(srcs)
    if len(srcs) != 1:
        msg = _(b'for now, incoming supports only a single source, %d provided')
        msg %= len(srcs)
        raise error.Abort(msg)
    path = srcs[0]
    if subpath is None:
        peer_path = path
        url = path.loc
    else:
        # XXX path: we are losing the `path` object here. Keeping it would be
        # valuable. For example as a "variant" as we do for pushes.
        subpath = urlutil.url(subpath)
        if subpath.isabs():
            peer_path = url = bytes(subpath)
        else:
            p = urlutil.url(path.loc)
            if p.islocal():
                normpath = os.path.normpath
            else:
                normpath = posixpath.normpath
            p.path = normpath(b'%s/%s' % (p.path, subpath))
            peer_path = url = bytes(p)
    other = repo_factory.peer(repo, opts, peer_path)
    cleanupfn = other.close
    try:
        ui.status(_(b'comparing with %s\n') % urlutil.hidepassword(url))
        branches = (path.branch, opts.get(b'branch', []))
        revs, checkout = urlutil.add_branch_revs(
            repo,
            other,
            branches,
            opts.get(b'rev'),
        )

        if revs:
            revs = [other.lookup(rev) for rev in revs]
        other, chlist, cleanupfn = bundlerepo.getremotechanges(
            ui, repo, other, revs, opts.get(b"bundle"), opts.get(b"force")
        )

        if not chlist:
            ui.status(_(b"no changes found\n"))
            return subreporecurse()
        ui.pager(b'incoming')
        displayer = logcmdutil.changesetdisplayer(
            ui, other, opts, buffered=buffered
        )
        displaychlist(other, chlist, displayer)
        displayer.close()
    finally:
        cleanupfn()
    subreporecurse()
    return 0  # exit code is zero since we found incoming changes


def incoming(ui, repo, source, opts, subpath=None):
    def subreporecurse():
        ret = 1
        if opts.get(b'subrepos'):
            ctx = repo[None]
            for subpath in sorted(ctx.substate):
                sub = ctx.sub(subpath)
                ret = min(ret, sub.incoming(ui, source, opts))
        return ret

    def display(other, chlist, displayer):
        limit = logcmdutil.getlimit(opts)
        if opts.get(b'newest_first'):
            chlist.reverse()
        count = 0
        for n in chlist:
            if limit is not None and count >= limit:
                break
            parents = [
                p for p in other.changelog.parents(n) if p != repo.nullid
            ]
            if opts.get(b'no_merges') and len(parents) == 2:
                continue
            count += 1
            displayer.show(other[n])

    return _incoming(
        display, subreporecurse, ui, repo, source, opts, subpath=subpath
    )
