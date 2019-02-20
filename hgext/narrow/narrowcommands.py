# narrowcommands.py - command modifications for narrowhg extension
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
from __future__ import absolute_import

import itertools
import os

from mercurial.i18n import _
from mercurial import (
    bundle2,
    cmdutil,
    commands,
    discovery,
    encoding,
    error,
    exchange,
    extensions,
    hg,
    narrowspec,
    node,
    pycompat,
    registrar,
    repair,
    repository,
    repoview,
    sparse,
    util,
    wireprototypes,
)

table = {}
command = registrar.command(table)

def setup():
    """Wraps user-facing mercurial commands with narrow-aware versions."""

    entry = extensions.wrapcommand(commands.table, 'clone', clonenarrowcmd)
    entry[1].append(('', 'narrow', None,
                     _("create a narrow clone of select files")))
    entry[1].append(('', 'depth', '',
                     _("limit the history fetched by distance from heads")))
    entry[1].append(('', 'narrowspec', '',
                     _("read narrowspecs from file")))
    # TODO(durin42): unify sparse/narrow --include/--exclude logic a bit
    if 'sparse' not in extensions.enabled():
        entry[1].append(('', 'include', [],
                         _("specifically fetch this file/directory")))
        entry[1].append(
            ('', 'exclude', [],
             _("do not fetch this file/directory, even if included")))

    entry = extensions.wrapcommand(commands.table, 'pull', pullnarrowcmd)
    entry[1].append(('', 'depth', '',
                     _("limit the history fetched by distance from heads")))

    extensions.wrapcommand(commands.table, 'archive', archivenarrowcmd)

def clonenarrowcmd(orig, ui, repo, *args, **opts):
    """Wraps clone command, so 'hg clone' first wraps localrepo.clone()."""
    opts = pycompat.byteskwargs(opts)
    wrappedextraprepare = util.nullcontextmanager()
    narrowspecfile = opts['narrowspec']

    if narrowspecfile:
        filepath = os.path.join(encoding.getcwd(), narrowspecfile)
        ui.status(_("reading narrowspec from '%s'\n") % filepath)
        try:
            fdata = util.readfile(filepath)
        except IOError as inst:
            raise error.Abort(_("cannot read narrowspecs from '%s': %s") %
                              (filepath, encoding.strtolocal(inst.strerror)))

        includes, excludes, profiles = sparse.parseconfig(ui, fdata, 'narrow')
        if profiles:
            raise error.Abort(_("cannot specify other files using '%include' in"
                                " narrowspec"))

        narrowspec.validatepatterns(includes)
        narrowspec.validatepatterns(excludes)

        # narrowspec is passed so we should assume that user wants narrow clone
        opts['narrow'] = True
        opts['include'].extend(includes)
        opts['exclude'].extend(excludes)

    if opts['narrow']:
        def pullbundle2extraprepare_widen(orig, pullop, kwargs):
            orig(pullop, kwargs)

            if opts.get('depth'):
                kwargs['depth'] = opts['depth']
        wrappedextraprepare = extensions.wrappedfunction(exchange,
            '_pullbundle2extraprepare', pullbundle2extraprepare_widen)

    with wrappedextraprepare:
        return orig(ui, repo, *args, **pycompat.strkwargs(opts))

def pullnarrowcmd(orig, ui, repo, *args, **opts):
    """Wraps pull command to allow modifying narrow spec."""
    wrappedextraprepare = util.nullcontextmanager()
    if repository.NARROW_REQUIREMENT in repo.requirements:

        def pullbundle2extraprepare_widen(orig, pullop, kwargs):
            orig(pullop, kwargs)
            if opts.get(r'depth'):
                kwargs['depth'] = opts[r'depth']
        wrappedextraprepare = extensions.wrappedfunction(exchange,
            '_pullbundle2extraprepare', pullbundle2extraprepare_widen)

    with wrappedextraprepare:
        return orig(ui, repo, *args, **opts)

def archivenarrowcmd(orig, ui, repo, *args, **opts):
    """Wraps archive command to narrow the default includes."""
    if repository.NARROW_REQUIREMENT in repo.requirements:
        repo_includes, repo_excludes = repo.narrowpats
        includes = set(opts.get(r'include', []))
        excludes = set(opts.get(r'exclude', []))
        includes, excludes, unused_invalid = narrowspec.restrictpatterns(
            includes, excludes, repo_includes, repo_excludes)
        if includes:
            opts[r'include'] = includes
        if excludes:
            opts[r'exclude'] = excludes
    return orig(ui, repo, *args, **opts)

def pullbundle2extraprepare(orig, pullop, kwargs):
    repo = pullop.repo
    if repository.NARROW_REQUIREMENT not in repo.requirements:
        return orig(pullop, kwargs)

    if wireprototypes.NARROWCAP not in pullop.remote.capabilities():
        raise error.Abort(_("server does not support narrow clones"))
    orig(pullop, kwargs)
    kwargs['narrow'] = True
    include, exclude = repo.narrowpats
    kwargs['oldincludepats'] = include
    kwargs['oldexcludepats'] = exclude
    if include:
        kwargs['includepats'] = include
    if exclude:
        kwargs['excludepats'] = exclude
    # calculate known nodes only in ellipses cases because in non-ellipses cases
    # we have all the nodes
    if wireprototypes.ELLIPSESCAP in pullop.remote.capabilities():
        kwargs['known'] = [node.hex(ctx.node()) for ctx in
                           repo.set('::%ln', pullop.common)
                           if ctx.node() != node.nullid]
        if not kwargs['known']:
            # Mercurial serializes an empty list as '' and deserializes it as
            # [''], so delete it instead to avoid handling the empty string on
            # the server.
            del kwargs['known']

extensions.wrapfunction(exchange,'_pullbundle2extraprepare',
                        pullbundle2extraprepare)

def _narrow(ui, repo, remote, commoninc, oldincludes, oldexcludes,
            newincludes, newexcludes, force):
    oldmatch = narrowspec.match(repo.root, oldincludes, oldexcludes)
    newmatch = narrowspec.match(repo.root, newincludes, newexcludes)

    # This is essentially doing "hg outgoing" to find all local-only
    # commits. We will then check that the local-only commits don't
    # have any changes to files that will be untracked.
    unfi = repo.unfiltered()
    outgoing = discovery.findcommonoutgoing(unfi, remote,
                                            commoninc=commoninc)
    ui.status(_('looking for local changes to affected paths\n'))
    localnodes = []
    for n in itertools.chain(outgoing.missing, outgoing.excluded):
        if any(oldmatch(f) and not newmatch(f) for f in unfi[n].files()):
            localnodes.append(n)
    revstostrip = unfi.revs('descendants(%ln)', localnodes)
    hiddenrevs = repoview.filterrevs(repo, 'visible')
    visibletostrip = list(repo.changelog.node(r)
                          for r in (revstostrip - hiddenrevs))
    if visibletostrip:
        ui.status(_('The following changeset(s) or their ancestors have '
                    'local changes not on the remote:\n'))
        maxnodes = 10
        if ui.verbose or len(visibletostrip) <= maxnodes:
            for n in visibletostrip:
                ui.status('%s\n' % node.short(n))
        else:
            for n in visibletostrip[:maxnodes]:
                ui.status('%s\n' % node.short(n))
            ui.status(_('...and %d more, use --verbose to list all\n') %
                      (len(visibletostrip) - maxnodes))
        if not force:
            raise error.Abort(_('local changes found'),
                              hint=_('use --force-delete-local-changes to '
                                     'ignore'))

    with ui.uninterruptible():
        if revstostrip:
            tostrip = [unfi.changelog.node(r) for r in revstostrip]
            if repo['.'].node() in tostrip:
                # stripping working copy, so move to a different commit first
                urev = max(repo.revs('(::%n) - %ln + null',
                                     repo['.'].node(), visibletostrip))
                hg.clean(repo, urev)
            overrides = {('devel', 'strip-obsmarkers'): False}
            with ui.configoverride(overrides, 'narrow'):
                repair.strip(ui, unfi, tostrip, topic='narrow')

        todelete = []
        for f, f2, size in repo.store.datafiles():
            if f.startswith('data/'):
                file = f[5:-2]
                if not newmatch(file):
                    todelete.append(f)
            elif f.startswith('meta/'):
                dir = f[5:-13]
                dirs = ['.'] + sorted(util.dirs({dir})) + [dir]
                include = True
                for d in dirs:
                    visit = newmatch.visitdir(d)
                    if not visit:
                        include = False
                        break
                    if visit == 'all':
                        break
                if not include:
                    todelete.append(f)

        repo.destroying()

        with repo.transaction('narrowing'):
            # Update narrowspec before removing revlogs, so repo won't be
            # corrupt in case of crash
            repo.setnarrowpats(newincludes, newexcludes)

            for f in todelete:
                ui.status(_('deleting %s\n') % f)
                util.unlinkpath(repo.svfs.join(f))
                repo.store.markremoved(f)

            narrowspec.updateworkingcopy(repo, assumeclean=True)
            narrowspec.copytoworkingcopy(repo)

        repo.destroyed()

def _widen(ui, repo, remote, commoninc, oldincludes, oldexcludes,
           newincludes, newexcludes):
    # for now we assume that if a server has ellipses enabled, we will be
    # exchanging ellipses nodes. In future we should add ellipses as a client
    # side requirement (maybe) to distinguish a client is shallow or not and
    # then send that information to server whether we want ellipses or not.
    # Theoretically a non-ellipses repo should be able to use narrow
    # functionality from an ellipses enabled server
    ellipsesremote = wireprototypes.ELLIPSESCAP in remote.capabilities()

    def pullbundle2extraprepare_widen(orig, pullop, kwargs):
        orig(pullop, kwargs)
        # The old{in,ex}cludepats have already been set by orig()
        kwargs['includepats'] = newincludes
        kwargs['excludepats'] = newexcludes
    wrappedextraprepare = extensions.wrappedfunction(exchange,
        '_pullbundle2extraprepare', pullbundle2extraprepare_widen)

    # define a function that narrowbundle2 can call after creating the
    # backup bundle, but before applying the bundle from the server
    def setnewnarrowpats():
        repo.setnarrowpats(newincludes, newexcludes)
    repo.setnewnarrowpats = setnewnarrowpats
    # silence the devel-warning of applying an empty changegroup
    overrides = {('devel', 'all-warnings'): False}

    with ui.uninterruptible():
        common = commoninc[0]
        if ellipsesremote:
            ds = repo.dirstate
            p1, p2 = ds.p1(), ds.p2()
            with ds.parentchange():
                ds.setparents(node.nullid, node.nullid)
            with wrappedextraprepare:
                with repo.ui.configoverride(overrides, 'widen'):
                    exchange.pull(repo, remote, heads=common)
            with ds.parentchange():
                ds.setparents(p1, p2)
        else:
            with remote.commandexecutor() as e:
                bundle = e.callcommand('narrow_widen', {
                    'oldincludes': oldincludes,
                    'oldexcludes': oldexcludes,
                    'newincludes': newincludes,
                    'newexcludes': newexcludes,
                    'cgversion': '03',
                    'commonheads': common,
                    'known': [],
                    'ellipses': False,
                }).result()

            with repo.transaction('widening') as tr:
                with repo.ui.configoverride(overrides, 'widen'):
                    tgetter = lambda: tr
                    bundle2.processbundle(repo, bundle,
                            transactiongetter=tgetter)

        with repo.transaction('widening'):
            repo.setnewnarrowpats()
            narrowspec.updateworkingcopy(repo)
            narrowspec.copytoworkingcopy(repo)

# TODO(rdamazio): Make new matcher format and update description
@command('tracked',
    [('', 'addinclude', [], _('new paths to include')),
     ('', 'removeinclude', [], _('old paths to no longer include')),
     ('', 'addexclude', [], _('new paths to exclude')),
     ('', 'import-rules', '', _('import narrowspecs from a file')),
     ('', 'removeexclude', [], _('old paths to no longer exclude')),
     ('', 'clear', False, _('whether to replace the existing narrowspec')),
     ('', 'force-delete-local-changes', False,
       _('forces deletion of local changes when narrowing')),
     ('', 'update-working-copy', False,
      _('update working copy when the store has changed')),
    ] + commands.remoteopts,
    _('[OPTIONS]... [REMOTE]'),
    inferrepo=True)
def trackedcmd(ui, repo, remotepath=None, *pats, **opts):
    """show or change the current narrowspec

    With no argument, shows the current narrowspec entries, one per line. Each
    line will be prefixed with 'I' or 'X' for included or excluded patterns,
    respectively.

    The narrowspec is comprised of expressions to match remote files and/or
    directories that should be pulled into your client.
    The narrowspec has *include* and *exclude* expressions, with excludes always
    trumping includes: that is, if a file matches an exclude expression, it will
    be excluded even if it also matches an include expression.
    Excluding files that were never included has no effect.

    Each included or excluded entry is in the format described by
    'hg help patterns'.

    The options allow you to add or remove included and excluded expressions.

    If --clear is specified, then all previous includes and excludes are DROPPED
    and replaced by the new ones specified to --addinclude and --addexclude.
    If --clear is specified without any further options, the narrowspec will be
    empty and will not match any files.
    """
    opts = pycompat.byteskwargs(opts)
    if repository.NARROW_REQUIREMENT not in repo.requirements:
        raise error.Abort(_('the tracked command is only supported on '
                            'respositories cloned with --narrow'))

    # Before supporting, decide whether it "hg tracked --clear" should mean
    # tracking no paths or all paths.
    if opts['clear']:
        raise error.Abort(_('the --clear option is not yet supported'))

    # import rules from a file
    newrules = opts.get('import_rules')
    if newrules:
        try:
            filepath = os.path.join(encoding.getcwd(), newrules)
            fdata = util.readfile(filepath)
        except IOError as inst:
            raise error.Abort(_("cannot read narrowspecs from '%s': %s") %
                              (filepath, encoding.strtolocal(inst.strerror)))
        includepats, excludepats, profiles = sparse.parseconfig(ui, fdata,
                                                                'narrow')
        if profiles:
            raise error.Abort(_("including other spec files using '%include' "
                                "is not supported in narrowspec"))
        opts['addinclude'].extend(includepats)
        opts['addexclude'].extend(excludepats)

    addedincludes = narrowspec.parsepatterns(opts['addinclude'])
    removedincludes = narrowspec.parsepatterns(opts['removeinclude'])
    addedexcludes = narrowspec.parsepatterns(opts['addexclude'])
    removedexcludes = narrowspec.parsepatterns(opts['removeexclude'])

    update_working_copy = opts['update_working_copy']
    only_show = not (addedincludes or removedincludes or addedexcludes or
                     removedexcludes or newrules or update_working_copy)

    oldincludes, oldexcludes = repo.narrowpats

    # filter the user passed additions and deletions into actual additions and
    # deletions of excludes and includes
    addedincludes -= oldincludes
    removedincludes &= oldincludes
    addedexcludes -= oldexcludes
    removedexcludes &= oldexcludes

    widening = addedincludes or removedexcludes
    narrowing = removedincludes or addedexcludes

    # Only print the current narrowspec.
    if only_show:
        ui.pager('tracked')
        fm = ui.formatter('narrow', opts)
        for i in sorted(oldincludes):
            fm.startitem()
            fm.write('status', '%s ', 'I', label='narrow.included')
            fm.write('pat', '%s\n', i, label='narrow.included')
        for i in sorted(oldexcludes):
            fm.startitem()
            fm.write('status', '%s ', 'X', label='narrow.excluded')
            fm.write('pat', '%s\n', i, label='narrow.excluded')
        fm.end()
        return 0

    if update_working_copy:
        with repo.wlock(), repo.lock(), repo.transaction('narrow-wc'):
            narrowspec.updateworkingcopy(repo)
            narrowspec.copytoworkingcopy(repo)
        return 0

    if not widening and not narrowing:
        ui.status(_("nothing to widen or narrow\n"))
        return 0

    with repo.wlock(), repo.lock():
        cmdutil.bailifchanged(repo)

        # Find the revisions we have in common with the remote. These will
        # be used for finding local-only changes for narrowing. They will
        # also define the set of revisions to update for widening.
        remotepath = ui.expandpath(remotepath or 'default')
        url, branches = hg.parseurl(remotepath)
        ui.status(_('comparing with %s\n') % util.hidepassword(url))
        remote = hg.peer(repo, opts, url)

        # check narrow support before doing anything if widening needs to be
        # performed. In future we should also abort if client is ellipses and
        # server does not support ellipses
        if widening and wireprototypes.NARROWCAP not in remote.capabilities():
            raise error.Abort(_("server does not support narrow clones"))

        commoninc = discovery.findcommonincoming(repo, remote)

        if narrowing:
            newincludes = oldincludes - removedincludes
            newexcludes = oldexcludes | addedexcludes
            _narrow(ui, repo, remote, commoninc, oldincludes, oldexcludes,
                    newincludes, newexcludes,
                    opts['force_delete_local_changes'])
            # _narrow() updated the narrowspec and _widen() below needs to
            # use the updated values as its base (otherwise removed includes
            # and addedexcludes will be lost in the resulting narrowspec)
            oldincludes = newincludes
            oldexcludes = newexcludes

        if widening:
            newincludes = oldincludes | addedincludes
            newexcludes = oldexcludes - removedexcludes
            _widen(ui, repo, remote, commoninc, oldincludes, oldexcludes,
                    newincludes, newexcludes)

    return 0
