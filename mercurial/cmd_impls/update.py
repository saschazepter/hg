# cmdutil.py - help for command processing in mercurial
#
# Copyright 2005-2025 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from ..i18n import _

from .. import (
    bookmarks,
    destutil,
    merge as mergemod,
    mergestate as mergestatemod,
    scmutil,
)

_VALID_UPDATECHECKS = {
    mergemod.UPDATECHECK_ABORT,
    mergemod.UPDATECHECK_NONE,
    mergemod.UPDATECHECK_LINEAR,
    mergemod.UPDATECHECK_NO_CONFLICT,
}


def update(repo, node, quietempty=False, updatecheck=None):
    """update the working directory to node"""
    stats = mergemod.update(repo[node], updatecheck=updatecheck)
    show_stats(repo, stats, quietempty)
    if stats.unresolvedcount:
        repo.ui.status(_(b"use 'hg resolve' to retry unresolved file merges\n"))
    return stats.unresolvedcount > 0


# naming conflict
_update = update


_VALID_UPDATECHECKS = {
    mergemod.UPDATECHECK_ABORT,
    mergemod.UPDATECHECK_NONE,
    mergemod.UPDATECHECK_LINEAR,
    mergemod.UPDATECHECK_NO_CONFLICT,
}


def update_totally(ui, repo, checkout, brev, clean=False, updatecheck=None):
    """Update the working directory with extra care for non-file components

    This takes care of non-file components below:

    :bookmark: might be advanced or (in)activated

    This takes arguments below:

    :checkout: to which revision the working directory is updated
    :brev: a name, which might be a bookmark to be activated after updating
    :clean: whether changes in the working directory can be discarded
    :updatecheck: how to deal with a dirty working directory

    Valid values for updatecheck are the UPDATECHECK_* constants
    defined in the merge module. Passing `None` will result in using the
    configured default.

     * ABORT: abort if the working directory is dirty
     * NONE: don't check (merge working directory changes into destination)
     * LINEAR: check that update is linear before merging working directory
               changes into destination
     * NO_CONFLICT: check that the update does not result in file merges

    This returns whether conflict is detected at updating or not.
    """
    if updatecheck is None:
        updatecheck = ui.config(b'commands', b'update.check')
        if updatecheck not in _VALID_UPDATECHECKS:
            # If not configured, or invalid value configured
            updatecheck = mergemod.UPDATECHECK_LINEAR
    if updatecheck not in _VALID_UPDATECHECKS:
        raise ValueError(
            r'Invalid updatecheck value %r (can accept %r)'
            % (updatecheck, _VALID_UPDATECHECKS)
        )
    with repo.wlock():
        movemarkfrom = None
        warndest = False
        if checkout is None:
            updata = destutil.destupdate(repo, clean=clean)
            checkout, movemarkfrom, brev = updata
            warndest = True

        if clean:
            ret = _clean(repo, checkout)
        else:
            if updatecheck == mergemod.UPDATECHECK_ABORT:
                scmutil.bail_if_changed(repo, merge=False)
                updatecheck = mergemod.UPDATECHECK_NONE
            ret = _update(repo, checkout, updatecheck=updatecheck)

        if not ret and movemarkfrom:
            if movemarkfrom == repo[b'.'].node():
                pass  # no-op update
            elif bookmarks.update(repo, [movemarkfrom], repo[b'.'].node()):
                b = ui.label(repo._activebookmark, b'bookmarks.active')
                ui.status(_(b"updating bookmark %s\n") % b)
            else:
                # this can happen with a non-linear update
                b = ui.label(repo._activebookmark, b'bookmarks')
                ui.status(_(b"(leaving bookmark %s)\n") % b)
                bookmarks.deactivate(repo)
        elif brev in repo._bookmarks:
            if brev != repo._activebookmark:
                b = ui.label(brev, b'bookmarks.active')
                ui.status(_(b"(activating bookmark %s)\n") % b)
            bookmarks.activate(repo, brev)
        elif brev:
            if repo._activebookmark:
                b = ui.label(repo._activebookmark, b'bookmarks')
                ui.status(_(b"(leaving bookmark %s)\n") % b)
            bookmarks.deactivate(repo)

        if warndest:
            destutil.statusotherdests(ui, repo)

    return ret


def show_stats(repo, stats, quietempty=False):
    if quietempty and stats.isempty():
        return
    repo.ui.status(
        _(
            b"%d files updated, %d files merged, "
            b"%d files removed, %d files unresolved\n"
        )
        % (
            stats.updatedcount,
            stats.mergedcount,
            stats.removedcount,
            stats.unresolvedcount,
        )
    )


# name conflict in clean(...)
_show_stats = show_stats


def clean(repo, node, show_stats=True, quietempty=False):
    """forcibly switch the working directory to node, clobbering changes"""
    stats = mergemod.clean_update(repo[node])
    assert stats.unresolvedcount == 0
    if show_stats:
        _show_stats(repo, stats, quietempty)
    return False


# naming conflict
_clean = clean


def merge(
    ctx,
    force=False,
    remind=True,
    labels=None,
):
    """Branch merge with node, resolving changes. Return true if any
    unresolved conflicts."""
    repo = ctx.repo()
    stats = mergemod.merge(ctx, force=force, labels=labels)
    show_stats(repo, stats)
    if stats.unresolvedcount:
        repo.ui.status(
            _(
                b"use 'hg resolve' to retry unresolved file merges "
                b"or 'hg merge --abort' to abandon\n"
            )
        )
    elif remind:
        repo.ui.status(_(b"(branch merge, don't forget to commit)\n"))
    return stats.unresolvedcount > 0


def abort_merge(ui, repo):
    ms = mergestatemod.mergestate.read(repo)
    if ms.active():
        # there were conflicts
        node = ms.localctx.hex()
    else:
        # there were no conficts, mergestate was not stored
        node = repo[b'.'].hex()

    repo.ui.status(_(b"aborting the merge, updating back to %s\n") % node[:12])
    stats = mergemod.clean_update(repo[node])
    assert stats.unresolvedcount == 0
    show_stats(repo, stats)
