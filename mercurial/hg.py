# hg.py - repository classes for mercurial
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
# Copyright 2006 Vadim Gelfer <vadim.gelfer@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import posixpath
import shutil
import stat

from .i18n import _
from .node import (
    hex,
    sha1nodeconstants,
    short,
)

from . import (
    bookmarks,
    bundlerepo,
    cmdutil,
    discovery,
    error,
    exchange,
    extensions,
    graphmod,
    localrepo,
    lock,
    logcmdutil,
    logexchange,
    merge as mergemod,
    narrowspec,
    phases,
    requirements,
    scmutil,
    ui as uimod,
    util,
    verify as verifymod,
    vfs as vfsmod,
)
from .cmd_impls import (
    update as up_impl,
)
from .interfaces import repository as repositorymod
from .repo import creation, factory as repo_factory
from .utils import (
    hashutil,
    urlutil,
)


release = lock.release

# shared features
sharedbookmarks = b'bookmarks'


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
    """return default destination of clone if none is given

    >>> defaultdest(b'foo')
    'foo'
    >>> defaultdest(b'/foo/bar')
    'bar'
    >>> defaultdest(b'/')
    ''
    >>> defaultdest(b'')
    ''
    >>> defaultdest(b'http://example.org/')
    ''
    >>> defaultdest(b'http://example.org/foo/')
    'foo'
    """
    path = urlutil.url(source).path
    if not path:
        return b''
    return os.path.basename(os.path.normpath(path))


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


def share(
    ui,
    source,
    dest=None,
    update=True,
    bookmarks=True,
    defaultpath=None,
    relative=False,
):
    '''create a shared repository'''

    not_local_msg = _(b'can only share local repositories')
    if hasattr(source, 'local'):
        if source.local() is None:
            raise error.Abort(not_local_msg)
    elif not repo_factory.is_local(source):
        # XXX why are we getting bytes here ?
        raise error.Abort(not_local_msg)

    if not dest:
        dest = defaultdest(source)
    else:
        dest = urlutil.get_clone_path_obj(ui, dest).loc

    if isinstance(source, bytes):
        source_path = urlutil.get_clone_path_obj(ui, source)
        srcrepo = repo_factory.repository(ui, source_path.loc)
        branches = (source_path.branch, [])
        rev, checkout = urlutil.add_branch_revs(
            srcrepo, srcrepo, branches, None
        )
    else:
        srcrepo = source.local()
        checkout = None

    shareditems = set()
    if bookmarks:
        shareditems.add(sharedbookmarks)

    r = repo_factory.repository(
        ui,
        dest,
        create=True,
        createopts={
            b'sharedrepo': srcrepo,
            b'sharedrelative': relative,
            b'shareditems': shareditems,
        },
    )

    postshare(srcrepo, r, defaultpath=defaultpath)
    r = repo_factory.repository(ui, dest)
    _postshareupdate(r, update, checkout=checkout)
    return r


def _prependsourcehgrc(repo):
    """copies the source repo config and prepend it in current repo .hg/hgrc
    on unshare. This is only done if the share was perfomed using share safe
    method where we share config of source in shares"""
    srcvfs = vfsmod.vfs(repo.sharedpath)
    dstvfs = vfsmod.vfs(repo.path)

    if not srcvfs.exists(b'hgrc'):
        return

    currentconfig = b''
    if dstvfs.exists(b'hgrc'):
        currentconfig = dstvfs.read(b'hgrc')

    with dstvfs(b'hgrc', b'wb') as fp:
        sourceconfig = srcvfs.read(b'hgrc')
        fp.write(b"# Config copied from shared source\n")
        fp.write(sourceconfig)
        fp.write(b'\n')
        fp.write(currentconfig)


def unshare(ui, repo):
    """convert a shared repository to a normal one

    Copy the store data to the repo and remove the sharedpath data.

    Returns a new repository object representing the unshared repository.

    The passed repository object is not usable after this function is
    called.
    """

    with repo.lock():
        # we use locks here because if we race with commit, we
        # can end up with extra data in the cloned revlogs that's
        # not pointed to by changesets, thus causing verify to
        # fail
        destlock = copystore(ui, repo, repo.path)
        with destlock or util.nullcontextmanager():
            if requirements.SHARESAFE_REQUIREMENT in repo.requirements:
                # we were sharing .hg/hgrc of the share source with the current
                # repo. We need to copy that while unsharing otherwise it can
                # disable hooks and other checks
                _prependsourcehgrc(repo)

            sharefile = repo.vfs.join(b'sharedpath')
            util.rename(sharefile, sharefile + b'.old')

            repo.requirements.discard(requirements.SHARED_REQUIREMENT)
            repo.requirements.discard(requirements.RELATIVE_SHARED_REQUIREMENT)
            scmutil.writereporequirements(repo)

    # Removing share changes some fundamental properties of the repo instance.
    # So we instantiate a new repo object and operate on it rather than
    # try to keep the existing repo usable.
    newrepo = repo_factory.repository(repo.baseui, repo.root, create=False)

    # TODO: figure out how to access subrepos that exist, but were previously
    #       removed from .hgsub
    c = newrepo[b'.']
    subs = c.substate
    for s in sorted(subs):
        c.sub(s).unshare()

    localrepo.poisonrepository(repo)

    return newrepo


def postshare(sourcerepo, destrepo, defaultpath=None):
    """Called after a new shared repo is created.

    The new repo only has a requirements file and pointer to the source.
    This function configures additional shared data.

    Extensions can wrap this function and write additional entries to
    destrepo/.hg/shared to indicate additional pieces of data to be shared.
    """
    default = defaultpath or sourcerepo.ui.config(b'paths', b'default')
    if default:
        template = b'[paths]\ndefault = %s\n'
        destrepo.vfs.write(b'hgrc', util.tonativeeol(template % default))
    if requirements.NARROW_REQUIREMENT in sourcerepo.requirements:
        with destrepo.wlock(), destrepo.lock(), destrepo.transaction(
            b"narrow-share"
        ):
            narrowspec.copytoworkingcopy(destrepo)


def _postshareupdate(repo, update, checkout=None):
    """Maybe perform a working directory update after a shared repo is created.

    ``update`` can be a boolean or a revision to update to.
    """
    if not update:
        return

    repo.ui.status(_(b"updating working directory\n"))
    if update is not True:
        checkout = update
    for test in (checkout, b'default', b'tip'):
        if test is None:
            continue
        try:
            uprev = repo.lookup(test)
            break
        except error.RepoLookupError:
            continue
    _update(repo, uprev)


def copystore(ui, srcrepo, destpath):
    """copy files from store of srcrepo in destpath

    returns destlock
    """
    destlock = None
    try:
        hardlink = None
        topic = _(b'linking') if hardlink else _(b'copying')
        with ui.makeprogress(topic, unit=_(b'files')) as progress:
            num = 0
            srcpublishing = srcrepo.publishing()
            srcvfs = vfsmod.vfs(srcrepo.sharedpath)
            dstvfs = vfsmod.vfs(destpath)
            for f in srcrepo.store.copylist():
                if srcpublishing and f.endswith(b'phaseroots'):
                    continue
                dstbase = os.path.dirname(f)
                if dstbase and not dstvfs.exists(dstbase):
                    dstvfs.mkdir(dstbase)
                if srcvfs.exists(f):
                    if f.endswith(b'data'):
                        # 'dstbase' may be empty (e.g. revlog format 0)
                        lockfile = os.path.join(dstbase, b"lock")
                        # lock to avoid premature writing to the target
                        destlock = lock.lock(dstvfs, lockfile)
                    hardlink, n = util.copyfiles(
                        srcvfs.join(f), dstvfs.join(f), hardlink, progress
                    )
                    num += n
            if hardlink:
                ui.debug(b"linked %d files\n" % num)
            else:
                ui.debug(b"copied %d files\n" % num)
        return destlock
    except:  # re-raises
        release(destlock)
        raise


def clonewithshare(
    ui,
    peeropts,
    sharepath,
    source,
    srcpeer,
    dest,
    pull=False,
    rev=None,
    update=True,
    stream=False,
):
    """Perform a clone using a shared repo.

    The store for the repository will be located at <sharepath>/.hg. The
    specified revisions will be cloned or pulled from "source". A shared repo
    will be created at "dest" and a working copy will be created if "update" is
    True.
    """
    revs = None
    if rev:
        if not srcpeer.capable(b'lookup'):
            raise error.Abort(
                _(
                    b"src repository does not support "
                    b"revision lookup and so doesn't "
                    b"support clone by revision"
                )
            )

        # TODO this is batchable.
        remoterevs = []
        for r in rev:
            with srcpeer.commandexecutor() as e:
                remoterevs.append(
                    e.callcommand(
                        b'lookup',
                        {
                            b'key': r,
                        },
                    ).result()
                )
        revs = remoterevs

    # Obtain a lock before checking for or cloning the pooled repo otherwise
    # 2 clients may race creating or populating it.
    pooldir = os.path.dirname(sharepath)
    # lock class requires the directory to exist.
    try:
        util.makedir(pooldir, False)
    except FileExistsError:
        pass

    poolvfs = vfsmod.vfs(pooldir)
    basename = os.path.basename(sharepath)

    with lock.lock(poolvfs, b'%s.lock' % basename):
        if os.path.exists(sharepath):
            ui.status(
                _(b'(sharing from existing pooled repository %s)\n') % basename
            )
        else:
            ui.status(
                _(b'(sharing from new pooled repository %s)\n') % basename
            )
            # Always use pull mode because hardlinks in share mode don't work
            # well. Never update because working copies aren't necessary in
            # share mode.
            clone(
                ui,
                peeropts,
                source,
                dest=sharepath,
                pull=True,
                revs=rev,
                update=False,
                stream=stream,
            )

    # Resolve the value to put in [paths] section for the source.
    if repo_factory.is_local(source):
        defaultpath = util.abspath(urlutil.urllocalpath(source))
    else:
        defaultpath = source

    sharerepo = repo_factory.repository(ui, path=sharepath)
    destrepo = share(
        ui,
        sharerepo,
        dest=dest,
        update=False,
        bookmarks=False,
        defaultpath=defaultpath,
    )

    # We need to perform a pull against the dest repo to fetch bookmarks
    # and other non-store data that isn't shared by default. In the case of
    # non-existing shared repo, this means we pull from the remote twice. This
    # is a bit weird. But at the time it was implemented, there wasn't an easy
    # way to pull just non-changegroup data.
    exchange.pull(destrepo, srcpeer, heads=revs)

    _postshareupdate(destrepo, update)

    return srcpeer, repo_factory.peer(ui, peeropts, dest)


# Recomputing caches is often slow on big repos, so copy them.
def _copycache(srcrepo, dstcachedir, fname):
    """copy a cache from srcrepo to destcachedir (if it exists)"""
    srcfname = srcrepo.cachevfs.join(fname)
    dstfname = os.path.join(dstcachedir, fname)
    if os.path.exists(srcfname):
        if not os.path.exists(dstcachedir):
            os.mkdir(dstcachedir)
        util.copyfile(srcfname, dstfname)


def clone(
    ui,
    peeropts,
    source,
    dest=None,
    pull=False,
    revs=None,
    update=True,
    stream=False,
    branch=None,
    shareopts=None,
    storeincludepats=None,
    storeexcludepats=None,
    depth=None,
):
    """Make a copy of an existing repository.

    Create a copy of an existing repository in a new directory.  The
    source and destination are URLs, as passed to the repository
    function.  Returns a pair of repository peers, the source and
    newly created destination.

    The location of the source is added to the new repository's
    .hg/hgrc file, as the default to be used for future pulls and
    pushes.

    If an exception is raised, the partly cloned/updated destination
    repository will be deleted.

    Arguments:

    source: repository object or URL

    dest: URL of destination repository to create (defaults to base
    name of source repository)

    pull: always pull from source repository, even in local case or if the
    server prefers streaming

    stream: stream raw data uncompressed from repository (fast over
    LAN, slow over WAN)

    revs: revision to clone up to (implies pull=True)

    update: update working directory after clone completes, if
    destination is local repository (True means update to default rev,
    anything else is treated as a revision)

    branch: branches to clone

    shareopts: dict of options to control auto sharing behavior. The "pool" key
    activates auto sharing mode and defines the directory for stores. The
    "mode" key determines how to construct the directory name of the shared
    repository. "identity" means the name is derived from the node of the first
    changeset in the repository. "remote" means the name is derived from the
    remote's path/URL. Defaults to "identity."

    storeincludepats and storeexcludepats: sets of file patterns to include and
    exclude in the repository copy, respectively. If not defined, all files
    will be included (a "full" clone). Otherwise a "narrow" clone containing
    only the requested files will be performed. If ``storeincludepats`` is not
    defined but ``storeexcludepats`` is, ``storeincludepats`` is assumed to be
    ``path:.``. If both are empty sets, no files will be cloned.
    """

    if isinstance(source, bytes):
        src_path = urlutil.get_clone_path_obj(ui, source)
        if src_path is None:
            srcpeer = repo_factory.peer(ui, peeropts, b'')
            origsource = source = b''
            branches = (None, branch or [])
        else:
            srcpeer = repo_factory.peer(ui, peeropts, src_path)
            origsource = src_path.rawloc
            branches = (src_path.branch, branch or [])
            source = src_path.loc
    else:
        if hasattr(source, 'peer'):
            srcpeer = source.peer()  # in case we were called with a localrepo
        else:
            srcpeer = source
        branches = (None, branch or [])
        # XXX path: simply use the peer `path` object when this become available
        origsource = source = srcpeer.url()
    srclock = destlock = destwlock = cleandir = None
    destpeer = None
    try:
        revs, checkout = urlutil.add_branch_revs(
            srcpeer, srcpeer, branches, revs
        )

        if dest is None:
            dest = defaultdest(source)
            if dest:
                ui.status(_(b"destination directory: %s\n") % dest)
        else:
            dest_path = urlutil.get_clone_path_obj(ui, dest)
            if dest_path is not None:
                dest = dest_path.rawloc
            else:
                dest = b''

        dest = urlutil.urllocalpath(dest)
        source = urlutil.urllocalpath(source)

        if not dest:
            raise error.InputError(_(b"empty destination path is not valid"))

        destvfs = vfsmod.vfs(dest, expandpath=True)
        if destvfs.lexists():
            if not destvfs.isdir():
                raise error.InputError(
                    _(b"destination '%s' already exists") % dest
                )
            elif destvfs.listdir():
                raise error.InputError(
                    _(b"destination '%s' is not empty") % dest
                )

        createopts = {}
        narrow = False

        if storeincludepats is not None:
            narrowspec.validatepatterns(storeincludepats)
            narrow = True

        if storeexcludepats is not None:
            narrowspec.validatepatterns(storeexcludepats)
            narrow = True

        if narrow:
            # Include everything by default if only exclusion patterns defined.
            if storeexcludepats and not storeincludepats:
                storeincludepats = {b'path:.'}

            createopts[b'narrowfiles'] = True

        if depth:
            createopts[b'shallowfilestore'] = True

        if srcpeer.capable(b'lfs-serve'):
            # Repository creation honors the config if it disabled the extension, so
            # we can't just announce that lfs will be enabled.  This check avoids
            # saying that lfs will be enabled, and then saying it's an unknown
            # feature.  The lfs creation option is set in either case so that a
            # requirement is added.  If the extension is explicitly disabled but the
            # requirement is set, the clone aborts early, before transferring any
            # data.
            createopts[b'lfs'] = True

            if b'lfs' in extensions.disabled():
                ui.status(
                    _(
                        b'(remote is using large file support (lfs), but it is '
                        b'explicitly disabled in the local configuration)\n'
                    )
                )
            else:
                ui.status(
                    _(
                        b'(remote is using large file support (lfs); lfs will '
                        b'be enabled for this repository)\n'
                    )
                )

        shareopts = shareopts or {}
        sharepool = shareopts.get(b'pool')
        sharenamemode = shareopts.get(b'mode')
        if sharepool and repo_factory.is_local(dest):
            sharepath = None
            if sharenamemode == b'identity':
                # Resolve the name from the initial changeset in the remote
                # repository. This returns nullid when the remote is empty. It
                # raises RepoLookupError if revision 0 is filtered or otherwise
                # not available. If we fail to resolve, sharing is not enabled.
                try:
                    with srcpeer.commandexecutor() as e:
                        rootnode = e.callcommand(
                            b'lookup',
                            {
                                b'key': b'0',
                            },
                        ).result()

                    if rootnode != sha1nodeconstants.nullid:
                        sharepath = os.path.join(sharepool, hex(rootnode))
                    else:
                        ui.status(
                            _(
                                b'(not using pooled storage: '
                                b'remote appears to be empty)\n'
                            )
                        )
                except error.RepoLookupError:
                    ui.status(
                        _(
                            b'(not using pooled storage: '
                            b'unable to resolve identity of remote)\n'
                        )
                    )
            elif sharenamemode == b'remote':
                sharepath = os.path.join(
                    sharepool, hex(hashutil.sha1(source).digest())
                )
            else:
                raise error.Abort(
                    _(b'unknown share naming mode: %s') % sharenamemode
                )

            # TODO this is a somewhat arbitrary restriction.
            if narrow:
                ui.status(
                    _(b'(pooled storage not supported for narrow clones)\n')
                )
                sharepath = None

            if sharepath:
                return clonewithshare(
                    ui,
                    peeropts,
                    sharepath,
                    source,
                    srcpeer,
                    dest,
                    pull=pull,
                    rev=revs,
                    update=update,
                    stream=stream,
                )

        srcrepo = srcpeer.local()

        abspath = origsource
        if repo_factory.is_local(origsource):
            abspath = util.abspath(urlutil.urllocalpath(origsource))

        if repo_factory.is_local(dest):
            if os.path.exists(dest):
                # only clean up directories we create ourselves
                hgdir = os.path.realpath(os.path.join(dest, b".hg"))
                cleandir = hgdir
            else:
                cleandir = dest

        copy = False
        if (
            srcrepo
            and srcrepo.cancopy()
            and repo_factory.is_local(dest)
            and not phases.hassecret(srcrepo)
        ):
            copy = not pull and not revs

        # TODO this is a somewhat arbitrary restriction.
        if narrow:
            copy = False

        if copy:
            try:
                # we use a lock here because if we race with commit, we
                # can end up with extra data in the cloned revlogs that's
                # not pointed to by changesets, thus causing verify to
                # fail
                srclock = srcrepo.lock(wait=False)
            except error.LockError:
                copy = False

        if copy:
            srcrepo.hook(b'preoutgoing', throw=True, source=b'clone')

            destrootpath = urlutil.urllocalpath(dest)
            dest_reqs = creation.clone_requirements(ui, createopts, srcrepo)
            localrepo.createrepository(
                ui,
                destrootpath,
                requirements=dest_reqs,
            )
            destrepo = localrepo.makelocalrepository(ui, destrootpath)

            destwlock = destrepo.wlock()
            destlock = destrepo.lock()
            from . import streamclone  # avoid cycle

            streamclone.local_copy(srcrepo, destrepo)

            # we need to re-init the repo after manually copying the data
            # into it
            destpeer = repo_factory.peer(srcrepo, peeropts, dest)

            # make the peer aware that is it already locked
            #
            # important:
            #
            #    We still need to release that lock at the end of the function
            if destrepo.dirstate._dirty:
                msg = "dirstate dirty after stream clone"
                raise error.ProgrammingError(msg)
            destwlock = destpeer.local().wlock(steal_from=destwlock)
            destlock = destpeer.local().lock(steal_from=destlock)

            srcrepo.hook(
                b'outgoing',
                source=b'clone',
                node=srcrepo.nodeconstants.nullhex,
            )
        else:
            try:
                # only pass ui when no srcrepo
                destpeer = repo_factory.peer(
                    srcrepo or ui,
                    peeropts,
                    dest,
                    create=True,
                    createopts=createopts,
                )
            except FileExistsError:
                cleandir = None
                raise error.Abort(_(b"destination '%s' already exists") % dest)

            if revs:
                if not srcpeer.capable(b'lookup'):
                    raise error.Abort(
                        _(
                            b"src repository does not support "
                            b"revision lookup and so doesn't "
                            b"support clone by revision"
                        )
                    )

                # TODO this is batchable.
                remoterevs = []
                for rev in revs:
                    with srcpeer.commandexecutor() as e:
                        remoterevs.append(
                            e.callcommand(
                                b'lookup',
                                {
                                    b'key': rev,
                                },
                            ).result()
                        )
                revs = remoterevs

                checkout = revs[0]
            else:
                revs = None
            local = destpeer.local()
            if local:
                if narrow:
                    with local.wlock(), local.lock(), local.transaction(
                        b'narrow-clone'
                    ):
                        local.setnarrowpats(storeincludepats, storeexcludepats)
                        narrowspec.copytoworkingcopy(local)

                u = urlutil.url(abspath)
                defaulturl = bytes(u)
                local.ui.setconfig(b'paths', b'default', defaulturl, b'clone')
                if not stream:
                    if pull:
                        stream = False
                    else:
                        stream = None
                # internal config: ui.quietbookmarkmove
                overrides = {(b'ui', b'quietbookmarkmove'): True}
                with local.ui.configoverride(overrides, b'clone'):
                    exchange.pull(
                        local,
                        srcpeer,
                        heads=revs,
                        streamclonerequested=stream,
                        includepats=storeincludepats,
                        excludepats=storeexcludepats,
                        depth=depth,
                    )
            elif srcrepo:
                # TODO lift restriction once exchange.push() accepts narrow
                # push.
                if narrow:
                    raise error.Abort(
                        _(
                            b'narrow clone not available for '
                            b'remote destinations'
                        )
                    )

                exchange.push(
                    srcrepo,
                    destpeer,
                    revs=revs,
                    bookmarks=srcrepo._bookmarks.keys(),
                )
            else:
                raise error.Abort(
                    _(b"clone from remote to remote not supported")
                )

        cleandir = None

        destrepo = destpeer.local()
        if destrepo:
            template = uimod.samplehgrcs[b'cloned']
            u = urlutil.url(abspath)
            u.passwd = None
            defaulturl = bytes(u)
            destrepo.vfs.write(b'hgrc', util.tonativeeol(template % defaulturl))
            destrepo.ui.setconfig(b'paths', b'default', defaulturl, b'clone')

            if ui.configbool(b'experimental', b'remotenames'):
                logexchange.pullremotenames(destrepo, srcpeer)

            if update:
                if update is not True:
                    with srcpeer.commandexecutor() as e:
                        checkout = e.callcommand(
                            b'lookup',
                            {
                                b'key': update,
                            },
                        ).result()

                uprev = None
                status = None
                if checkout is not None:
                    # Some extensions (at least hg-git and hg-subversion) have
                    # a peer.lookup() implementation that returns a name instead
                    # of a nodeid. We work around it here until we've figured
                    # out a better solution.
                    if len(checkout) == 20 and checkout in destrepo:
                        uprev = checkout
                    elif scmutil.isrevsymbol(destrepo, checkout):
                        uprev = scmutil.revsymbol(destrepo, checkout).node()
                    else:
                        if update is not True:
                            try:
                                uprev = destrepo.lookup(update)
                            except error.RepoLookupError:
                                pass
                if uprev is None:
                    try:
                        if destrepo._activebookmark:
                            uprev = destrepo.lookup(destrepo._activebookmark)
                            update = destrepo._activebookmark
                        else:
                            uprev = destrepo._bookmarks[b'@']
                            update = b'@'
                        bn = destrepo[uprev].branch()
                        if bn == b'default':
                            status = _(b"updating to bookmark %s\n" % update)
                        else:
                            status = (
                                _(b"updating to bookmark %s on branch %s\n")
                            ) % (update, bn)
                    except KeyError:
                        try:
                            uprev = destrepo.branchtip(b'default')
                        except error.RepoLookupError:
                            uprev = destrepo.lookup(b'tip')
                if not status:
                    bn = destrepo[uprev].branch()
                    status = _(b"updating to branch %s\n") % bn
                destrepo.ui.status(status)
                _update(destrepo, uprev)
                if update in destrepo._bookmarks:
                    bookmarks.activate(destrepo, update)
            if destlock is not None:
                release(destlock)
                destlock = None
            if destwlock is not None:
                release(destwlock)
                destwlock = None
            # here is a tiny windows were someone could end up writing the
            # repository before the cache are sure to be warm. This is "fine"
            # as the only "bad" outcome would be some slowness. That potential
            # slowness already affect reader.
            with destrepo.lock():
                destrepo.updatecaches(caches=repositorymod.CACHES_POST_CLONE)
    finally:
        release(srclock, destlock, destwlock)
        if cleandir is not None:
            shutil.rmtree(cleandir, True)
        if srcpeer is not None:
            srcpeer.close()
        if destpeer and destpeer.local() is None:
            destpeer.close()
    return srcpeer, destpeer


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


def update(*args, **kwargs):
    return up_impl.update(*args, **kwargs)


def updatetotally(*args, **kwargs):
    return up_impl.update_totally(*args, **kwargs)


def clean(*args, **kwargs):
    return up_impl.clean(*args, **kwargs)


def merge(*args, **kwargs):
    return up_impl.merge(*args, **kwargs)


def abortmerge(*args, **kwargs):
    return up_impl.abort_merge(*args, **kwargs)


# naming conflict in clone()
_update = update


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
            repo, other, branches, opts.get(b'rev')
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
