# subrepoutil.py - sub-repository operations and substate handling
#
# Copyright 2009-2010 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import posixpath
import re
import typing

from typing import (
    Any,
)

from .i18n import _
from . import (
    config,
    error,
    filemerge,
    pathutil,
    phases,
    util,
)
from .utils import (
    stringutil,
    urlutil,
)

# keeps pyflakes happy
assert [
    Any,
]

nullstate = (b'', b'', b'empty')

if typing.TYPE_CHECKING:
    from . import (
        context,
        localrepo,
        match as matchmod,
        subrepo,
        ui as uimod,
    )

    from .interfaces import status as istatus
    from .interfaces.types import (
        MatcherT,
    )

    # keeps pyflakes happy
    assert [
        context,
        localrepo,
        matchmod,
        subrepo,
        uimod,
    ]

Substate = dict[bytes, tuple[bytes, bytes, bytes]]


def state(ctx: context.changectx, ui: uimod.ui) -> Substate:
    """return a state dict, mapping subrepo paths configured in .hgsub
    to tuple: (source from .hgsub, revision from .hgsubstate, kind
    (key in types dict))
    """
    p: config.config = config.config()
    repo = ctx.repo()

    def read(f, sections=None, remap=None):
        if f in ctx:
            try:
                data = ctx[f].data()
            except FileNotFoundError:
                # handle missing subrepo spec files as removed
                ui.warn(
                    _(b"warning: subrepo spec file \'%s\' not found\n")
                    % repo.pathto(f)
                )
                return
            p.parse(f, data, sections, remap, read)
        else:
            raise error.Abort(
                _(b"subrepo spec file \'%s\' not found") % repo.pathto(f)
            )

    if b'.hgsub' in ctx:
        read(b'.hgsub')

    for path, src in ui.configitems(b'subpaths'):
        p.set(b'subpaths', path, src, ui.configsource(b'subpaths', path))

    rev = {}
    if b'.hgsubstate' in ctx:
        try:
            for i, l in enumerate(ctx[b'.hgsubstate'].data().splitlines()):
                l = l.lstrip()
                if not l:
                    continue
                try:
                    revision, path = l.split(b" ", 1)
                except ValueError:
                    raise error.Abort(
                        _(
                            b"invalid subrepository revision "
                            b"specifier in \'%s\' line %d"
                        )
                        % (repo.pathto(b'.hgsubstate'), (i + 1))
                    )
                rev[path] = revision
        except FileNotFoundError:
            pass

    def remap(src: bytes) -> bytes:
        for pattern, repl in p.items(b'subpaths'):
            # Turn r'C:\foo\bar' into r'C:\\foo\\bar' since re.sub
            # does a string decode.
            repl = stringutil.escapestr(repl)
            # However, we still want to allow back references to go
            # through unharmed, so we turn r'\\1' into r'\1'. Again,
            # extra escapes are needed because re.sub string decodes.
            repl = re.sub(br'\\\\([0-9]+)', br'\\\1', repl)
            try:
                src = re.sub(pattern, repl, src, count=1)
            except re.error as e:
                raise error.Abort(
                    _(b"bad subrepository pattern in %s: %s")
                    % (
                        p.source(b'subpaths', pattern),
                        stringutil.forcebytestr(e),
                    )
                )
        return src

    state = {}
    for path, src in p.items(b''):
        kind = b'hg'
        if src.startswith(b'['):
            if b']' not in src:
                raise error.Abort(_(b'missing ] in subrepository source'))
            kind, src = src.split(b']', 1)
            kind = kind[1:]
            src = src.lstrip()  # strip any extra whitespace after ']'

        if not urlutil.url(src).isabs():
            parent = _abssource(repo, abort=False)
            if parent:
                parent = urlutil.url(parent)
                parent.path = posixpath.join(parent.path or b'', src)
                parent.path = posixpath.normpath(parent.path)
                joined = bytes(parent)
                # Remap the full joined path and use it if it changes,
                # else remap the original source.
                remapped = remap(joined)
                if remapped == joined:
                    src = remap(src)
                else:
                    src = remapped

        src = remap(src)
        state[util.pconvert(path)] = (src.strip(), rev.get(path, b''), kind)

    return state


def writestate(repo: localrepo.localrepository, state: Substate) -> None:
    """rewrite .hgsubstate in (outer) repo with these subrepo states"""
    lines = [
        b'%s %s\n' % (state[s][1], s)
        for s in sorted(state)
        if state[s][1] != nullstate[1]
    ]
    repo.wwrite(b'.hgsubstate', b''.join(lines), b'')


def submerge(
    repo: localrepo.localrepository,
    wctx: context.workingctx,
    mctx: context.changectx,
    actx: context.changectx,
    overwrite: bool,
    labels: Any | None = None,
) -> Substate:
    # TODO: type the `labels` arg
    """delegated from merge.applyupdates: merging of .hgsubstate file
    in working context, merging context and ancestor context"""
    if mctx == actx:  # backwards?
        actx = wctx.p1()
    s1 = wctx.substate
    s2 = mctx.substate
    sa = actx.substate
    sm = {}

    repo.ui.debug(b"subrepo merge %s %s %s\n" % (wctx, mctx, actx))

    def debug(s, msg, r=b""):
        if r:
            r = b"%s:%s:%s" % r
        repo.ui.debug(b"  subrepo %s: %s %s\n" % (s, msg, r))

    promptssrc = filemerge.partextras(labels)
    for s, l in sorted(s1.items()):
        a = sa.get(s, nullstate)
        ld = l  # local state with possible dirty flag for compares
        if wctx.sub(s).dirty():
            ld = (l[0], l[1] + b"+")
        if wctx == actx:  # overwrite
            a = ld

        prompts = promptssrc.copy()
        prompts[b's'] = s
        if s in s2:
            r = s2[s]
            if ld == r or r == a:  # no change or local is newer
                sm[s] = l
                continue
            elif ld == a:  # other side changed
                debug(s, b"other changed, get", r)
                wctx.sub(s).get(r, overwrite)
                sm[s] = r
            elif ld[0] != r[0]:  # sources differ
                prompts[b'lo'] = l[0]
                prompts[b'ro'] = r[0]
                if repo.ui.promptchoice(
                    _(
                        b' subrepository sources for %(s)s differ\n'
                        b'you can use (l)ocal%(l)s source (%(lo)s)'
                        b' or (r)emote%(o)s source (%(ro)s).\n'
                        b'what do you want to do?'
                        b'$$ &Local $$ &Remote'
                    )
                    % prompts,
                    0,
                ):
                    debug(s, b"prompt changed, get", r)
                    wctx.sub(s).get(r, overwrite)
                    sm[s] = r
            elif ld[1] == a[1]:  # local side is unchanged
                debug(s, b"other side changed, get", r)
                wctx.sub(s).get(r, overwrite)
                sm[s] = r
            else:
                debug(s, b"both sides changed")
                srepo = wctx.sub(s)
                prompts[b'sl'] = srepo.shortid(l[1])
                prompts[b'sr'] = srepo.shortid(r[1])
                option = repo.ui.promptchoice(
                    _(
                        b' subrepository %(s)s diverged (local revision: %(sl)s, '
                        b'remote revision: %(sr)s)\n'
                        b'you can (m)erge, keep (l)ocal%(l)s or keep '
                        b'(r)emote%(o)s.\n'
                        b'what do you want to do?'
                        b'$$ &Merge $$ &Local $$ &Remote'
                    )
                    % prompts,
                    0,
                )
                if option == 0:
                    wctx.sub(s).merge(r)
                    sm[s] = l
                    debug(s, b"merge with", r)
                elif option == 1:
                    sm[s] = l
                    debug(s, b"keep local subrepo revision", l)
                else:
                    wctx.sub(s).get(r, overwrite)
                    sm[s] = r
                    debug(s, b"get remote subrepo revision", r)
        elif ld == a:  # remote removed, local unchanged
            debug(s, b"remote removed, remove")
            wctx.sub(s).remove()
        elif a == nullstate:  # not present in remote or ancestor
            debug(s, b"local added, keep")
            sm[s] = l
            continue
        else:
            if repo.ui.promptchoice(
                _(
                    b' local%(l)s changed subrepository %(s)s'
                    b' which remote%(o)s removed\n'
                    b'use (c)hanged version or (d)elete?'
                    b'$$ &Changed $$ &Delete'
                )
                % prompts,
                0,
            ):
                debug(s, b"prompt remove")
                wctx.sub(s).remove()

    for s, r in sorted(s2.items()):
        if s in s1:
            continue
        elif s not in sa:
            debug(s, b"remote added, get", r)
            mctx.sub(s).get(r)
            sm[s] = r
        elif r != sa[s]:
            prompts = promptssrc.copy()
            prompts[b's'] = s
            if (
                repo.ui.promptchoice(
                    _(
                        b' remote%(o)s changed subrepository %(s)s'
                        b' which local%(l)s removed\n'
                        b'use (c)hanged version or (d)elete?'
                        b'$$ &Changed $$ &Delete'
                    )
                    % prompts,
                    0,
                )
                == 0
            ):
                debug(s, b"prompt recreate", r)
                mctx.sub(s).get(r)
                sm[s] = r

    # record merged .hgsubstate
    writestate(repo, sm)
    return sm


def precommit(
    ui: uimod.ui,
    wctx: context.workingcommitctx,
    status: istatus.Status,
    match: MatcherT,
    force: bool = False,
) -> tuple[list[bytes], set[bytes], Substate]:
    """Calculate .hgsubstate changes that should be applied before committing

    Returns (subs, commitsubs, newstate) where
    - subs: changed subrepos (including dirty ones)
    - commitsubs: dirty subrepos which the caller needs to commit recursively
    - newstate: new state dict which the caller must write to .hgsubstate

    This also updates the given status argument.
    """
    subs = []
    commitsubs = set()
    newstate = wctx.substate.copy()

    # only manage subrepos and .hgsubstate if .hgsub is present
    if b'.hgsub' in wctx:
        # we'll decide whether to track this ourselves, thanks
        for c in status.modified, status.added, status.removed:
            if b'.hgsubstate' in c:
                c.remove(b'.hgsubstate')

        # compare current state to last committed state
        # build new substate based on last committed state
        oldstate = wctx.p1().substate
        for s in sorted(newstate.keys()):
            if not match(s):
                # ignore working copy, use old state if present
                if s in oldstate:
                    newstate[s] = oldstate[s]
                    continue
                if not force:
                    raise error.Abort(
                        _(b"commit with new subrepo %s excluded") % s
                    )
            dirtyreason = wctx.sub(s).dirtyreason(True)
            if dirtyreason:
                if not ui.configbool(b'ui', b'commitsubrepos'):
                    raise error.Abort(
                        dirtyreason,
                        hint=_(b"use --subrepos for recursive commit"),
                    )
                subs.append(s)
                commitsubs.add(s)
            else:
                bs = wctx.sub(s).basestate()
                newstate[s] = (newstate[s][0], bs, newstate[s][2])
                if oldstate.get(s, (None, None, None))[1] != bs:
                    subs.append(s)

        # check for removed subrepos
        for p in wctx.parents():
            r = [s for s in p.substate if s not in newstate]
            subs += [s for s in r if match(s)]
        if subs:
            if not match(b'.hgsub') and b'.hgsub' in (
                wctx.modified() + wctx.added()
            ):
                raise error.Abort(_(b"can't commit subrepos without .hgsub"))
            status.modified.insert(0, b'.hgsubstate')

    elif b'.hgsub' in status.removed:
        # clean up .hgsubstate when .hgsub is removed
        if b'.hgsubstate' in wctx and b'.hgsubstate' not in (
            status.modified + status.added + status.removed
        ):
            status.removed.insert(0, b'.hgsubstate')

    return subs, commitsubs, newstate


def repo_rel_or_abs_source(repo):
    """return the source of this repo

    Either absolute or relative the outermost repo"""
    parent = repo
    chunks = []
    while hasattr(parent, '_subparent'):
        source = urlutil.url(parent._subsource)
        chunks.append(bytes(source))
        if source.isabs():
            break
        parent = parent._subparent

    chunks.reverse()
    path = posixpath.join(*chunks)
    matchscheme = re.compile(b'^[a-zA-Z0-9+.\\-]+:').match
    if matchscheme(path):
        scheme, path = path.split(b':', 1)
        if path.startswith(b'//'):
            path = path[2:]
            sep = b'//'
        else:
            sep = b''
        normalized_path = scheme + b':' + sep + posixpath.normpath(path)
    else:
        normalized_path = posixpath.normpath(path)
    return normalized_path


def reporelpath(repo: localrepo.localrepository) -> bytes:
    """return path to this (sub)repo as seen from outermost repo"""
    parent = repo
    while hasattr(parent, '_subparent'):
        parent = parent._subparent
    return repo.root[len(pathutil.normasprefix(parent.root)) :]


def subrelpath(sub: subrepo.abstractsubrepo) -> bytes:
    """return path to this subrepo as seen from outermost repo"""
    return sub._relpath


def _abssource(
    repo: localrepo.localrepository,
    push: bool = False,
    abort: bool = True,
) -> bytes | None:
    """return pull/push path of repo - either based on parent repo .hgsub info
    or on the top repo config. Abort or return None if no source found."""
    if hasattr(repo, '_subparent'):
        source = urlutil.url(repo._subsource)
        if source.isabs():
            return bytes(source)
        source.path = posixpath.normpath(source.path)
        parent = _abssource(repo._subparent, push, abort=False)
        if parent:
            parent = urlutil.url(util.pconvert(parent))
            parent.path = posixpath.join(parent.path or b'', source.path)
            parent.path = posixpath.normpath(parent.path)
            return bytes(parent)
    else:  # recursion reached top repo
        path = None
        if hasattr(repo, '_subtoppath'):
            path = repo._subtoppath
        elif push and repo.ui.config(b'paths', b'default-push'):
            path = repo.ui.config(b'paths', b'default-push')
        elif repo.ui.config(b'paths', b'default'):
            path = repo.ui.config(b'paths', b'default')
        elif repo.shared():
            # chop off the .hg component to get the default path form.  This has
            # already run through vfsmod.vfs(..., realpath=True), so it doesn't
            # have problems with 'C:'
            return os.path.dirname(repo.sharedpath)
        if path:
            # issue5770: 'C:\' and 'C:' are not equivalent paths.  The former is
            # as expected: an absolute path to the root of the C: drive.  The
            # latter is a relative path, and works like so:
            #
            #   C:\>cd C:\some\path
            #   C:\>D:
            #   D:\>python -c "import os; print os.path.abspath('C:')"
            #   C:\some\path
            #
            #   D:\>python -c "import os; print os.path.abspath('C:relative')"
            #   C:\some\path\relative
            if urlutil.hasdriveletter(path):
                if len(path) == 2 or path[2:3] not in br'\/':
                    path = util.abspath(path)
            return path

    if abort:
        raise error.Abort(_(b"default path for subrepository not found"))


def newcommitphase(ui: uimod.ui, ctx: context.changectx) -> int:
    commitphase = phases.newcommitphase(ui)
    substate = getattr(ctx, "substate", None)
    if not substate:
        return commitphase
    check = ui.config(b'phases', b'checksubrepos')
    if check not in (b'ignore', b'follow', b'abort'):
        raise error.Abort(
            _(b'invalid phases.checksubrepos configuration: %s') % check
        )
    if check == b'ignore':
        return commitphase
    maxphase = phases.public
    maxsub = None
    for s in sorted(substate):
        sub = ctx.sub(s)
        subphase = sub.phase(substate[s][1])
        if maxphase < subphase:
            maxphase = subphase
            maxsub = s
    if commitphase < maxphase:
        if check == b'abort':
            raise error.Abort(
                _(
                    b"can't commit in %s phase"
                    b" conflicting %s from subrepository %s"
                )
                % (
                    phases.phasenames[commitphase],
                    phases.phasenames[maxphase],
                    maxsub,
                )
            )
        ui.warn(
            _(
                b"warning: changes are committed in"
                b" %s phase from subrepository %s\n"
            )
            % (phases.phasenames[maxphase], maxsub)
        )
        return maxphase
    return commitphase
