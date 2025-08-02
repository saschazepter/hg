# narrow.working_copy - logic related to narrow's impact on the working copy
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from ..i18n import _
from .. import (
    match as matchmod,
    merge,
    mergestate as mergestatemod,
    narrowspec,
    scmutil,
    sparse,
)


# These two are extracted for extensions (specifically for Google's CitC file
# system)
def _deletecleanfiles(repo, files):
    for f in files:
        repo.wvfs.unlinkpath(f)


def _writeaddedfiles(repo, pctx, files):
    mresult = merge.mergeresult()
    mf = repo[b'.'].manifest()
    for f in files:
        if not repo.wvfs.exists(f):
            mresult.addfile(
                f,
                mergestatemod.ACTION_GET,
                (mf.flags(f), False),
                b"narrowspec updated",
            )
    merge.applyupdates(
        repo,
        mresult,
        wctx=repo[None],
        mctx=repo[b'.'],
        overwrite=False,
        wantfiledata=False,
    )


def update_working_copy(repo, assumeclean=False):
    """updates the working copy and dirstate from the store narrowspec

    When assumeclean=True, files that are not known to be clean will also
    be deleted. It is then up to the caller to make sure they are clean.
    """
    old = repo._pending_narrow_pats_dirstate
    if old is None:
        oldspec = repo.vfs.tryread(narrowspec.DIRSTATE_FILENAME)
        oldincludes, oldexcludes = narrowspec.parseconfig(repo.ui, oldspec)
    else:
        oldincludes, oldexcludes = old
    newincludes, newexcludes = repo.narrowpats
    repo._updatingnarrowspec = True

    match = narrowspec.match
    oldmatch = match(repo.root, include=oldincludes, exclude=oldexcludes)
    newmatch = match(repo.root, include=newincludes, exclude=newexcludes)
    addedmatch = matchmod.differencematcher(newmatch, oldmatch)
    removedmatch = matchmod.differencematcher(oldmatch, newmatch)

    assert repo.currentwlock() is not None
    ds = repo.dirstate
    with ds.running_status(repo):
        lookup, status, _mtime_boundary = ds.status(
            removedmatch,
            subrepos=[],
            ignored=True,
            clean=True,
            unknown=True,
        )
    trackeddirty = status.modified + status.added
    clean = status.clean
    if assumeclean:
        clean.extend(lookup)
    else:
        trackeddirty.extend(lookup)
    _deletecleanfiles(repo, clean)
    uipathfn = scmutil.getuipathfn(repo)
    for f in sorted(trackeddirty):
        repo.ui.status(
            _(b'not deleting possibly dirty file %s\n') % uipathfn(f)
        )
    for f in sorted(status.unknown):
        repo.ui.status(_(b'not deleting unknown file %s\n') % uipathfn(f))
    for f in sorted(status.ignored):
        repo.ui.status(_(b'not deleting ignored file %s\n') % uipathfn(f))
    for f in clean + trackeddirty:
        ds.update_file(f, p1_tracked=False, wc_tracked=False)

    pctx = repo[b'.']

    # only update added files that are in the sparse checkout
    addedmatch = matchmod.intersectmatchers(addedmatch, sparse.matcher(repo))
    newfiles = [f for f in pctx.manifest().walk(addedmatch) if f not in ds]
    for f in newfiles:
        ds.update_file(f, p1_tracked=True, wc_tracked=True, possibly_dirty=True)
    _writeaddedfiles(repo, pctx, newfiles)
    repo._updatingnarrowspec = False
