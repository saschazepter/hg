# merge_utils.update - collection of logic around updating the working copy
#
# Copyright 2006, 2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import typing
from typing import Optional

from ..i18n import _
from ..node import nullrev
from ..thirdparty import attr

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

from ..utils import stringutil
from ..dirstateutils import timestamp
from .. import (
    encoding,
    error,
    filemerge,
    merge_utils,
    pathutil,
    scmutil,
    subrepoutil,
    util,
    worker,
)


@attr.s(frozen=True)
class UpdateResult:
    updatedcount = attr.ib()
    mergedcount = attr.ib()
    removedcount = attr.ib()
    unresolvedcount = attr.ib()

    def isempty(self):
        return not (
            self.updatedcount
            or self.mergedcount
            or self.removedcount
            or self.unresolvedcount
        )


def apply_updates(
    repo,
    mresult: merge_utils.MergeResult,
    wctx,
    mctx,
    overwrite,
    wantfiledata,
    labels=None,
):
    """apply the merge action list to the working directory

    mresult is a MergeResult object representing result of the merge
    wctx is the working copy context
    mctx is the context to be merged into the working copy

    Return a tuple of (counts, filedata), where counts is a tuple
    (updated, merged, removed, unresolved) that describes how many
    files were affected by the update, and filedata is as described in
    batchget.
    """

    _prefetchfiles(repo, mctx, mresult)

    updated, merged, removed = 0, 0, 0
    ms = wctx.mergestate(clean=True)
    ms.start(wctx.p1().node(), mctx.node(), labels)

    for f, op in mresult.commitinfo.items():
        # the other side of filenode was choosen while merging, store this in
        # mergestate so that it can be reused on commit
        ms.addcommitinfo(f, op)

    num_no_op = mresult.len(merge_utils.MergeAction.NO_OP_ACTIONS)
    numupdates = mresult.len() - num_no_op
    progress = repo.ui.makeprogress(
        _(b'updating'), unit=_(b'files'), total=numupdates
    )

    if b'.hgsubstate' in mresult._actionmapping[merge_utils.ACTION_REMOVE]:
        subrepoutil.submerge(repo, wctx, mctx, wctx, overwrite, labels)

    # record path conflicts
    for f, args, msg in mresult.getactions(
        [merge_utils.ACTION_PATH_CONFLICT], sort=True
    ):
        f1, fo = args
        s = repo.ui.status
        s(
            _(
                b"%s: path conflict - a file or link has the same name as a "
                b"directory\n"
            )
            % f
        )
        if fo == b'l':
            s(_(b"the local file has been renamed to %s\n") % f1)
        else:
            s(_(b"the remote file has been renamed to %s\n") % f1)
        s(_(b"resolve manually then use 'hg resolve --mark %s'\n") % f)
        ms.addpathconflict(f, f1, fo)
        progress.increment(item=f)

    # When merging in-memory, we can't support worker processes, so set the
    # per-item cost at 0 in that case.
    cost = 0 if wctx.isinmemory() else 0.001

    # remove in parallel (must come before resolving path conflicts and getting)
    prog = worker.worker(
        repo.ui,
        cost,
        batchremove,
        (repo, wctx),
        list(mresult.getactions([merge_utils.ACTION_REMOVE], sort=True)),
    )
    for i, item in prog:
        progress.increment(step=i, item=item)
    removed = mresult.len((merge_utils.ACTION_REMOVE,))

    # resolve path conflicts (must come before getting)
    for f, args, msg in mresult.getactions(
        [merge_utils.ACTION_PATH_CONFLICT_RESOLVE], sort=True
    ):
        repo.ui.debug(b" %s: %s -> pr\n" % (f, msg))
        (f0, origf0) = args
        if wctx[f0].lexists():
            repo.ui.note(_(b"moving %s to %s\n") % (f0, f))
            wctx[f].audit()
            wctx[f].write(wctx.filectx(f0).data(), wctx.filectx(f0).flags())
            wctx[f0].remove()
        progress.increment(item=f)

    # get in parallel.
    threadsafe = repo.ui.configbool(
        b'experimental', b'worker.wdir-get-thread-safe'
    )
    prog = worker.worker(
        repo.ui,
        cost,
        batchget,
        (repo, mctx, wctx, wantfiledata),
        list(mresult.getactions([merge_utils.ACTION_GET], sort=True)),
        threadsafe=threadsafe,
        hasretval=True,
    )
    getfiledata = {}
    for final, res in prog:
        if final:
            getfiledata = res
        else:
            i, item = res
            progress.increment(step=i, item=item)

    if b'.hgsubstate' in mresult._actionmapping[merge_utils.ACTION_GET]:
        subrepoutil.submerge(repo, wctx, mctx, wctx, overwrite, labels)

    # forget (manifest only, just log it) (must come first)
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_FORGET,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> f\n" % (f, msg))
        progress.increment(item=f)

    # re-add (manifest only, just log it)
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_ADD,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> a\n" % (f, msg))
        progress.increment(item=f)

    # re-add/mark as modified (manifest only, just log it)
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_ADD_MODIFIED,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> am\n" % (f, msg))
        progress.increment(item=f)

    # keep (noop, just log it)
    for a in merge_utils.MergeAction.NO_OP_ACTIONS:
        for f, args, msg in mresult.getactions((a,), sort=True):
            repo.ui.debug(b" %s: %s -> %s\n" % (f, msg, a.__bytes__()))
            # no progress

    # directory rename, move local
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_DIR_RENAME_MOVE_LOCAL,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> dm\n" % (f, msg))
        progress.increment(item=f)
        f0, flags = args
        repo.ui.note(_(b"moving %s to %s\n") % (f0, f))
        wctx[f].audit()
        wctx[f].write(wctx.filectx(f0).data(), flags)
        wctx[f0].remove()

    # local directory rename, get
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_LOCAL_DIR_RENAME_GET,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> dg\n" % (f, msg))
        progress.increment(item=f)
        f0, flags = args
        repo.ui.note(_(b"getting %s to %s\n") % (f0, f))
        wctx[f].write(mctx.filectx(f0).data(), flags)

    # exec
    for f, args, msg in mresult.getactions(
        (merge_utils.ACTION_EXEC,), sort=True
    ):
        repo.ui.debug(b" %s: %s -> e\n" % (f, msg))
        progress.increment(item=f)
        (flags,) = args
        wctx[f].audit()
        wctx[f].setflags(b'l' in flags, b'x' in flags)

    moves = []

    # 'cd' and 'dc' actions are treated like other merge conflicts
    mergeactions = list(
        mresult.getactions(
            [
                merge_utils.ACTION_CHANGED_DELETED,
                merge_utils.ACTION_DELETED_CHANGED,
                merge_utils.ACTION_MERGE,
            ],
            sort=True,
        )
    )
    for f, args, msg in mergeactions:
        f1, f2, fa, move, anc = args
        if f == b'.hgsubstate':  # merged internally
            continue
        if f1 is None:
            fcl = filemerge.absentfilectx(wctx, fa)
        else:
            repo.ui.debug(b" preserving %s for resolve of %s\n" % (f1, f))
            fcl = wctx[f1]
        if f2 is None:
            fco = filemerge.absentfilectx(mctx, fa)
        else:
            fco = mctx[f2]
        actx = repo[anc]
        if fa in actx:
            fca = actx[fa]
        else:
            # TODO: move to absentfilectx
            fca = repo.filectx(f1, fileid=nullrev)
        ms.add(fcl, fco, fca, f)
        if f1 != f and move:
            moves.append(f1)

    # remove renamed files after safely stored
    for f in moves:
        if wctx[f].lexists():
            repo.ui.debug(b"removing %s\n" % f)
            wctx[f].audit()
            wctx[f].remove()

    # these actions updates the file
    updated = mresult.len(
        (
            merge_utils.ACTION_GET,
            merge_utils.ACTION_EXEC,
            merge_utils.ACTION_LOCAL_DIR_RENAME_GET,
            merge_utils.ACTION_DIR_RENAME_MOVE_LOCAL,
        )
    )

    try:
        for f, args, msg in mergeactions:
            repo.ui.debug(b" %s: %s -> m\n" % (f, msg))
            ms.addcommitinfo(f, {b'merged': b'yes'})
            progress.increment(item=f)
            if f == b'.hgsubstate':  # subrepo states need updating
                subrepoutil.submerge(
                    repo, wctx, mctx, wctx.ancestor(mctx), overwrite, labels
                )
                continue
            wctx[f].audit()
            ms.resolve(f, wctx)

    except error.InterventionRequired:
        # If the user has merge.on-failure=halt, catch the error and close the
        # merge state "properly".
        pass
    finally:
        ms.commit()

    unresolved = ms.unresolvedcount()

    msupdated, msmerged, msremoved = ms.counts()
    updated += msupdated
    merged += msmerged
    removed += msremoved

    extraactions = ms.actions()

    getfiledata = filter_ambiguous_files(repo, getfiledata)

    progress.complete()
    return (
        UpdateResult(updated, merged, removed, unresolved),
        getfiledata,
        extraactions,
    )


def _prefetchfiles(repo, ctx, mresult: merge_utils.MergeResult) -> None:
    """Invoke ``scmutil.prefetchfiles()`` for the files relevant to the dict
    of merge actions.  ``ctx`` is the context being merged in."""

    # Skipping 'a', 'am', 'f', 'r', 'dm', 'e', 'k', 'p' and 'pr', because they
    # don't touch the context to be merged in.  'cd' is skipped, because
    # changed/deleted never resolves to something from the remote side.
    files = mresult.files(
        [
            merge_utils.ACTION_GET,
            merge_utils.ACTION_DELETED_CHANGED,
            merge_utils.ACTION_LOCAL_DIR_RENAME_GET,
            merge_utils.ACTION_MERGE,
        ]
    )

    prefetch = scmutil.prefetchfiles
    matchfiles = scmutil.matchfiles
    prefetch(
        repo,
        [
            (
                ctx.rev(),
                matchfiles(repo, files),
            )
        ],
    )


# filename -> (mode, size, timestamp)
FileData = dict[bytes, Optional[tuple[int, int, Optional[timestamp.timestamp]]]]


def filter_ambiguous_files(repo, file_data: FileData) -> FileData:
    """We've gathered "cache" information for the clean files while updating
    them: their mtime, size and mode.

    At the time this comment is written, there are various issues with how we
    gather the `mode` and `mtime` information (see the comment in `batchget`).

    We are going to smooth one of these issues here: mtime ambiguity.

    i.e. even if the mtime gathered during `batchget` was correct[1] a change
    happening right after it could change the content while keeping
    the same mtime[2].

    When we reach the current code, the "on disk" part of the update operation
    is finished. We still assume that no other process raced that "on disk"
    part, but we want to at least prevent later file changes to alter the
    contents of the file right after the update operation so quickly that the
    same mtime is recorded for the operation.

    To prevent such ambiguities from happenning, we will do (up to) two things:
        - wait until the filesystem clock has ticked
        - only keep the "file data" for files with mtimes that are strictly in
          the past, i.e. whose mtime is strictly lower than the current time.

    We only wait for the system clock to tick if using dirstate-v2, since v1
    only has second-level granularity and waiting for a whole second is
    too much of a penalty in the general case.

    Although we're assuming that people running dirstate-v2 on Linux
    don't have a second-granularity FS (with the exclusion of NFS), users
    can be surprising, and at some point in the future, dirstate-v2 will become
    the default. To that end, we limit the wait time to 100ms and fall back
    to the filtering method in case of a timeout.

    +------------+------+--------------+
    |   version  | wait | filter level |
    +------------+------+--------------+
    |     V1     | No   | Second       |
    |     V2     | Yes  | Nanosecond   |
    | V2-slow-fs | No   | Second       |
    +------------+------+--------------+

    This protects us from race conditions from operations that could run right
    after this one, especially other Mercurial operations that could be waiting
    for the wlock to touch files contents and the dirstate.

    In an ideal world, we could only get reliable information in `getfiledata`
    (from `getbatch`), however this filtering approach has been a successful
    compromise for many years. A patch series of the linux kernel might change
    this in 6.12³.

    At the time this comment is written, not using any "cache" file data at all
    here would not be viable, as it would result is a very large amount of work
    (equivalent to the previous `hg update` during the next status after an
    update).

    [1] the current code cannot grantee that the `mtime` and `mode`
    are correct, but the result is "okay in practice".
    (see the comment in `batchget`)

    [2] using nano-second precision can greatly help here because it makes the
    "different write with same mtime" issue virtually vanish. However,
    dirstate v1 cannot store such precision and a bunch of python-runtime,
    operating-system and filesystem parts do not provide us with such
    precision, so we have to operate as if it wasn't available.

    [3] https://lore.kernel.org/all/20241002-mgtime-v10-8-d1c4717f5284@kernel.org
    """
    ambiguous_mtime: FileData = {}
    dirstate_v2 = repo.dirstate._use_dirstate_v2
    fs_now_result = None
    fast_enough_fs = True
    if dirstate_v2:
        fstype = util.getfstype(repo.vfs.base)
        # Exclude NFS right off the bat
        fast_enough_fs = fstype != b'nfs'
        if fstype is not None and fast_enough_fs:
            fs_now_result = timestamp.wait_until_fs_tick(repo.vfs)

    if fs_now_result is None:
        try:
            now = timestamp.get_fs_now(repo.vfs)
            fs_now_result = (now, False)
        except OSError:
            pass

    if fs_now_result is None:
        # we can't write to the FS, so we won't actually update
        # the dirstate content anyway, let another operation fail later.
        return file_data
    else:
        now, timed_out = fs_now_result
        if timed_out:
            fast_enough_fs = False
        for f, m in file_data.items():
            if m is not None:
                reliable = timestamp.make_mtime_reliable(m[2], now)
                if reliable is None or (
                    reliable[2] and (not dirstate_v2 or not fast_enough_fs)
                ):
                    # Either it's not reliable, or it's second ambiguous
                    # and we're in dirstate-v1 or in a slow fs, so discard
                    # the mtime.
                    ambiguous_mtime[f] = (m[0], m[1], None)
                elif reliable[2]:
                    # We need to remember that this time is "second ambiguous"
                    # otherwise the next status might miss a subsecond change
                    # if its "stat" doesn't provide nanoseconds.
                    #
                    # TODO make osutil.c understand nanoseconds when possible
                    # (see timestamp.py for the same note)
                    ambiguous_mtime[f] = (m[0], m[1], reliable)
        for f, m in ambiguous_mtime.items():
            file_data[f] = m
    return file_data


def _getcwd():
    try:
        return encoding.getcwd()
    except FileNotFoundError:
        return None


def batchremove(repo, wctx, actions):
    """apply removes to the working directory

    yields tuples for progress updates
    """
    verbose = repo.ui.verbose
    cwd = _getcwd()
    i = 0
    for f, args, msg in actions:
        repo.ui.debug(b" %s: %s -> r\n" % (f, msg))
        if verbose:
            repo.ui.note(_(b"removing %s\n") % f)
        wctx[f].audit()
        try:
            wctx[f].remove(ignoremissing=True)
        except OSError as inst:
            repo.ui.warn(
                _(b"update failed to remove %s: %s!\n")
                % (f, stringutil.forcebytestr(inst.strerror))
            )
        if i == 100:
            yield i, f
            i = 0
        i += 1
    if i > 0:
        yield i, f

    if cwd and not _getcwd():
        # cwd was removed in the course of removing files; print a helpful
        # warning.
        repo.ui.warn(
            _(
                b"current directory was removed\n"
                b"(consider changing to repo root: %s)\n"
            )
            % repo.root
        )


def batchget(repo, mctx, wctx, wantfiledata, actions):
    """apply gets to the working directory

    mctx is the context to get from

    Yields arbitrarily many (False, tuple) for progress updates, followed by
    exactly one (True, filedata). When wantfiledata is false, filedata is an
    empty dict. When wantfiledata is true, filedata[f] is a triple (mode, size,
    mtime) of the file f written for each action.
    """
    filedata = {}
    verbose = repo.ui.verbose
    fctx = mctx.filectx
    ui = repo.ui
    i = 0
    with repo.wvfs.backgroundclosing(ui, expectedcount=len(actions)):
        for f, (flags, backup), msg in actions:
            repo.ui.debug(b" %s: %s -> g\n" % (f, msg))
            if verbose:
                repo.ui.note(_(b"getting %s\n") % f)

            if backup:
                # If a file or directory exists with the same name, back that
                # up.  Otherwise, look to see if there is a file that conflicts
                # with a directory this file is in, and if so, back that up.
                conflicting = f
                if not repo.wvfs.lexists(f):
                    for p in pathutil.finddirs(f):
                        if repo.wvfs.isfileorlink(p):
                            conflicting = p
                            break
                if repo.wvfs.lexists(conflicting):
                    orig = scmutil.backuppath(ui, repo, conflicting)
                    util.rename(repo.wjoin(conflicting), orig)
            wfctx = wctx[f]
            wfctx.clearunknown()
            atomictemp = ui.configbool(b"experimental", b"update.atomic-file")
            size = wfctx.write(
                fctx(f).data(),
                flags,
                backgroundclose=True,
                atomictemp=atomictemp,
            )
            if wantfiledata:
                # XXX note that there is a race window between the time we
                # write the clean data into the file and we stats it. So another
                # writing process meddling with the file content right after we
                # wrote it could cause bad stat data to be gathered.
                #
                # They are 2 data we gather here
                # - the mode:
                #       That we actually just wrote, we should not need to read
                #       it from disk, (except not all mode might have survived
                #       the disk round-trip, which is another issue: we should
                #       not depends on this)
                # - the mtime,
                #       On system that support nanosecond precision, the mtime
                #       could be accurate enough to tell the two writes appart.
                #       However gathering it in a racy way make the mtime we
                #       gather "unreliable".
                #
                # (note: we get the size from the data we write, which is sane)
                #
                # So in theory the data returned here are fully racy, but in
                # practice "it works mostly fine".
                #
                # Do not be surprised if you end up reading this while looking
                # for the causes of some buggy status. Feel free to improve
                # this in the future, but we cannot simply stop gathering
                # information. Otherwise `hg status` call made after a large `hg
                # update` runs would have to redo a similar amount of work to
                # restore and compare all files content.
                s = wfctx.lstat()
                mode = s.st_mode
                mtime = timestamp.mtime_of(s)
                # for dirstate.update_file's parentfiledata argument:
                filedata[f] = (mode, size, mtime)
            if i == 100:
                yield False, (i, f)
                i = 0
            i += 1
    if i > 0:
        yield False, (i, f)
    yield True, filedata
