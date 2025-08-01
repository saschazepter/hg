# outgoing.py - high level implementation for outgoing
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import posixpath

from ..i18n import _

from .. import (
    cmdutil,
    discovery,
    graphmod,
    logcmdutil,
    scmutil,
)
from ..repo import factory as repo_factory
from ..utils import (
    urlutil,
)


def _outgoing_filter(repo, revs, opts):
    """apply revision filtering/ordering option for outgoing"""
    limit = logcmdutil.getlimit(opts)
    no_merges = opts.get(b'no_merges')
    if opts.get(b'newest_first'):
        revs.reverse()
    if limit is None and not no_merges:
        yield from revs
        return

    count = 0
    cl = repo.changelog
    for n in revs:
        if limit is not None and count >= limit:
            break
        parents = [p for p in cl.parents(n) if p != repo.nullid]
        if no_merges and len(parents) == 2:
            continue
        count += 1
        yield n


def _outgoing_recurse(ui, repo, dests, opts):
    ret = 1
    if opts.get(b'subrepos'):
        ctx = repo[None]
        for subpath in sorted(ctx.substate):
            sub = ctx.sub(subpath)
            ret = min(ret, sub.outgoing(ui, dests, opts))
    return ret


def display_outgoing_revs(ui, repo, o, opts):
    # make sure this is ordered by revision number
    cl = repo.changelog
    o.sort(key=cl.rev)
    if opts.get(b'graph'):
        revdag = logcmdutil.graphrevs(repo, o, opts)
        ui.pager(b'outgoing')
        displayer = logcmdutil.changesetdisplayer(ui, repo, opts, buffered=True)
        logcmdutil.displaygraph(
            ui, repo, revdag, displayer, graphmod.asciiedges
        )
    else:
        ui.pager(b'outgoing')
        displayer = logcmdutil.changesetdisplayer(ui, repo, opts)
        for n in _outgoing_filter(repo, o, opts):
            displayer.show(repo[n])
            displayer.close()


_no_subtoppath = object()


def outgoing(ui, repo, dests, opts, subpath=None):
    if opts.get(b'graph'):
        logcmdutil.checkunsupportedgraphflags([], opts)
    ret = 1
    for path in urlutil.get_push_paths(repo, ui, dests):
        dest = path.loc
        prev_subtopath = getattr(repo, "_subtoppath", _no_subtoppath)
        try:
            repo._subtoppath = dest
            if subpath is not None:
                subpath = urlutil.url(subpath)
                if subpath.isabs():
                    dest = bytes(subpath)
                else:
                    p = urlutil.url(dest)
                    if p.islocal():
                        normpath = os.path.normpath
                    else:
                        normpath = posixpath.normpath
                    p.path = normpath(b'%s/%s' % (p.path, subpath))
                    dest = bytes(p)
            branches = path.branch, opts.get(b'branch') or []

            ui.status(_(b'comparing with %s\n') % urlutil.hidepassword(dest))
            revs, checkout = urlutil.add_branch_revs(
                repo, repo, branches, opts.get(b'rev')
            )
            if revs:
                revs = [
                    repo[rev].node() for rev in logcmdutil.revrange(repo, revs)
                ]

            other = repo_factory.peer(repo, opts, dest)
            try:
                outgoing = discovery.findcommonoutgoing(
                    repo, other, revs, force=opts.get(b'force')
                )
                o = outgoing.missing
                if not o:
                    scmutil.nochangesfound(repo.ui, repo, outgoing.excluded)
                else:
                    ret = 0
                    display_outgoing_revs(ui, repo, o, opts)

                cmdutil.outgoinghooks(ui, repo, other, opts, o)

                # path.loc is used instead of dest because what we need to pass
                # is the destination of the repository containing the
                # subrepositories and not the destination of the current
                # subrepository being processed. It will be used to discover
                # subrepositories paths when using relative paths do map them
                ret = min(ret, _outgoing_recurse(ui, repo, (path.loc,), opts))
            except:  # re-raises
                raise
            finally:
                other.close()
        finally:
            if prev_subtopath is _no_subtoppath:
                del repo._subtoppath
            else:
                repo._subtoppath = prev_subtopath
    return ret
