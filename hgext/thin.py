# experimental extension for thin repository
"""provide thin working with a remote backend (experimental)

This extensions is at an early stage of development."""

from __future__ import annotations

import contextlib
import hashlib
import weakref

from mercurial.interfaces.types import (
    HgPathT,
    MatcherT,
    NodeIdT,
    RepoT,
    StatusT,
    UiT,
    VfsT,
)

from mercurial.node import (
    sha1nodeconstants,
)

from mercurial.i18n import _

from mercurial import (
    cmdutil,
    context,
    dirstate as dirstate_mod,
    error,
    exthelper,
    hook as hookmod,
    localrepo,
    lock as lockmod,
    match as matchmod,
    requirements as req_mod,
    sparse,
    util,
    vfs as vfsmod,
)

from mercurial.repo import (
    factory,
    requirements as req_util,
)


eh = exthelper.exthelper()
cmdtable = eh.cmdtable
configtable = eh.configtable
extsetup = eh.finalextsetup
uisetup = eh.finaluisetup
filesetpredicate = eh.filesetpredicate
reposetup = eh.finalreposetup
templatekeyword = eh.templatekeyword


THIN_REQUIREMENT = b'exp-v0-thin'
THIN_FEATURE = THIN_REQUIREMENT + b'-feature'  # keep them in sync but different


@eh.uisetup
def _register_requirement(ui):
    req_util.BASE_SUPPORTED.add(THIN_REQUIREMENT)
    req_mod.WORKING_DIR_REQUIREMENTS.add(THIN_REQUIREMENT)
    req_mod.STREAM_IGNORABLE_REQUIREMENTS.add(THIN_REQUIREMENT)


class ThinRepo:
    """An object that behavior enough like a localrepo object for Thin to work

    The extensions is still at a quite early stage of development so assume
    that anything not explicilty tested is broken.
    """

    def __init__(
        self,
        baseui,
        ui,
        origroot: bytes,
        wdirvfs: vfsmod.vfs,
        hgvfs: vfsmod.vfs,
        requirements,
        supportedrequirements,
        features,
    ):
        self._base_ui = baseui
        ui.setconfig(
            b"commands",
            b"commit.report-head-changes",
            False,
            source=b'thin',
        )
        self.ui = ui

        self.baseui = baseui
        self.ui = ui
        self.origroot = origroot
        # vfs rooted at working directory.
        self.wvfs = wdirvfs
        self.root = wdirvfs.base
        # vfs rooted at .hg/. Used to access most non-store paths.
        self.vfs = hgvfs
        self.path = hgvfs.base
        self.requirements = requirements
        self.nodeconstants = sha1nodeconstants
        self.nullid = self.nodeconstants.nullid

        self.supported = supportedrequirements
        self.features = features
        self.filtername = None
        self._wlockref = None
        self._dirstate = None

        backend_url = self.vfs.read(b"thin-backend")
        assert backend_url.startswith(b"local://")
        repo_path = backend_url[len(b"local://") : -1]
        self._backend = LocalBackend(self._base_ui, repo_path)

    def __getitem__(self, node):
        return ThinWcCtx(self)

    def local(self):
        return True

    def filtered(self, name, visibilityexceptions=None) -> ThinRepo:
        return self

    def unfiltered(self) -> ThinRepo:
        return self

    def close(self):
        pass
        # XXX write cache

    @util.propertycache
    def _narrowmatch(self):
        # XXX Actually support narrow at some point
        return matchmod.always()

    def narrowmatch(self, match=None, includeexact=False):
        """matcher corresponding the the repo's narrowspec

        If `match` is given, then that will be intersected with the narrow
        matcher.

        If `includeexact` is True, then any exact matches from `match` will
        be included even if they're outside the narrowspec.
        """
        assert self._narrowmatch.always()
        if match:
            return match
        else:
            return self._narrowmatch

    @localrepo.unfilteredpropertycache
    def dirstate(self):
        if self._dirstate is None:
            self._dirstate = self._makedirstate()
        else:
            self._dirstate.refresh()
        return self._dirstate

    def _makedirstate(self):
        """Extension point for wrapping the dirstate per-repo."""
        sparsematchfn = None
        if sparse.use_sparse(self):
            sparsematchfn = lambda: sparse.matcher(self)
        v2_req = req_mod.DIRSTATE_V2_REQUIREMENT
        th = req_mod.DIRSTATE_TRACKED_HINT_V1
        use_dirstate_v2 = v2_req in self.requirements
        use_tracked_hint = th in self.requirements

        return dirstate_mod.dirstate(
            self.vfs,
            self.ui,
            self.root,
            lambda node: node,  # XXX assume anynode is valid
            sparsematchfn,
            self.nodeconstants,
            use_dirstate_v2,
            use_tracked_hint=use_tracked_hint,
        )

    def invalidatedirstate(self):
        """Invalidates the dirstate, causing the next call to dirstate
        to check if it was modified since the last time it was read,
        rereading it if it has.

        This is different to dirstate.invalidate() that it doesn't always
        rereads the dirstate. Use dirstate.invalidate() if you want to
        explicitly read the dirstate again (i.e. restoring it to a previous
        known good state)."""
        unfi = self.unfiltered()
        if 'dirstate' in unfi.__dict__:
            self.dirstate.invalidate_cwd()
            assert not self.dirstate.is_changing_any
            del unfi.__dict__['dirstate']

    def _lock(
        self,
        vfs,
        lockname,
        wait,
        releasefn,
        acquirefn,
        desc,
        steal_from=None,
    ) -> lockmod.lock:
        timeout = 0
        warntimeout = 0
        if wait:
            timeout = self.ui.configint(b"ui", b"timeout")
            warntimeout = self.ui.configint(b"ui", b"timeout.warn")
        # internal config: ui.signal-safe-lock
        signalsafe = self.ui.configbool(b'ui', b'signal-safe-lock')
        sync_file = self.ui.config(b'devel', b'lock-wait-sync-file')
        if not sync_file:
            sync_file = None

        if steal_from is None:
            l = lockmod.trylock(
                self.ui,
                vfs,
                lockname,
                timeout,
                warntimeout,
                releasefn=releasefn,
                acquirefn=acquirefn,
                desc=desc,
                signalsafe=signalsafe,
                devel_wait_sync_file=sync_file,
            )
        else:
            l = lockmod.steal_lock(
                self.ui,
                vfs,
                lockname,
                steal_from,
                releasefn=releasefn,
                acquirefn=acquirefn,
                desc=desc,
                signalsafe=signalsafe,
            )

        return l

    @util.rust_tracing_span("wlock")
    def wlock(self, wait=True, steal_from=None) -> lockmod.lock:
        """Lock the non-store parts of the repository (everything under
        .hg except .hg/store) and return a weak reference to the lock.

        Use this before modifying files in .hg.

        If both 'lock' and 'wlock' must be acquired, ensure you always acquires
        'wlock' first to avoid a dead-lock hazard.

        The steal_from argument is  used during local clone when reloading a
        repository. If we could remove the need for this during copy clone, we
        could remove this function.
        """
        l = self._currentlock(self._wlockref)
        if l is not None:
            if steal_from is not None:
                msg = "cannot steal wlock if already locked"
                raise error.ProgrammingError(msg)
            l.lock()
            return l

        if steal_from is None:
            self.hook(b'prewlock', throw=True)

        def unlock():
            if self.dirstate.is_changing_any:
                self.dirstate.invalidate()
                msg = b"wlock release in the middle of a changing parents"
                raise error.ProgrammingError(msg)
            else:
                if self.dirstate._dirty:
                    msg = b"dirty dirstate on wlock release"
                    raise error.ProgrammingError(msg)
                self.dirstate.write(None)

            unfi = self.unfiltered()
            if 'dirstate' in unfi.__dict__:
                del unfi.__dict__['dirstate']

        l = self._lock(
            vfs=self.vfs,
            lockname=b"wlock",
            wait=wait,
            releasefn=unlock,
            acquirefn=self.invalidatedirstate,
            desc=_(b'working directory of %s') % self.origroot,
            steal_from=steal_from,
        )
        self._wlockref = weakref.ref(l)
        return l

    def _currentlock(
        self,
        lockref: weakref.ref[lockmod.lock] | None,
    ) -> lockmod.lock | None:
        """Returns the lock if it's held, or None if it's not."""
        if lockref is None or (l := lockref()) is None:
            return None
        if not l.held:
            return None
        return l

    def currentwlock(self) -> lockmod.lock | None:
        """Returns the wlock if it's held, or None if it's not."""
        return self._currentlock(self._wlockref)

    def currenttransaction(self):
        return None

    def hook(self, name, throw=False, **args):
        """Call a hook, passing this repo instance.

        This a convenience method to aid invoking hooks. Extensions likely
        won't call this unless they have registered a custom hook or are
        replacing code that is expected to call a hook.
        """
        return hookmod.hook(self.ui, self, name, throw, **args)

    @contextlib.contextmanager
    def lock(self):
        # Can can't reasonably lock remotely, we have to rely on atomic command
        # on the backend side.
        yield

    def getcwd(self) -> bytes:
        return self.dirstate.getcwd()

    def pathto(self, f: bytes, cwd: bytes | None = None) -> bytes:
        return self.dirstate.pathto(f, cwd)

    def commit(
        self,
        text=b"",
        user=None,
        date=None,
        match=None,
        force=False,
        editor=None,
        extra=None,
    ):
        """Add a new revision to current repository.

        Revision information is gathered from the working directory,
        match can be used to filter the committed files. If editor is
        supplied, it is called to get a commit message.
        """
        status = self.status()

        files = {}

        for path in status.removed:
            files[path] = None
        for path in status.modified + status.added:
            files[path] = self.wvfs.tryread(path)
        assert self.dirstate.p2() == self.nodeconstants.nullid
        # TODO:
        # - sending symlinks information
        # - sending exec-bits information
        # - sending copies informatin
        return self._backend.commit(
            p1_node=self.dirstate.p1(),
            user=user,
            date=date,
            extra=extra,
            description=text,
            files=files,
        )

    def status(
        self,
        node1=b'.',
        node2=None,
        match: MatcherT | None = None,
        ignored: bool = False,
        clean: bool = False,
        unknown: bool = False,
        listsubrepos: bool = False,
        empty_dirs_keep_files: bool = False,
    ) -> StatusT:
        # XXX only work for working copy status
        assert not self.wvfs.tryread(b'.hgsub')
        dirstate = self.dirstate
        # XXX narrow matcher
        if match is None:
            match = matchmod.alwaysmatcher()
        with dirstate.running_status(self):
            cmp, s, mtime_boundary = dirstate.status(
                match,
                subrepos=[],
                ignored=ignored,
                clean=clean,
                unknown=unknown,
                empty_dirs_keep_files=empty_dirs_keep_files,
            )

            # check for any possibly clean files
            if cmp:
                # for now a cheap version of context._checklookup
                #
                # XXX ignoring mode
                # XXX ignoring deleted file
                digests = {}
                for path in cmp:
                    with self.wvfs(path) as f:
                        d = file_digest(f, "sha256").digest()
                    digests[path] = d

                assert dirstate.p2() == self.nodeconstants.nullid
                are_clean = self._backend.are_clean(dirstate.p1(), digests)
                for f, is_clean in are_clean.items():
                    if not is_clean:
                        s.modified.append(f)
                    elif clean:
                        s.clean.append(f)
                # XXX for now we skip context._poststatusfixup as the working copy
                # is dead after the commit anyway.
        return s


class ThinWcCtx(context.workingctx):
    def __init__(self, repo):
        self._repo = repo

    def branch(self):
        return b'default'

    def repo(self):
        return self._repo

    def is_merge(self):
        return False

    def match(
        self,
        pats=None,
        include=None,
        exclude=None,
        default: bytes = b'glob',
        listsubrepos: bool = False,
        badfn=None,
        cwd: bytes | None = None,
    ):
        r = self._repo
        if not cwd:
            cwd = r.getcwd()

        # Only a case insensitive filesystem needs magic to translate user input
        # to actual case in the filesystem.
        icasefs = not util.fscasesensitive(r.root)
        return matchmod.match(
            r.root,
            cwd,
            pats,
            include,
            exclude,
            default,
            auditor=None,
            ctx=self,
            listsubrepos=listsubrepos,
            badfn=badfn,
            icasefs=icasefs,
        )

    @property
    def substate(self):
        return {}

    def hasdir(self, path: HgPathT) -> bool:
        return self._repo.wvfs.isdir(path)


def filectxfn_from_dict(files):
    def getfilectx(repo, memctx, path: bytes):
        data = files.get(path)
        if data is None:
            return None
        return context.memfilectx(
            repo,
            memctx,
            path,
            data,
        )

    return getfilectx


class LocalBackend:
    def __init__(self, ui, local_path):
        self._repo = factory.repository(ui, local_path)

    def are_clean(self, p1_node, file_digests) -> dict:
        ctx = self._repo[p1_node]
        are_clean = {}
        for f, d in file_digests.items():
            are_clean[f] = hashlib.sha256(ctx[f].data()).digest() == d
        return are_clean

    # XXX files as a dict is obviously too simple, we loose exec, symlink and
    # XXX copy info
    def commit(
        self,
        p1_node,
        user,
        date,
        extra,
        description,
        files,
    ) -> NodeIdT | None:
        if not files:
            return None
        with self._repo.lock(), self._repo.transaction(b"remote-commit"):
            ctx = context.memctx(
                self._repo,
                [p1_node, self._repo.nodeconstants.nullid],
                text=description,
                files=sorted(files.keys()),
                filectxfn=filectxfn_from_dict(files),
                user=user,
                date=date,
                extra=extra,
            )
            return self._repo.commitctx(ctx)


class _FakeRepo:
    """Awful hack to get to a minimal version faster"""

    def currentwlock(self):
        return self  # anything but None

    def currenttransaction(self):
        return None


@eh.command(
    b'devel::create-thin-wc',
    [],
    b'devel::create-thin-wc THIN_WC_PATH',
)
def create_thin_wc(ui, repo, root):
    # the files
    # a .hg
    # a dirstate
    # special requirements
    # pointer to the "remote backend"
    requirements = [
        req_mod.DIRSTATE_V2_REQUIREMENT,
        req_mod.DIRSTATE_TRACKED_HINT_V1,
        req_mod.SHARESAFE_REQUIREMENT,
        THIN_REQUIREMENT,
    ]

    sparsematchfn = None
    if sparse.use_sparse(repo):
        sparsematchfn = lambda: sparse.matcher(repo)
        requirements.append(req_mod.SPARSE_REQUIREMENT)
    vfs = vfsmod.vfs(root + b"/.hg", expandpath=True, realpath=True)
    vfs.write(b"requires", b"\n".join(requirements))
    vfs.write(b"thin-backend", b"local://%s\n" % repo.root)

    wvfs = vfsmod.vfs(root, expandpath=True, realpath=True)

    dirstate = dirstate_mod.dirstate(
        vfs,
        ui,
        root,
        validate=lambda node: node,
        sparsematchfn=None,
        nodeconstants=repo.nodeconstants,
        use_dirstate_v2=sparsematchfn,
        use_tracked_hint=True,
    )

    target_rev = repo[b'.']
    with dirstate.changing_parents(_FakeRepo()):
        for filename in target_rev:
            if sparsematchfn is None or sparsematchfn().matchfn(filename):
                file_dir = wvfs.dirname(filename)
                wvfs.makedirs(file_dir)
                # XXX current code ignore symlink entirely
                wvfs.write(filename, target_rev[filename].data())
                # XXX not passing `parentfiledata` ot `update_file` will result
                # in all file being in an ambiguous state
                dirstate.update_file(filename, True, True)

        dirstate.setparents(target_rev.node(), repo.nodeconstants.nullid)
    dirstate.write(tr=None)


@eh.wrapfunction(localrepo, "_read_store_requirements")
def wrap_read_store_requirements(
    orig,
    requirements: set[bytes],
    storevfs: VfsT,
) -> set[bytes]:
    if THIN_REQUIREMENT in requirements:
        return set()
    return orig(requirements, storevfs)


@eh.wrapfunction(localrepo, "_thin_repo_hook")
def wrap_thin_repo_hook(
    orig,
    baseui: UiT,
    ui: UiT,
    origroot: HgPathT,
    wdirvfs: VfsT,
    hgvfs: VfsT,
    requirements: set[bytes],
    supportedrequirements: set[bytes],
    features: set[bytes],
):
    """Create a local repository object.

    Given arguments needed to construct a local repository, this function
    performs various early repository loading functionality (such as reading
    the ``.hg/requires`` and ``.hg/hgrc`` files), validates that the repository
    can be opened, and returns an install of `localrepository`.
    """
    if THIN_REQUIREMENT not in requirements:
        return orig(
            baseui=baseui,
            ui=ui,
            origroot=origroot,
            wdirvfs=wdirvfs,
            hgvfs=hgvfs,
            requirements=requirements,
            supportedrequirements=supportedrequirements,
            features=features,
        )

    features.add(THIN_FEATURE)

    return ThinRepo(
        baseui=baseui,
        ui=ui,
        origroot=origroot,
        wdirvfs=wdirvfs,
        hgvfs=hgvfs,
        requirements=requirements,
        supportedrequirements=supportedrequirements,
        features=features,
    )


@eh.wrapfunction(cmdutil, "may_use_commit_status")
def wrap_may_use_commit_status(orig, repo: RepoT):
    """skip calling cmdutil.commitstatus on this repo

    Commitstatus use information currently unavailable on Thin repo.
    """
    if THIN_FEATURE in repo.features:
        return False
    return orig(repo)


# Imported from python 3.11's hashlib.py
# Remove and just call hashlib.file_digest directly once hg drops support for
# pythons older than 3.11
def file_digest(fileobj, digest, /, *, _bufsize=2**18):
    """Hash the contents of a file-like object. Returns a digest object.

    *fileobj* must be a file-like object opened for reading in binary mode.
    It accepts file objects from open(), io.BytesIO(), and SocketIO objects.
    The function may bypass Python's I/O and use the file descriptor *fileno*
    directly.

    *digest* must either be a hash algorithm name as a *str*, a hash
    constructor, or a callable that returns a hash object.
    """
    # On Linux we could use AF_ALG sockets and sendfile() to archive zero-copy
    # hashing with hardware acceleration.
    if isinstance(digest, str):
        digestobj = hashlib.new(digest)
    else:
        digestobj = digest()

    if hasattr(fileobj, "getbuffer"):
        # io.BytesIO object, use zero-copy buffer
        digestobj.update(fileobj.getbuffer())
        return digestobj

    # Only binary files implement readinto().
    if not (
        hasattr(fileobj, "readinto")
        and hasattr(fileobj, "readable")
        and fileobj.readable()
    ):
        raise ValueError(
            f"'{fileobj!r}' is not a file-like object in binary reading mode."
        )

    # binary file, socket.SocketIO object
    # Note: socket I/O uses different syscalls than file I/O.
    buf = bytearray(_bufsize)  # Reusable buffer to reduce allocations.
    view = memoryview(buf)
    while True:
        size = fileobj.readinto(buf)
        if size == 0:
            break  # EOF
        digestobj.update(view[:size])

    return digestobj
