# merge.py - directory-level update/merge handling for Mercurial
#
# Copyright 2006, 2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import struct
from typing import Iterator

from .i18n import _
from .node import nullrev

from . import (
    copies,
    error,
    filemerge,
    match as matchmod,
    merge_utils,
    mergestate as mergestatemod,
    obsutil,
    pathutil,
    policy,
    pycompat,
    scmutil,
    sparse,
    util,
)
from .merge_utils import (
    update as update_util,
)

rust_update_mod = policy.importrust("update")

_pack = struct.pack
_unpack = struct.unpack

# updated by fsmonitor when it load. Used to detect the extension presence.
_fs_monitor_loaded = False


def _getcheckunknownconfig(repo, section, name):
    config = repo.ui.config(section, name)
    valid = [b'abort', b'ignore', b'warn']
    if config not in valid:
        validstr = b', '.join([b"'" + v + b"'" for v in valid])
        msg = _(b"%s.%s not valid ('%s' is none of %s)")
        msg %= (section, name, config, validstr)
        raise error.ConfigError(msg)
    return config


def _checkunknownfile(dirstate, wvfs, dircache, wctx, mctx, f, f2=None):
    if wctx.isinmemory():
        # Nothing to do in IMM because nothing in the "working copy" can be an
        # unknown file.
        #
        # Note that we should bail out here, not in ``_checkunknownfiles()``,
        # because that function does other useful work.
        return False

    if f2 is None:
        f2 = f
    return (
        wvfs.isfileorlink_checkdir(dircache, f)
        and dirstate.normalize(f) not in dirstate
        and mctx[f2].cmp(wctx[f])
    )


class _unknowndirschecker:
    """
    Look for any unknown files or directories that may have a path conflict
    with a file.  If any path prefix of the file exists as a file or link,
    then it conflicts.  If the file itself is a directory that contains any
    file that is not tracked, then it conflicts.

    Returns the shortest path at which a conflict occurs, or None if there is
    no conflict.
    """

    def __init__(self):
        # A set of paths known to be good.  This prevents repeated checking of
        # dirs.  It will be updated with any new dirs that are checked and found
        # to be safe.
        self._unknowndircache = set()

        # A set of paths that are known to be absent.  This prevents repeated
        # checking of subdirectories that are known not to exist. It will be
        # updated with any new dirs that are checked and found to be absent.
        self._missingdircache = set()

    def __call__(self, repo, wctx, f):
        if wctx.isinmemory():
            # Nothing to do in IMM for the same reason as ``_checkunknownfile``.
            return False

        # Check for path prefixes that exist as unknown files.
        for p in reversed(list(pathutil.finddirs(f))):
            if p in self._missingdircache:
                return
            if p in self._unknowndircache:
                continue
            if repo.wvfs.audit.check(p):
                if (
                    repo.wvfs.isfileorlink(p)
                    and repo.dirstate.normalize(p) not in repo.dirstate
                ):
                    return p
                if not repo.wvfs.lexists(p):
                    self._missingdircache.add(p)
                    return
                self._unknowndircache.add(p)

        # Check if the file conflicts with a directory containing unknown files.
        if repo.wvfs.audit.check(f) and repo.wvfs.isdir(f):
            # Does the directory contain any files that are not in the dirstate?
            for p, dirs, files in repo.wvfs.walk(f):
                for fn in files:
                    relf = util.pconvert(repo.wvfs.reljoin(p, fn))
                    relf = repo.dirstate.normalize(relf, isknown=True)
                    if relf not in repo.dirstate:
                        return f
        return None


def _checkunknownfiles(
    repo,
    wctx,
    mctx,
    force,
    mresult: merge_utils.MergeResult,
    mergeforce,
):
    """
    Considers any actions that care about the presence of conflicting unknown
    files. For some actions, the result is to abort; for others, it is to
    choose a different action.
    """
    fileconflicts = set()
    pathconflicts = set()
    warnconflicts = set()
    abortconflicts = set()
    unknownconfig = _getcheckunknownconfig(repo, b'merge', b'checkunknown')
    ignoredconfig = _getcheckunknownconfig(repo, b'merge', b'checkignored')
    pathconfig = repo.ui.configbool(
        b'experimental', b'merge.checkpathconflicts'
    )
    dircache = dict()
    dirstate = repo.dirstate
    wvfs = repo.wvfs
    # wouldn't it be easier to loop over unknown files (and dirs)?

    if not force:

        def collectconflicts(conflicts, config):
            if config == b'abort':
                abortconflicts.update(conflicts)
            elif config == b'warn':
                warnconflicts.update(conflicts)

        checkunknowndirs = _unknowndirschecker()
        for f in mresult.files(
            (
                mergestatemod.ACTION_CREATED,
                mergestatemod.ACTION_DELETED_CHANGED,
            )
        ):
            if _checkunknownfile(dirstate, wvfs, dircache, wctx, mctx, f):
                fileconflicts.add(f)
            elif pathconfig and f not in wctx:
                path = checkunknowndirs(repo, wctx, f)
                if path is not None:
                    pathconflicts.add(path)
        for f, args, msg in mresult.getactions(
            [mergestatemod.ACTION_LOCAL_DIR_RENAME_GET]
        ):
            if _checkunknownfile(
                dirstate, wvfs, dircache, wctx, mctx, f, args[0]
            ):
                fileconflicts.add(f)

        allconflicts = fileconflicts | pathconflicts
        ignoredconflicts = {c for c in allconflicts if repo.dirstate._ignore(c)}
        unknownconflicts = allconflicts - ignoredconflicts
        collectconflicts(ignoredconflicts, ignoredconfig)
        collectconflicts(unknownconflicts, unknownconfig)
    else:
        for f, args, msg in list(
            mresult.getactions([mergestatemod.ACTION_CREATED_MERGE])
        ):
            fl2, anc = args
            different = _checkunknownfile(
                dirstate, wvfs, dircache, wctx, mctx, f
            )
            if repo.dirstate._ignore(f):
                config = ignoredconfig
            else:
                config = unknownconfig

            # The behavior when force is True is described by this table:
            #  config  different  mergeforce  |    action    backup
            #    *         n          *       |      get        n
            #    *         y          y       |     merge       -
            #   abort      y          n       |     merge       -   (1)
            #   warn       y          n       |  warn + get     y
            #  ignore      y          n       |      get        y
            #
            # (1) this is probably the wrong behavior here -- we should
            #     probably abort, but some actions like rebases currently
            #     don't like an abort happening in the middle of
            #     merge.update.
            if not different:
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_GET,
                    (fl2, False),
                    b'remote created',
                )
            elif mergeforce or config == b'abort':
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_MERGE,
                    (f, f, None, False, anc),
                    b'remote differs from untracked local',
                )
            elif config == b'abort':
                abortconflicts.add(f)
            else:
                if config == b'warn':
                    warnconflicts.add(f)
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_GET,
                    (fl2, True),
                    b'remote created',
                )

    for f in sorted(abortconflicts):
        warn = repo.ui.warn
        if f in pathconflicts:
            if repo.wvfs.isfileorlink(f):
                warn(_(b"%s: untracked file conflicts with directory\n") % f)
            else:
                warn(_(b"%s: untracked directory conflicts with file\n") % f)
        else:
            warn(_(b"%s: untracked file differs\n") % f)
    if abortconflicts:
        raise error.StateError(
            _(
                b"untracked files in working directory "
                b"differ from files in requested revision"
            )
        )

    for f in sorted(warnconflicts):
        if repo.wvfs.isfileorlink(f):
            repo.ui.warn(_(b"%s: replacing untracked file\n") % f)
        else:
            repo.ui.warn(_(b"%s: replacing untracked files in directory\n") % f)

    def transformargs(f, args):
        backup = (
            f in fileconflicts
            or pathconflicts
            and (
                f in pathconflicts
                or any(p in pathconflicts for p in pathutil.finddirs(f))
            )
        )
        (flags,) = args
        return (flags, backup)

    mresult.mapaction(
        mergestatemod.ACTION_CREATED, mergestatemod.ACTION_GET, transformargs
    )


def _forgetremoved(
    wctx,
    mctx,
    branchmerge,
    mresult: merge_utils.MergeResult,
) -> None:
    """
    Forget removed files

    If we're jumping between revisions (as opposed to merging), and if
    neither the working directory nor the target rev has the file,
    then we need to remove it from the dirstate, to prevent the
    dirstate from listing the file when it is no longer in the
    manifest.

    If we're merging, and the other revision has removed a file
    that is not present in the working directory, we need to mark it
    as removed.
    """

    m = mergestatemod.ACTION_FORGET
    if branchmerge:
        m = mergestatemod.ACTION_REMOVE
    for f in wctx.deleted():
        if f not in mctx:
            mresult.addfile(f, m, None, b"forget deleted")

    if not branchmerge:
        for f in wctx.removed():
            if f not in mctx:
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_FORGET,
                    None,
                    b"forget removed",
                )


def _checkcollision(
    repo,
    wmf,
    mresult: merge_utils.MergeResult | None,
) -> None:
    """
    Check for case-folding collisions.
    """
    # If the repo is narrowed, filter out files outside the narrowspec.
    narrowmatch = repo.narrowmatch()
    if not narrowmatch.always():
        pmmf = set(wmf.walk(narrowmatch))
        if mresult:
            for f in list(mresult.files()):
                if not narrowmatch(f):
                    mresult.removefile(f)
    else:
        # build provisional merged manifest up
        pmmf = set(wmf)

    if mresult:
        # KEEP and EXEC are no-op
        for f in mresult.files(
            (
                mergestatemod.ACTION_ADD,
                mergestatemod.ACTION_ADD_MODIFIED,
                mergestatemod.ACTION_FORGET,
                mergestatemod.ACTION_GET,
                mergestatemod.ACTION_CHANGED_DELETED,
                mergestatemod.ACTION_DELETED_CHANGED,
            )
        ):
            pmmf.add(f)
        for f in mresult.files((mergestatemod.ACTION_REMOVE,)):
            pmmf.discard(f)
        for f, args, msg in mresult.getactions(
            [mergestatemod.ACTION_DIR_RENAME_MOVE_LOCAL]
        ):
            f2, flags = args
            pmmf.discard(f2)
            pmmf.add(f)
        for f in mresult.files((mergestatemod.ACTION_LOCAL_DIR_RENAME_GET,)):
            pmmf.add(f)
        for f, args, msg in mresult.getactions([mergestatemod.ACTION_MERGE]):
            f1, f2, fa, move, anc = args
            if move:
                pmmf.discard(f1)
            pmmf.add(f)

    # check case-folding collision in provisional merged manifest
    foldmap = {}
    for f in pmmf:
        fold = util.normcase(f)
        if fold in foldmap:
            msg = _(b"case-folding collision between %s and %s")
            msg %= (f, foldmap[fold])
            raise error.StateError(msg)
        foldmap[fold] = f

    # check case-folding of directories
    foldprefix = unfoldprefix = lastfull = b''
    for fold, f in sorted(foldmap.items()):
        if fold.startswith(foldprefix) and not f.startswith(unfoldprefix):
            # the folded prefix matches but actual casing is different
            msg = _(b"case-folding collision between %s and directory of %s")
            msg %= (lastfull, f)
            raise error.StateError(msg)
        foldprefix = fold + b'/'
        unfoldprefix = f + b'/'
        lastfull = f


def _filesindirs(repo, manifest, dirs) -> Iterator[tuple[bytes, bytes]]:
    """
    Generator that yields pairs of all the files in the manifest that are found
    inside the directories listed in dirs, and which directory they are found
    in.
    """
    for f in manifest:
        for p in pathutil.finddirs(f):
            if p in dirs:
                yield f, p
                break


def checkpathconflicts(
    repo,
    wctx,
    mctx,
    mresult: merge_utils.MergeResult,
) -> None:
    """
    Check if any actions introduce path conflicts in the repository, updating
    actions to record or handle the path conflict accordingly.
    """
    mf = wctx.manifest()

    # The set of local files that conflict with a remote directory.
    localconflicts = set()

    # The set of directories that conflict with a remote file, and so may cause
    # conflicts if they still contain any files after the merge.
    remoteconflicts = set()

    # The set of directories that appear as both a file and a directory in the
    # remote manifest.  These indicate an invalid remote manifest, which
    # can't be updated to cleanly.
    invalidconflicts = set()

    # The set of directories that contain files that are being created.
    createdfiledirs = set()

    # The set of files deleted by all the actions.
    deletedfiles = set()

    for f in mresult.files(
        (
            mergestatemod.ACTION_CREATED,
            mergestatemod.ACTION_DELETED_CHANGED,
            mergestatemod.ACTION_MERGE,
            mergestatemod.ACTION_CREATED_MERGE,
        )
    ):
        # This action may create a new local file.
        createdfiledirs.update(pathutil.finddirs(f))
        if mf.hasdir(f):
            # The file aliases a local directory.  This might be ok if all
            # the files in the local directory are being deleted.  This
            # will be checked once we know what all the deleted files are.
            remoteconflicts.add(f)
    # Track the names of all deleted files.
    for f in mresult.files((mergestatemod.ACTION_REMOVE,)):
        deletedfiles.add(f)
    for f, args, msg in mresult.getactions((mergestatemod.ACTION_MERGE,)):
        f1, f2, fa, move, anc = args
        if move:
            deletedfiles.add(f1)
    for f, args, msg in mresult.getactions(
        (mergestatemod.ACTION_DIR_RENAME_MOVE_LOCAL,)
    ):
        f2, flags = args
        deletedfiles.add(f2)

    # Check all directories that contain created files for path conflicts.
    for p in createdfiledirs:
        if p in mf:
            if p in mctx:
                # A file is in a directory which aliases both a local
                # and a remote file.  This is an internal inconsistency
                # within the remote manifest.
                invalidconflicts.add(p)
            else:
                # A file is in a directory which aliases a local file.
                # We will need to rename the local file.
                localconflicts.add(p)
        pd = mresult.getfile(p)
        if pd and pd[0] in (
            mergestatemod.ACTION_CREATED,
            mergestatemod.ACTION_DELETED_CHANGED,
            mergestatemod.ACTION_MERGE,
            mergestatemod.ACTION_CREATED_MERGE,
        ):
            # The file is in a directory which aliases a remote file.
            # This is an internal inconsistency within the remote
            # manifest.
            invalidconflicts.add(p)

    # Rename all local conflicting files that have not been deleted.
    for p in localconflicts:
        if p not in deletedfiles:
            ctxname = bytes(wctx).rstrip(b'+')
            pnew = util.safename(p, ctxname, wctx, set(mresult.files()))
            porig = wctx[p].copysource() or p
            mresult.addfile(
                pnew,
                mergestatemod.ACTION_PATH_CONFLICT_RESOLVE,
                (p, porig),
                b'local path conflict',
            )
            mresult.addfile(
                p,
                mergestatemod.ACTION_PATH_CONFLICT,
                (pnew, b'l'),
                b'path conflict',
            )

    if remoteconflicts:
        # Check if all files in the conflicting directories have been removed.
        ctxname = bytes(mctx).rstrip(b'+')
        for f, p in _filesindirs(repo, mf, remoteconflicts):
            if f not in deletedfiles:
                mapping_value = mresult.getfile(p)

                # Help pytype- in theory, this could be None since no default
                # value is passed to getfile() above.
                assert mapping_value is not None

                m, args, msg = mapping_value
                pnew = util.safename(p, ctxname, wctx, set(mresult.files()))
                if m in (
                    mergestatemod.ACTION_DELETED_CHANGED,
                    mergestatemod.ACTION_MERGE,
                ):
                    # Action was merge, just update target.
                    mresult.addfile(pnew, m, args, msg)
                else:
                    # Action was create, change to renamed get action.
                    fl = args[0]
                    mresult.addfile(
                        pnew,
                        mergestatemod.ACTION_LOCAL_DIR_RENAME_GET,
                        (p, fl),
                        b'remote path conflict',
                    )
                mresult.addfile(
                    p,
                    mergestatemod.ACTION_PATH_CONFLICT,
                    (pnew, b'r'),
                    b'path conflict',
                )
                remoteconflicts.remove(p)
                break

    if invalidconflicts:
        for p in invalidconflicts:
            repo.ui.warn(_(b"%s: is both a file and a directory\n") % p)
        raise error.StateError(
            _(b"destination manifest contains path conflicts")
        )


def _filternarrowactions(
    narrowmatch,
    branchmerge,
    mresult: merge_utils.MergeResult,
) -> None:
    """
    Filters out actions that can ignored because the repo is narrowed.

    Raise an exception if the merge cannot be completed because the repo is
    narrowed.
    """
    # We mutate the items in the dict during iteration, so iterate
    # over a copy.
    for f, action in list(mresult.filemap()):
        if narrowmatch(f):
            pass
        elif not branchmerge:
            mresult.removefile(f)  # just updating, ignore changes outside clone
        elif action[0].no_op:
            mresult.removefile(f)  # merge does not affect file
        elif action[0].narrow_safe:
            if not f.endswith(b'/'):
                mresult.removefile(f)  # merge won't affect on-disk files

                mresult.addcommitinfo(
                    f, b'outside-narrow-merge-action', action[0].changes
                )
            else:  # TODO: handle the tree case
                msg = _(
                    b'merge affects file \'%s\' outside narrow, '
                    b'which is not yet supported'
                )
                hint = _(b'merging in the other direction may work')
                raise error.Abort(msg % f, hint=hint)
        else:
            msg = _(b'conflict in file \'%s\' is outside narrow clone')
            raise error.StateError(msg % f)


def manifestmerge(
    repo,
    wctx,
    p2,
    pa,
    branchmerge,
    force,
    matcher,
    acceptremote,
    followcopies,
    forcefulldiff=False,
) -> merge_utils.MergeResult:
    """
    Merge wctx and p2 with ancestor pa and generate merge action list

    branchmerge and force are as passed in to update
    matcher = matcher to filter file lists
    acceptremote = accept the incoming changes without prompting

    Returns an object of merge_utils.MergeResult class
    """
    mresult = merge_utils.MergeResult()
    if matcher is not None and matcher.always():
        matcher = None

    # manifests fetched in order are going to be faster, so prime the caches
    [
        x.manifest()
        for x in sorted(wctx.parents() + [p2, pa], key=scmutil.intrev)
    ]

    branch_copies1 = copies.branch_copies()
    branch_copies2 = copies.branch_copies()
    diverge = {}
    # information from merge which is needed at commit time
    # for example choosing filelog of which parent to commit
    # TODO: use specific constants in future for this mapping
    if followcopies:
        branch_copies1, branch_copies2, diverge = copies.mergecopies(
            repo, wctx, p2, pa
        )

    boolbm = pycompat.bytestr(bool(branchmerge))
    boolf = pycompat.bytestr(bool(force))
    boolm = pycompat.bytestr(bool(matcher))
    repo.ui.note(_(b"resolving manifests\n"))
    repo.ui.debug(
        b" branchmerge: %s, force: %s, partial: %s\n" % (boolbm, boolf, boolm)
    )
    repo.ui.debug(b" ancestor: %s, local: %s, remote: %s\n" % (pa, wctx, p2))

    m1, m2, ma = wctx.manifest(), p2.manifest(), pa.manifest()
    copied1 = set(branch_copies1.copy.values())
    copied1.update(branch_copies1.movewithdir.values())
    copied2 = set(branch_copies2.copy.values())
    copied2.update(branch_copies2.movewithdir.values())

    if b'.hgsubstate' in m1 and wctx.rev() is None:
        # Check whether sub state is modified, and overwrite the manifest
        # to flag the change. If wctx is a committed revision, we shouldn't
        # care for the dirty state of the working directory.
        if any(wctx.sub(s).dirty() for s in wctx.substate):
            m1[b'.hgsubstate'] = repo.nodeconstants.modifiednodeid

    # Don't use m2-vs-ma optimization if:
    # - ma is the same as m1 or m2, which we're just going to diff again later
    # - The caller specifically asks for a full diff, which is useful during bid
    #   merge.
    # - we are tracking salvaged files specifically hence should process all
    #   files
    if (
        pa not in ([wctx, p2] + wctx.parents())
        and not forcefulldiff
        and not (
            repo.ui.configbool(b'experimental', b'merge-track-salvaged')
            or repo.filecopiesmode == b'changeset-sidedata'
        )
    ):
        # Identify which files are relevant to the merge, so we can limit the
        # total m1-vs-m2 diff to just those files. This has significant
        # performance benefits in large repositories.
        relevantfiles = set(ma.diff(m2).keys())

        # For copied and moved files, we need to add the source file too.
        for copykey, copyvalue in branch_copies1.copy.items():
            if copyvalue in relevantfiles:
                relevantfiles.add(copykey)
        for movedirkey in branch_copies1.movewithdir:
            relevantfiles.add(movedirkey)
        filesmatcher = scmutil.matchfiles(repo, relevantfiles)
        matcher = matchmod.intersectmatchers(matcher, filesmatcher)

    diff = m1.diff(m2, match=matcher)

    for f, ((n1, fl1), (n2, fl2)) in diff.items():
        if n1 and n2:  # file exists on both local and remote side
            if f not in ma:
                # TODO: what if they're renamed from different sources?
                fa = branch_copies1.copy.get(
                    f, None
                ) or branch_copies2.copy.get(f, None)
                args, msg = None, None
                if fa is not None:
                    args = (f, f, fa, False, pa.node())
                    msg = b'both renamed from %s' % fa
                else:
                    args = (f, f, None, False, pa.node())
                    msg = b'both created'
                mresult.addfile(f, mergestatemod.ACTION_MERGE, args, msg)
            elif f in branch_copies1.copy:
                fa = branch_copies1.copy[f]
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_MERGE,
                    (f, fa, fa, False, pa.node()),
                    b'local replaced from %s' % fa,
                )
            elif f in branch_copies2.copy:
                fa = branch_copies2.copy[f]
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_MERGE,
                    (fa, f, fa, False, pa.node()),
                    b'other replaced from %s' % fa,
                )
            else:
                a = ma[f]
                fla = ma.flags(f)
                nol = b'l' not in fl1 + fl2 + fla
                if n2 == a and fl2 == fla:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_KEEP,
                        (),
                        b'remote unchanged',
                    )
                elif n1 == a and fl1 == fla:  # local unchanged - use remote
                    if n1 == n2:  # optimization: keep local content
                        mresult.addfile(
                            f,
                            mergestatemod.ACTION_EXEC,
                            (fl2,),
                            b'update permissions',
                        )
                    else:
                        mresult.addfile(
                            f,
                            mergestatemod.ACTION_GET,
                            (fl2, False),
                            b'remote is newer',
                        )
                        if branchmerge:
                            mresult.addcommitinfo(
                                f, b'filenode-source', b'other'
                            )
                elif nol and n2 == a:  # remote only changed 'x'
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_EXEC,
                        (fl2,),
                        b'update permissions',
                    )
                elif nol and n1 == a:  # local only changed 'x'
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_GET,
                        (fl1, False),
                        b'remote is newer',
                    )
                    if branchmerge:
                        mresult.addcommitinfo(f, b'filenode-source', b'other')
                else:  # both changed something
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_MERGE,
                        (f, f, f, False, pa.node()),
                        b'versions differ',
                    )
        elif n1:  # file exists only on local side
            if f in copied2:
                pass  # we'll deal with it on m2 side
            elif (
                f in branch_copies1.movewithdir
            ):  # directory rename, move local
                f2 = branch_copies1.movewithdir[f]
                if f2 in m2:
                    mresult.addfile(
                        f2,
                        mergestatemod.ACTION_MERGE,
                        (f, f2, None, True, pa.node()),
                        b'remote directory rename, both created',
                    )
                else:
                    mresult.addfile(
                        f2,
                        mergestatemod.ACTION_DIR_RENAME_MOVE_LOCAL,
                        (f, fl1),
                        b'remote directory rename - move from %s' % f,
                    )
            elif f in branch_copies1.copy:
                f2 = branch_copies1.copy[f]
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_MERGE,
                    (f, f2, f2, False, pa.node()),
                    b'local copied/moved from %s' % f2,
                )
            elif f in ma:  # clean, a different, no remote
                if n1 != ma[f]:
                    if acceptremote:
                        mresult.addfile(
                            f,
                            mergestatemod.ACTION_REMOVE,
                            None,
                            b'remote delete',
                        )
                    else:
                        mresult.addfile(
                            f,
                            mergestatemod.ACTION_CHANGED_DELETED,
                            (f, None, f, False, pa.node()),
                            b'prompt changed/deleted',
                        )
                        if branchmerge:
                            mresult.addcommitinfo(
                                f, b'merge-removal-candidate', b'yes'
                            )
                elif n1 == repo.nodeconstants.addednodeid:
                    # This file was locally added. We should forget it instead of
                    # deleting it.
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_FORGET,
                        None,
                        b'remote deleted',
                    )
                else:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_REMOVE,
                        None,
                        b'other deleted',
                    )
                    if branchmerge:
                        # the file must be absent after merging,
                        # howeber the user might make
                        # the file reappear using revert and if they does,
                        # we force create a new node
                        mresult.addcommitinfo(
                            f, b'merge-removal-candidate', b'yes'
                        )

            else:  # file not in ancestor, not in remote
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_KEEP_NEW,
                    None,
                    b'ancestor missing, remote missing',
                )

        elif n2:  # file exists only on remote side
            if f in copied1:
                pass  # we'll deal with it on m1 side
            elif f in branch_copies2.movewithdir:
                f2 = branch_copies2.movewithdir[f]
                if f2 in m1:
                    mresult.addfile(
                        f2,
                        mergestatemod.ACTION_MERGE,
                        (f2, f, None, False, pa.node()),
                        b'local directory rename, both created',
                    )
                else:
                    mresult.addfile(
                        f2,
                        mergestatemod.ACTION_LOCAL_DIR_RENAME_GET,
                        (f, fl2),
                        b'local directory rename - get from %s' % f,
                    )
            elif f in branch_copies2.copy:
                f2 = branch_copies2.copy[f]
                msg, args = None, None
                if f2 in m2:
                    args = (f2, f, f2, False, pa.node())
                    msg = b'remote copied from %s' % f2
                else:
                    args = (f2, f, f2, True, pa.node())
                    msg = b'remote moved from %s' % f2
                mresult.addfile(f, mergestatemod.ACTION_MERGE, args, msg)
            elif f not in ma:
                # local unknown, remote created: the logic is described by the
                # following table:
                #
                # force  branchmerge  different  |  action
                #   n         *           *      |   create
                #   y         n           *      |   create
                #   y         y           n      |   create
                #   y         y           y      |   merge
                #
                # Checking whether the files are different is expensive, so we
                # don't do that when we can avoid it.
                if not force:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_CREATED,
                        (fl2,),
                        b'remote created',
                    )
                elif not branchmerge:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_CREATED,
                        (fl2,),
                        b'remote created',
                    )
                else:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_CREATED_MERGE,
                        (fl2, pa.node()),
                        b'remote created, get or merge',
                    )
            elif n2 != ma[f]:
                df = None
                for d in branch_copies1.dirmove:
                    if f.startswith(d):
                        # new file added in a directory that was moved
                        df = branch_copies1.dirmove[d] + f[len(d) :]
                        break
                if df is not None and df in m1:
                    mresult.addfile(
                        df,
                        mergestatemod.ACTION_MERGE,
                        (df, f, f, False, pa.node()),
                        b'local directory rename - respect move '
                        b'from %s' % f,
                    )
                elif acceptremote:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_CREATED,
                        (fl2,),
                        b'remote recreating',
                    )
                else:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_DELETED_CHANGED,
                        (None, f, f, False, pa.node()),
                        b'prompt deleted/changed',
                    )
                    if branchmerge:
                        mresult.addcommitinfo(
                            f, b'merge-removal-candidate', b'yes'
                        )
            else:
                mresult.addfile(
                    f,
                    mergestatemod.ACTION_KEEP_ABSENT,
                    None,
                    b'local not present, remote unchanged',
                )
                if branchmerge:
                    # the file must be absent after merging
                    # however the user might make
                    # the file reappear using revert and if they does,
                    # we force create a new node
                    mresult.addcommitinfo(f, b'merge-removal-candidate', b'yes')

    if repo.ui.configbool(b'experimental', b'merge.checkpathconflicts'):
        # If we are merging, look for path conflicts.
        checkpathconflicts(repo, wctx, p2, mresult)

    narrowmatch = repo.narrowmatch()
    if not narrowmatch.always():
        # Updates "actions" in place
        _filternarrowactions(narrowmatch, branchmerge, mresult)

    renamedelete = branch_copies1.renamedelete
    renamedelete.update(branch_copies2.renamedelete)

    mresult.updatevalues(diverge, renamedelete)
    return mresult


def _resolvetrivial(
    repo,
    wctx,
    mctx,
    ancestor,
    mresult: merge_utils.MergeResult,
) -> None:
    """Resolves false conflicts where the nodeid changed but the content
    remained the same."""
    # We force a copy of actions.items() because we're going to mutate
    # actions as we resolve trivial conflicts.
    for f in list(mresult.files((mergestatemod.ACTION_CHANGED_DELETED,))):
        if f in ancestor and not wctx[f].cmp(ancestor[f]):
            # local did change but ended up with same content
            mresult.addfile(
                f, mergestatemod.ACTION_REMOVE, None, b'prompt same'
            )

    for f in list(mresult.files((mergestatemod.ACTION_DELETED_CHANGED,))):
        if f in ancestor and not mctx[f].cmp(ancestor[f]):
            # remote did change but ended up with same content
            mresult.removefile(f)  # don't get = keep local deleted


def calculateupdates(
    repo,
    wctx,
    mctx,
    ancestors,
    branchmerge,
    force,
    acceptremote,
    followcopies,
    matcher=None,
    mergeforce=False,
) -> merge_utils.MergeResult:
    """
    Calculate the actions needed to merge mctx into wctx using ancestors

    Uses manifestmerge() to merge manifest and get list of actions required to
    perform for merging two manifests. If there are multiple ancestors, uses bid
    merge if enabled.

    Also filters out actions which are unrequired if repository is sparse.

    Returns merge_utils.MergeResult object same as manifestmerge().
    """
    mresult = None
    if len(ancestors) == 1:  # default
        mresult = manifestmerge(
            repo,
            wctx,
            mctx,
            ancestors[0],
            branchmerge,
            force,
            matcher,
            acceptremote,
            followcopies,
        )
        _checkunknownfiles(repo, wctx, mctx, force, mresult, mergeforce)
        if repo.ui.configbool(b'devel', b'debug.abort-update'):
            exit(1)

    else:  # only when merge.preferancestor=* - the default
        repo.ui.note(
            _(b"note: merging %s and %s using bids from ancestors %s\n")
            % (
                wctx,
                mctx,
                _(b' and ').join(pycompat.bytestr(anc) for anc in ancestors),
            )
        )

        # mapping filename to bids (action method to list af actions)
        # {FILENAME1 : BID1, FILENAME2 : BID2}
        # BID is another dictionary which contains
        # mapping of following form:
        # {ACTION_X : [info, ..], ACTION_Y : [info, ..]}
        fbids = {}
        mresult = merge_utils.MergeResult()
        diverge, renamedelete = None, None
        for ancestor in ancestors:
            repo.ui.note(_(b'\ncalculating bids for ancestor %s\n') % ancestor)
            mresult1 = manifestmerge(
                repo,
                wctx,
                mctx,
                ancestor,
                branchmerge,
                force,
                matcher,
                acceptremote,
                followcopies,
                forcefulldiff=True,
            )
            _checkunknownfiles(repo, wctx, mctx, force, mresult1, mergeforce)

            # Track the shortest set of warning on the theory that bid
            # merge will correctly incorporate more information
            if diverge is None or len(mresult1.diverge) < len(diverge):
                diverge = mresult1.diverge
            if renamedelete is None or len(renamedelete) < len(
                mresult1.renamedelete
            ):
                renamedelete = mresult1.renamedelete

            # blindly update final mergeresult commitinfo with what we get
            # from mergeresult object for each ancestor
            # TODO: some commitinfo depends on what bid merge choose and hence
            # we will need to make commitinfo also depend on bid merge logic
            mresult._commitinfo.update(mresult1._commitinfo)

            for f, a in mresult1.filemap(sort=True):
                m, args, msg = a
                repo.ui.debug(b' %s: %s -> %s\n' % (f, msg, m.__bytes__()))
                if f in fbids:
                    d = fbids[f]
                    if m in d:
                        d[m].append(a)
                    else:
                        d[m] = [a]
                else:
                    fbids[f] = {m: [a]}

        # Call for bids
        # Pick the best bid for each file
        repo.ui.note(
            _(b'\nauction for merging merge bids (%d ancestors)\n')
            % len(ancestors)
        )
        for f, bids in sorted(fbids.items()):
            if repo.ui.debugflag:
                repo.ui.debug(b" list of bids for %s:\n" % f)
                for m, l in sorted(bids.items()):
                    for _f, args, msg in l:
                        repo.ui.debug(b'   %s -> %s\n' % (msg, m.__bytes__()))
            # bids is a mapping from action method to list af actions
            # Consensus?
            if len(bids) == 1:  # all bids are the same kind of method
                m, l = list(bids.items())[0]
                if all(a == l[0] for a in l[1:]):  # len(bids) is > 1
                    repo.ui.note(
                        _(b" %s: consensus for %s\n") % (f, m.__bytes__())
                    )
                    mresult.addfile(f, *l[0])
                    continue
            # If keep is an option, just do it.
            if mergestatemod.ACTION_KEEP in bids:
                repo.ui.note(_(b" %s: picking 'keep' action\n") % f)
                mresult.addfile(f, *bids[mergestatemod.ACTION_KEEP][0])
                continue
            # If keep absent is an option, just do that
            if mergestatemod.ACTION_KEEP_ABSENT in bids:
                repo.ui.note(_(b" %s: picking 'keep absent' action\n") % f)
                mresult.addfile(f, *bids[mergestatemod.ACTION_KEEP_ABSENT][0])
                continue
            # ACTION_KEEP_NEW and ACTION_CHANGED_DELETED are conflicting actions
            # as one say that file is new while other says that file was present
            # earlier too and has a change delete conflict
            # Let's fall back to conflicting ACTION_CHANGED_DELETED and let user
            # do the right thing
            if (
                mergestatemod.ACTION_CHANGED_DELETED in bids
                and mergestatemod.ACTION_KEEP_NEW in bids
            ):
                repo.ui.note(_(b" %s: picking 'changed/deleted' action\n") % f)
                mresult.addfile(
                    f, *bids[mergestatemod.ACTION_CHANGED_DELETED][0]
                )
                continue
            # If keep new is an option, let's just do that
            if mergestatemod.ACTION_KEEP_NEW in bids:
                repo.ui.note(_(b" %s: picking 'keep new' action\n") % f)
                mresult.addfile(f, *bids[mergestatemod.ACTION_KEEP_NEW][0])
                continue
            # ACTION_GET and ACTION_DELETE_CHANGED are conflicting actions as
            # one action states the file is newer/created on remote side and
            # other states that file is deleted locally and changed on remote
            # side. Let's fallback and rely on a conflicting action to let user
            # do the right thing
            if (
                mergestatemod.ACTION_DELETED_CHANGED in bids
                and mergestatemod.ACTION_GET in bids
            ):
                repo.ui.note(_(b" %s: picking 'delete/changed' action\n") % f)
                mresult.addfile(
                    f, *bids[mergestatemod.ACTION_DELETED_CHANGED][0]
                )
                continue
            # If there are gets and they all agree [how could they not?], do it.
            if mergestatemod.ACTION_GET in bids:
                ga0 = bids[mergestatemod.ACTION_GET][0]
                if all(a == ga0 for a in bids[mergestatemod.ACTION_GET][1:]):
                    repo.ui.note(_(b" %s: picking 'get' action\n") % f)
                    mresult.addfile(f, *ga0)
                    continue
            # TODO: Consider other simple actions such as mode changes
            # Handle inefficient democrazy.
            repo.ui.note(_(b' %s: multiple bids for merge action:\n') % f)
            for m, l in sorted(bids.items()):
                for _f, args, msg in l:
                    repo.ui.note(b'  %s -> %s\n' % (msg, m.__bytes__()))
            # Pick random action. TODO: Instead, prompt user when resolving
            m, l = list(bids.items())[0]
            repo.ui.warn(
                _(b' %s: ambiguous merge - picked %s action\n')
                % (f, m.__bytes__())
            )
            mresult.addfile(f, *l[0])
            continue
        repo.ui.note(_(b'end of auction\n\n'))
        mresult.updatevalues(diverge, renamedelete)

    if wctx.rev() is None:
        _forgetremoved(wctx, mctx, branchmerge, mresult)

    sparse.filterupdatesactions(repo, wctx, mctx, branchmerge, mresult)
    _resolvetrivial(repo, wctx, mctx, ancestors[0], mresult)

    return mresult


def _advertisefsmonitor(repo, num_gets, p1node):
    # Advertise fsmonitor when its presence could be useful.
    #
    # We only advertise when performing an update from an empty working
    # directory. This typically only occurs during initial clone.
    #
    # We give users a mechanism to disable the warning in case it is
    # annoying.
    #
    # We only allow on Linux and MacOS because that's where fsmonitor is
    # considered stable.
    fsmonitorwarning = repo.ui.configbool(b'fsmonitor', b'warn_when_unused')
    fsmonitorthreshold = repo.ui.configint(
        b'fsmonitor', b'warn_update_file_count'
    )
    # avoid cycle dirstate -> sparse -> merge -> dirstate
    dirstate_rustmod = policy.importrust("dirstate")

    if dirstate_rustmod is not None:
        # When using rust status, fsmonitor becomes necessary at higher sizes
        fsmonitorthreshold = repo.ui.configint(
            b'fsmonitor',
            b'warn_update_file_count_rust',
        )

    if _fs_monitor_loaded:
        # We intentionally don't look at whether fsmonitor has disabled
        # itself because a) fsmonitor may have already printed a warning
        # b) we only care about the config state here.
        fsmonitorenabled = repo.ui.config(b'fsmonitor', b'mode') != b'off'
    else:
        fsmonitorenabled = False

    if (
        fsmonitorwarning
        and not fsmonitorenabled
        and p1node == repo.nullid
        and num_gets >= fsmonitorthreshold
        and pycompat.sysplatform.startswith((b'linux', b'darwin'))
    ):
        repo.ui.warn(
            _(
                b'(warning: large working directory being used without '
                b'fsmonitor enabled; enable fsmonitor to improve performance; '
                b'see "hg help -e fsmonitor")\n'
            )
        )


UPDATECHECK_ABORT = b'abort'  # handled at higher layers
UPDATECHECK_NONE = b'none'
UPDATECHECK_LINEAR = b'linear'
UPDATECHECK_NO_CONFLICT = b'noconflict'

# Let extensions turn off any Rust code in the update code if that interferes
# will their patching.
# This being `True` does not mean that you have Rust extensions installed or
# that the Rust path will be taken for any given invocation.
MAYBE_USE_RUST_UPDATE = True


def _update(
    repo,
    node,
    branchmerge,
    force,
    ancestor=None,
    mergeancestor=False,
    labels=None,
    matcher=None,
    mergeforce=False,
    updatedirstate=True,
    updatecheck=None,
    wc=None,
):
    """
    Perform a merge between the working directory and the given node

    node = the node to update to
    branchmerge = whether to merge between branches
    force = whether to force branch merging or file overwriting
    matcher = a matcher to filter file lists (dirstate not updated)
    mergeancestor = whether it is merging with an ancestor. If true,
      we should accept the incoming changes for any prompts that occur.
      If false, merging with an ancestor (fast-forward) is only allowed
      between different named branches. This flag is used by rebase extension
      as a temporary fix and should be avoided in general.
    labels = labels to use for local, other, and base
    mergeforce = whether the merge was run with 'merge --force' (deprecated): if
      this is True, then 'force' should be True as well.

    The table below shows all the behaviors of the update command given the
    -c/--check and -C/--clean or no options, whether the working directory is
    dirty, whether a revision is specified, and the relationship of the parent
    rev to the target rev (linear or not). Match from top first. The -n
    option doesn't exist on the command line, but represents the
    experimental.updatecheck=noconflict option.

    This logic is tested by test-update-branches.t.

    -c  -C  -n  -m  dirty  rev  linear  |  result
     y   y   *   *    *     *     *     |    (1)
     y   *   y   *    *     *     *     |    (1)
     y   *   *   y    *     *     *     |    (1)
     *   y   y   *    *     *     *     |    (1)
     *   y   *   y    *     *     *     |    (1)
     *   *   y   y    *     *     *     |    (1)
     *   *   *   *    *     n     n     |     x
     *   *   *   *    n     *     *     |    ok
     n   n   n   n    y     *     y     |   merge
     n   n   n   n    y     y     n     |    (2)
     n   n   n   y    y     *     *     |   merge
     n   n   y   n    y     *     *     |  merge if no conflict
     n   y   n   n    y     *     *     |  discard
     y   n   n   n    y     *     *     |    (3)

    x = can't happen
    * = don't-care
    1 = incompatible options (checked in commands.py)
    2 = abort: uncommitted changes (commit or update --clean to discard changes)
    3 = abort: uncommitted changes (checked in commands.py)

    The merge is performed inside ``wc``, a workingctx-like objects. It defaults
    to repo[None] if None is passed.

    Return the same tuple as apply_updates().
    """
    # This function used to find the default destination if node was None, but
    # that's now in destutil.py.
    assert node is not None
    if not branchmerge and not force:
        # TODO: remove the default once all callers that pass branchmerge=False
        # and force=False pass a value for updatecheck. We may want to allow
        # updatecheck='abort' to better suppport some of these callers.
        if updatecheck is None:
            updatecheck = UPDATECHECK_LINEAR
        okay = (UPDATECHECK_NONE, UPDATECHECK_LINEAR, UPDATECHECK_NO_CONFLICT)
        if updatecheck not in okay:
            msg = r'Invalid updatecheck %r (can accept %r)'
            msg %= (updatecheck, okay)
            raise ValueError(msg)
    if wc is not None and wc.isinmemory():
        maybe_wlock = util.nullcontextmanager()
    else:
        maybe_wlock = repo.wlock()
    with maybe_wlock, util.rust_tracing_span("under wlock"):
        if wc is None:
            wc = repo[None]
        pl = wc.parents()
        p1 = pl[0]
        p2 = repo[node]
        if ancestor is not None:
            pas = [repo[ancestor]]
        else:
            if repo.ui.configlist(b'merge', b'preferancestor') == [b'*']:
                cahs = repo.changelog.commonancestorsheads(p1.node(), p2.node())
                pas = [repo[anc] for anc in (sorted(cahs) or [repo.nullid])]
            else:
                pas = [p1.ancestor(p2, warn=branchmerge)]

        fp1, fp2, xp1, xp2 = p1.node(), p2.node(), bytes(p1), bytes(p2)

        overwrite = force and not branchmerge
        # If not none, whether the (optional) first status was clean or dirty
        is_dirty = None
        ### check phase
        if not overwrite:
            if len(pl) > 1:
                raise error.StateError(_(b"outstanding uncommitted merge"))
            ms = wc.mergestate()
            if ms.unresolvedcount():
                msg = _(b"outstanding merge conflicts")
                hint = _(b"use 'hg resolve' to resolve")
                raise error.StateError(msg, hint=hint)
        if branchmerge:
            m_a = _(b"merging with a working directory ancestor has no effect")
            if pas == [p2]:
                raise error.Abort(m_a)
            elif pas == [p1]:
                if not mergeancestor and wc.branch() == p2.branch():
                    msg = _(b"nothing to merge")
                    hint = _(b"use 'hg update' or check 'hg heads'")
                    raise error.Abort(msg, hint=hint)
            if not force and (wc.files() or wc.deleted()):
                msg = _(b"uncommitted changes")
                hint = _(b"use 'hg status' to list changes")
                raise error.StateError(msg, hint=hint)
            if not wc.isinmemory():
                for s in sorted(wc.substate):
                    wc.sub(s).bailifchanged()

        elif not overwrite:
            if p1 == p2:  # no-op update
                # call the hooks and exit early
                repo.hook(b'preupdate', throw=True, parent1=xp2, parent2=b'')
                repo.hook(b'update', parent1=xp2, parent2=b'', error=0)
                return update_util.UpdateResult(0, 0, 0, 0)

            if updatecheck == UPDATECHECK_LINEAR and pas not in (
                [p1],
                [p2],
            ):  # nonlinear
                is_dirty = wc.dirty(missing=True)
                if is_dirty:
                    # Branching is a bit strange to ensure we do the minimal
                    # amount of call to obsutil.foreground.
                    foreground = obsutil.foreground(repo, [p1.node()])
                    # note: the <node> variable contains a random identifier
                    if repo[node].node() in foreground:
                        pass  # allow updating to successors
                    else:
                        msg = _(b"uncommitted changes")
                        hint = _(b"commit or update --clean to discard changes")
                        raise error.UpdateAbort(msg, hint=hint)
                else:
                    # Allow jumping branches if clean and specific rev given
                    pass

        if overwrite:
            pas = [wc]
        elif not branchmerge:
            pas = [p1]

        # deprecated config: merge.followcopies
        followcopies = repo.ui.configbool(b'merge', b'followcopies')
        if overwrite:
            followcopies = False
        elif not pas[0]:
            followcopies = False
        if is_dirty is None:
            is_dirty = bool(wc.dirty(missing=True))
        if not branchmerge and not is_dirty:
            followcopies = False

        (update_from_rust_fallback, res) = _update_rust_fast_path(
            repo=repo,
            wc=wc,
            p1=p1,
            p2=p2,
            pas=pas,
            pl=pl,
            branchmerge=branchmerge,
            matcher=matcher,
            is_dirty=is_dirty,
            force=force,
            mergeancestor=mergeancestor,
            followcopies=followcopies,
            mergeforce=mergeforce,
        )
        if not update_from_rust_fallback and res is not None:
            return res

        ### calculate phase
        mresult = calculateupdates(
            repo,
            wc,
            p2,
            pas,
            branchmerge,
            force,
            mergeancestor,
            followcopies,
            matcher=matcher,
            mergeforce=mergeforce,
        )

        if updatecheck == UPDATECHECK_NO_CONFLICT:
            if mresult.hasconflicts():
                msg = _(b"conflicting changes")
                hint = _(b"commit or update --clean to discard changes")
                raise error.StateError(msg, hint=hint)

        # Prompt and create actions. Most of this is in the resolve phase
        # already, but we can't handle .hgsubstate in filemerge or
        # subrepoutil.submerge yet so we have to keep prompting for it.
        vals = mresult.getfile(b'.hgsubstate')
        if vals:
            f = b'.hgsubstate'
            m, args, msg = vals
            prompts = filemerge.partextras(labels)
            prompts[b'f'] = f
            if m == mergestatemod.ACTION_CHANGED_DELETED:
                if repo.ui.promptchoice(
                    _(
                        b"local%(l)s changed %(f)s which other%(o)s deleted\n"
                        b"use (c)hanged version or (d)elete?"
                        b"$$ &Changed $$ &Delete"
                    )
                    % prompts,
                    0,
                ):
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_REMOVE,
                        None,
                        b'prompt delete',
                    )
                elif f in p1:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_ADD_MODIFIED,
                        None,
                        b'prompt keep',
                    )
                else:
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_ADD,
                        None,
                        b'prompt keep',
                    )
            elif m == mergestatemod.ACTION_DELETED_CHANGED:
                f1, f2, fa, move, anc = args
                flags = p2[f2].flags()
                if (
                    repo.ui.promptchoice(
                        _(
                            b"other%(o)s changed %(f)s which local%(l)s deleted\n"
                            b"use (c)hanged version or leave (d)eleted?"
                            b"$$ &Changed $$ &Deleted"
                        )
                        % prompts,
                        0,
                    )
                    == 0
                ):
                    mresult.addfile(
                        f,
                        mergestatemod.ACTION_GET,
                        (flags, False),
                        b'prompt recreating',
                    )
                else:
                    mresult.removefile(f)

        if not util.fscasesensitive(repo.path):
            # check collision between files only in p2 for clean update
            if not branchmerge and (
                force or not wc.dirty(missing=True, branch=False)
            ):
                _checkcollision(repo, p2.manifest(), None)
            else:
                _checkcollision(repo, wc.manifest(), mresult)

        # divergent renames
        for f, fl in sorted(mresult.diverge.items()):
            repo.ui.warn(
                _(
                    b"note: possible conflict - %s was renamed "
                    b"multiple times to:\n"
                )
                % f
            )
            for nf in sorted(fl):
                repo.ui.warn(b" %s\n" % nf)

        # rename and delete
        for f, fl in sorted(mresult.renamedelete.items()):
            repo.ui.warn(
                _(
                    b"note: possible conflict - %s was deleted "
                    b"and renamed to:\n"
                )
                % f
            )
            for nf in sorted(fl):
                repo.ui.warn(b" %s\n" % nf)

        ### apply phase
        if not branchmerge:  # just jump to the new rev
            fp1, fp2, xp1, xp2 = fp2, repo.nullid, xp2, b''
        # If we're doing a partial update, we need to skip updating
        # the dirstate.
        always = matcher is None or matcher.always()
        updatedirstate = updatedirstate and always and not wc.isinmemory()
        # If we're in the fallback case, we've already done this
        if updatedirstate and not update_from_rust_fallback:
            repo.hook(b'preupdate', throw=True, parent1=xp1, parent2=xp2)
            # note that we're in the middle of an update
            repo.vfs.write(b'updatestate', p2.hex())

        # TODO don't run if Rust is available
        _advertisefsmonitor(
            repo, mresult.len((mergestatemod.ACTION_GET,)), p1.node()
        )

        wantfiledata = updatedirstate and not branchmerge
        stats, getfiledata, extraactions = update_util.apply_updates(
            repo,
            mresult,
            wc,
            p2,
            overwrite,
            wantfiledata,
            labels=labels,
        )

        if updatedirstate:
            if extraactions:
                for k, acts in extraactions.items():
                    for a in acts:
                        mresult.addfile(a[0], k, *a[1:])
                    if k == mergestatemod.ACTION_GET and wantfiledata:
                        # no filedata until mergestate is updated to provide it
                        for a in acts:
                            getfiledata[a[0]] = None

            assert len(getfiledata) == (
                mresult.len((mergestatemod.ACTION_GET,)) if wantfiledata else 0
            )
            with repo.dirstate.changing_parents(repo):
                repo.setparents(fp1, fp2)
                mergestatemod.recordupdates(
                    repo, mresult.actionsdict, branchmerge, getfiledata
                )
                if not branchmerge:
                    repo.dirstate.setbranch(
                        p2.branch(), repo.currenttransaction()
                    )

                # update completed, clear state
                util.unlink(repo.vfs.join(b'updatestate'))

                # If we're updating to a location, clean up any stale temporary includes
                # (ex: this happens during hg rebase --abort).
                if not branchmerge:
                    sparse.prunetemporaryincludes(repo)

    if updatedirstate:
        repo.hook(
            b'update', parent1=xp1, parent2=xp2, error=stats.unresolvedcount
        )
    return stats


def _update_rust_fast_path(
    repo,
    wc,
    p1,
    p2,
    pas,
    pl,
    branchmerge,
    matcher,
    is_dirty,
    force,
    mergeancestor,
    followcopies,
    mergeforce,
):
    update_from_clean = (
        MAYBE_USE_RUST_UPDATE
        and not is_dirty
        and repo.ui.configbool(b"rust", b"update-from-clean")
    )

    fp2, xp1, xp2 = p2.node(), bytes(p1), bytes(p2)

    # Checking for subrepos is quite expensive as it requires multiple
    # manifest lookups. Here, we cheat by looking directly in the store
    # for the `.hgsub` filelog path.
    never_had_subrepos = not repo.svfs.exists(b"data/.hgsub.i")

    update_from_null = False
    if (
        MAYBE_USE_RUST_UPDATE
        and not repo.is_bundle_repo
        and repo.ui.configbool(b"rust", b"update-from-null")
        and rust_update_mod is not None
        and p1.rev() == nullrev
        and not branchmerge
        # TODO it's probably not too hard to pass down the transaction and
        # respect the write patterns from Rust. But since it doesn't affect
        # a simple update from null, then it doesn't matter yet.
        and repo.currenttransaction() is None
        and matcher is None
        and not wc.mergestate().active()
        and never_had_subrepos
    ):
        working_dir_iter = os.scandir(repo.root)
        maybe_hg_folder = next(working_dir_iter)
        assert maybe_hg_folder is not None
        if maybe_hg_folder.name == b".hg":
            try:
                next(working_dir_iter)
            except StopIteration:
                update_from_null = True

    devel_abort_dirstate = repo.ui.configbool(
        b"devel", b"update.abort-on-dirstate-change"
    )

    def on_rust_warnings(warnings: Iterator[bytes]):
        """It is faster to loop in Python in cases with many items than
        to call back from Rust in a loop."""
        for warning in warnings:
            repo.ui.warn(warning)

    if update_from_null:
        repo.hook(b'preupdate', throw=True, parent1=xp1, parent2=xp2)
        # note that we're in the middle of an update
        repo.vfs.write(b'updatestate', p2.hex())
        num_cpus = (
            repo.ui.configint(b"worker", b"numcpus", None)
            if repo.ui.configbool(b"worker", b"enabled")
            else 1
        )

        try:
            dirstate = repo.dirstate
            with dirstate.changing_parents(repo):
                repo.setparents(fp2)
                tr = repo.currenttransaction()
                dirstate.setbranch(p2.branch(), tr)
                updated_count = rust_update_mod.update_from_null(
                    repo_path=repo.root,
                    to=p2.rev(),
                    dirstate=dirstate._map._map,
                    num_cpus=num_cpus,
                    on_warnings=on_rust_warnings,
                    devel_abort_dirstate=devel_abort_dirstate,
                )
                dirstate._dirty = True
                # In the narrow (pun intended) case of a narrowed repo whose
                # target revision from null has an empty working copy, this
                # is technically not true, but we still stay on the safe side
                # by setting the tracked set to dirty.
                dirstate._dirty_tracked_set = True
        except rust_update_mod.FallbackError:
            return (True, None)
        else:
            sparse.prunetemporaryincludes(repo)
            repo.hook(b'update', parent1=xp1, parent2=xp2, error=0)
            # update completed, clear state
            util.unlink(repo.vfs.join(b'updatestate'))
            return (False, update_util.UpdateResult(updated_count, 0, 0, 0))
    elif update_from_clean:
        if (
            rust_update_mod is not None
            and MAYBE_USE_RUST_UPDATE
            and not repo.is_bundle_repo
            and not branchmerge
            and not force  # TODO support force?
            and not mergeancestor
            and not followcopies
            and not mergeforce
            and matcher is None
            and not scmutil.istreemanifest(repo)
            and len(pas) == 1
            and pas[0] in [wc, p2] + wc.parents()
            # TODO it's probably not too hard to pass down the transaction
            # and respect the write patterns from Rust, but since it
            # doesn't affect an update from clean, then it doesn't
            # matter yet.
            and repo.currenttransaction() is None
            and not repo.ui.configbool(
                b'experimental', b'merge.checkpathconflicts'
            )
            and util.fscasesensitive(repo.path)
            and not wc.mergestate().active()
            and never_had_subrepos
        ):
            repo.hook(b'preupdate', throw=True, parent1=xp1, parent2=xp2)
            # note that we're in the middle of an update
            repo.vfs.write(b'updatestate', p2.hex())

            # TODO make the config object a Rust-based one so we can just
            # reuse it transparently and not worry about CLI arguments
            # not being caught by Rust
            num_cpus = (
                repo.ui.configint(b"worker", b"numcpus", None)
                if repo.ui.configbool(b"worker", b"enabled")
                else 1
            )
            remove_empty_dirs = repo.ui.configbool(
                b"experimental", b"removeemptydirs"
            )
            orig_backup_path = repo.ui.config(b"ui", b"origbackuppath")
            atomic_file = repo.ui.configbool(
                b"experimental", b"update.atomic-file"
            )

            try:
                with util.rust_tracing_span("update from clean python"):
                    p1_manifest = pl[0]._manifest._lm
                    p2_manifest = p2._manifest._lm
                    dirstate = repo.dirstate
                    with dirstate.changing_parents(repo):
                        repo.setparents(fp2)
                        tr = repo.currenttransaction()
                        dirstate.setbranch(p2.branch(), tr)
                        update_stats = rust_update_mod.update_from_clean(
                            repo_path=repo.root,
                            dirstate=dirstate._map._map,
                            wc_manifest_bytes=p1_manifest.text(),
                            target_rev=p2.rev(),
                            target_manifest_bytes=p2_manifest.text(),
                            num_cpus=num_cpus,
                            remove_empty_dirs=remove_empty_dirs,
                            devel_abort_dirstate=devel_abort_dirstate,
                            orig_backup_path=orig_backup_path,
                            atomic_file=atomic_file,
                            on_warnings=on_rust_warnings,
                        )
                        dirstate._dirty = True
                        # added or removed
                        if update_stats[0] or update_stats[3]:
                            dirstate._dirty_tracked_set = True
            except rust_update_mod.FallbackError:
                return (True, None)
            else:
                sparse.prunetemporaryincludes(repo)
                repo.hook(b'update', parent1=xp2, parent2=b'', error=0)
                # update completed, clear state
                util.unlink(repo.vfs.join(b'updatestate'))

                result = update_util.UpdateResult(
                    update_stats[1],
                    update_stats[2],
                    update_stats[3],
                    update_stats[4],
                )

                return (False, result)

    return (False, None)


def merge(ctx, labels=None, force=False, wc=None):
    """Merge another topological branch into the working copy.

    force = whether the merge was run with 'merge --force' (deprecated)
    """

    return _update(
        ctx.repo(),
        ctx.rev(),
        labels=labels,
        branchmerge=True,
        force=force,
        mergeforce=force,
        wc=wc,
    )


def update(ctx, updatecheck=None, wc=None):
    """Do a regular update to the given commit, aborting if there are conflicts.

    The 'updatecheck' argument can be used to control what to do in case of
    conflicts.

    Note: This is a new, higher-level update() than the one that used to exist
    in this module. That function is now called _update(). You can hopefully
    replace your callers to use this new update(), or clean_update(), merge(),
    revert_to(), or graft().
    """
    return _update(
        ctx.repo(),
        ctx.rev(),
        branchmerge=False,
        force=False,
        labels=[b'working copy', b'destination', b'working copy parent'],
        updatecheck=updatecheck,
        wc=wc,
    )


def clean_update(ctx, wc=None):
    """Do a clean update to the given commit.

    This involves updating to the commit and discarding any changes in the
    working copy.
    """
    return _update(ctx.repo(), ctx.rev(), branchmerge=False, force=True, wc=wc)


def revert_to(ctx, matcher=None, wc=None):
    """Revert the working copy to the given commit.

    The working copy will keep its current parent(s) but its content will
    be the same as in the given commit.
    """

    return _update(
        ctx.repo(),
        ctx.rev(),
        branchmerge=False,
        force=True,
        updatedirstate=False,
        matcher=matcher,
        wc=wc,
    )


def graft(
    repo,
    ctx,
    base=None,
    labels=None,
    keepparent=False,
    keepconflictparent=False,
    wctx=None,
):
    """Do a graft-like merge.

    This is a merge where the merge ancestor is chosen such that one
    or more changesets are grafted onto the current changeset. In
    addition to the merge, this fixes up the dirstate to include only
    a single parent (if keepparent is False) and tries to duplicate any
    renames/copies appropriately.

    ctx - changeset to rebase
    base - merge base, or ctx.p1() if not specified
    labels - merge labels eg ['local', 'graft']
    keepparent - keep second parent if any
    keepconflictparent - if unresolved, keep parent used for the merge

    """
    # If we're grafting a descendant onto an ancestor, be sure to pass
    # mergeancestor=True to update. This does two things: 1) allows the merge if
    # the destination is the same as the parent of the ctx (so we can use graft
    # to copy commits), and 2) informs update that the incoming changes are
    # newer than the destination so it doesn't prompt about "remote changed foo
    # which local deleted".
    # We also pass mergeancestor=True when base is the same revision as p1. 2)
    # doesn't matter as there can't possibly be conflicts, but 1) is necessary.
    wctx = wctx or repo[None]
    pctx = wctx.p1()
    base = base or ctx.p1()
    mergeancestor = (
        repo.changelog.isancestor(pctx.node(), ctx.node())
        or pctx.rev() == base.rev()
    )

    stats = _update(
        repo,
        ctx.node(),
        True,
        True,
        base.node(),
        mergeancestor=mergeancestor,
        labels=labels,
        wc=wctx,
    )

    if keepconflictparent and stats.unresolvedcount:
        pother = ctx.node()
    else:
        pother = repo.nullid
        parents = ctx.parents()
        if keepparent and len(parents) == 2 and base in parents:
            parents.remove(base)
            pother = parents[0].node()
    # Never set both parents equal to each other
    if pother == pctx.node():
        pother = repo.nullid

    if wctx.isinmemory():
        wctx.setparents(pctx.node(), pother)
        # fix up dirstate for copies and renames
        copies.graftcopies(wctx, ctx, base)
    else:
        with repo.dirstate.changing_parents(repo):
            repo.setparents(pctx.node(), pother)
            repo.dirstate.write(repo.currenttransaction())
            # fix up dirstate for copies and renames
            copies.graftcopies(wctx, ctx, base)
    return stats


def back_out(ctx, parent=None, wc=None):
    if parent is None:
        if ctx.p2() is not None:
            msg = b"must specify parent of merge commit to back out"
            raise error.ProgrammingError(msg)
        parent = ctx.p1()
    return _update(
        ctx.repo(),
        parent,
        branchmerge=True,
        force=True,
        ancestor=ctx.node(),
        mergeancestor=False,
    )


def purge(
    repo,
    matcher,
    unknown=True,
    ignored=False,
    removeemptydirs=True,
    removefiles=True,
    abortonerror=False,
    noop=False,
    confirm=False,
):
    """Purge the working directory of untracked files.

    ``matcher`` is a matcher configured to scan the working directory -
    potentially a subset.

    ``unknown`` controls whether unknown files should be purged.

    ``ignored`` controls whether ignored files should be purged.

    ``removeemptydirs`` controls whether empty directories should be removed.

    ``removefiles`` controls whether files are removed.

    ``abortonerror`` causes an exception to be raised if an error occurs
    deleting a file or directory.

    ``noop`` controls whether to actually remove files. If not defined, actions
    will be taken.

    ``confirm`` ask confirmation before actually removing anything.

    Returns an iterable of relative paths in the working directory that were
    or would be removed.
    """

    def remove(removefn, path):
        try:
            removefn(path)
        except OSError:
            m = _(b'%s cannot be removed') % path
            if abortonerror:
                raise error.Abort(m)
            else:
                repo.ui.warn(_(b'warning: %s\n') % m)

    # There's no API to copy a matcher. So mutate the passed matcher and
    # restore it when we're done.
    oldtraversedir = matcher.traversedir

    res = []

    try:
        if removeemptydirs:
            directories = []
            matcher.traversedir = directories.append

        status = repo.status(match=matcher, ignored=ignored, unknown=unknown)

        if confirm:
            msg = None
            nb_ignored = len(status.ignored)
            nb_unknown = len(status.unknown)
            if nb_unknown and nb_ignored:
                msg = _(b"permanently delete %d unknown and %d ignored files?")
                msg %= (nb_unknown, nb_ignored)
            elif nb_unknown:
                msg = _(b"permanently delete %d unknown files?")
                msg %= nb_unknown
            elif nb_ignored:
                msg = _(b"permanently delete %d ignored files?")
                msg %= nb_ignored
            elif removeemptydirs:
                dir_count = 0
                for f in directories:
                    if matcher(f) and not repo.wvfs.listdir(f):
                        dir_count += 1
                if dir_count:
                    msg = _(
                        b"permanently delete at least %d empty directories?"
                    )
                    msg %= dir_count
            if msg is None:
                return res
            else:
                msg += b" (yN)$$ &Yes $$ &No"
                if repo.ui.promptchoice(msg, default=1) == 1:
                    raise error.CanceledError(_(b'removal cancelled'))

        if removefiles:
            for f in sorted(status.unknown + status.ignored):
                if not noop:
                    repo.ui.note(_(b'removing file %s\n') % f)
                    remove(repo.wvfs.unlink, f)
                res.append(f)

        if removeemptydirs:
            for f in sorted(directories, reverse=True):
                if matcher(f) and not repo.wvfs.listdir(f):
                    if not noop:
                        repo.ui.note(_(b'removing directory %s\n') % f)
                        remove(repo.wvfs.rmdir, f)
                    res.append(f)

        return res

    finally:
        matcher.traversedir = oldtraversedir
