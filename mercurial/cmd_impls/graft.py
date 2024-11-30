# graft.py - implementation of the graft command

from __future__ import annotations

from ..i18n import _

from .. import cmdutil, error, logcmdutil, merge as mergemod, state as statemod


def cmd_graft(ui, repo, *revs, **opts):
    """implement the graft command as defined in mercurial/commands.py"""
    ret = _process_args(ui, repo, *revs, **opts)
    action, graftstate, args = ret
    if action == "ERROR":
        return -1
    elif action == "ABORT":
        assert args is None
        return cmdutil.abortgraft(ui, repo, graftstate)
    elif action == "STOP":
        assert args is None
        return _stopgraft(ui, repo, graftstate)
    elif action == "GRAFT":
        return _graft_revisions(ui, repo, graftstate, *args)
    else:
        raise error.ProgrammingError('unknown action: %s' % action)


def _process_args(ui, repo, *revs, **opts):
    """process the graft command argument to figure out what to do

    This also filter the selected revision to skip the one that cannot be graft
    or were already grafted.
    """
    if revs and opts.get('rev'):
        ui.warn(
            _(
                b'warning: inconsistent use of --rev might give unexpected '
                b'revision ordering!\n'
            )
        )

    revs = list(revs)
    revs.extend(opts.get('rev'))
    # a dict of data to be stored in state file
    statedata = {}
    # list of new nodes created by ongoing graft
    statedata[b'newnodes'] = []

    # argument incompatible with followup from an interrupted operation
    commit_args = ['edit', 'log', 'user', 'date', 'currentdate', 'currentuser']
    nofollow_args = commit_args + ['base', 'rev']

    arg_compatibilities = [
        ('no_commit', commit_args),
        ('stop', nofollow_args),
        ('abort', nofollow_args),
    ]
    cmdutil.check_at_most_one_arg(opts, 'abort', 'stop', 'continue')
    for arg, incompatible in arg_compatibilities:
        cmdutil.check_incompatible_arguments(opts, arg, incompatible)

    cmdutil.resolve_commit_options(ui, opts)

    cont = False

    graftstate = statemod.cmdstate(repo, b'graftstate')

    if opts.get('stop'):
        return "STOP", graftstate, None
    elif opts.get('abort'):
        return "ABORT", graftstate, None
    elif opts.get('continue'):
        cont = True
        if revs:
            raise error.InputError(_(b"can't specify --continue and revisions"))
        # read in unfinished revisions
        if graftstate.exists():
            statedata = cmdutil.readgraftstate(repo, graftstate)
            if statedata.get(b'no_commit'):
                opts['no_commit'] = statedata.get(b'no_commit')
            if statedata.get(b'base'):
                opts['base'] = statedata.get(b'base')
            nodes = statedata[b'nodes']
            revs = [repo[node].rev() for node in nodes]
        else:
            cmdutil.wrongtooltocontinue(repo, _(b'graft'))
    elif not revs:
        raise error.InputError(_(b'no revisions specified'))
    else:
        cmdutil.checkunfinished(repo)
        cmdutil.bailifchanged(repo)
        revs = logcmdutil.revrange(repo, revs)

    for o in (
        b'date',
        b'user',
        b'log',
        b'no_commit',
        b'dry_run',
    ):
        v = opts.get(o.decode('ascii'))
        # if statedata is already set, it comes from --continue and test says
        # we should honor them above the options (which seems weird).
        if v and o not in statedata:
            statedata[o] = v

    skipped = set()
    basectx = None
    if opts.get('base'):
        basectx = logcmdutil.revsingle(repo, opts['base'], None)
        statedata[b'base'] = basectx.hex()
    if basectx is None:
        # check for merges
        for rev in repo.revs(b'%ld and merge()', revs):
            ui.warn(_(b'skipping ungraftable merge revision %d\n') % rev)
            skipped.add(rev)
    revs = [r for r in revs if r not in skipped]
    if not revs:
        return "ERROR", None, None
    if basectx is not None and len(revs) != 1:
        raise error.InputError(_(b'only one revision allowed with --base'))

    # Don't check in the --continue case, in effect retaining --force across
    # --continues. That's because without --force, any revisions we decided to
    # skip would have been filtered out here, so they wouldn't have made their
    # way to the graftstate. With --force, any revisions we would have otherwise
    # skipped would not have been filtered out, and if they hadn't been applied
    # already, they'd have been in the graftstate.
    if not (cont or opts.get('force')) and basectx is None:
        # check for ancestors of dest branch
        ancestors = repo.revs(b'%ld & (::.)', revs)
        for rev in ancestors:
            ui.warn(_(b'skipping ancestor revision %d:%s\n') % (rev, repo[rev]))

        revs = [r for r in revs if r not in ancestors]

        if not revs:
            return "ERROR", None, None

        # analyze revs for earlier grafts
        ids = {}
        for ctx in repo.set(b"%ld", revs):
            ids[ctx.hex()] = ctx.rev()
            n = ctx.extra().get(b'source')
            if n:
                ids[n] = ctx.rev()

        # check ancestors for earlier grafts
        ui.debug(b'scanning for duplicate grafts\n')

        # The only changesets we can be sure doesn't contain grafts of any
        # revs, are the ones that are common ancestors of *all* revs:
        for rev in repo.revs(b'only(%d,ancestor(%ld))', repo[b'.'].rev(), revs):
            ctx = repo[rev]
            n = ctx.extra().get(b'source')
            if n in ids:
                try:
                    r = repo[n].rev()
                except error.RepoLookupError:
                    r = None
                if r in revs:
                    ui.warn(
                        _(
                            b'skipping revision %d:%s '
                            b'(already grafted to %d:%s)\n'
                        )
                        % (r, repo[r], rev, ctx)
                    )
                    revs.remove(r)
                elif ids[n] in revs:
                    if r is None:
                        ui.warn(
                            _(
                                b'skipping already grafted revision %d:%s '
                                b'(%d:%s also has unknown origin %s)\n'
                            )
                            % (ids[n], repo[ids[n]], rev, ctx, n[:12])
                        )
                    else:
                        ui.warn(
                            _(
                                b'skipping already grafted revision %d:%s '
                                b'(%d:%s also has origin %d:%s)\n'
                            )
                            % (ids[n], repo[ids[n]], rev, ctx, r, n[:12])
                        )
                    revs.remove(ids[n])
            elif ctx.hex() in ids:
                r = ids[ctx.hex()]
                if r in revs:
                    ui.warn(
                        _(
                            b'skipping already grafted revision %d:%s '
                            b'(was grafted from %d:%s)\n'
                        )
                        % (r, repo[r], rev, ctx)
                    )
                    revs.remove(r)
        if not revs:
            return "ERROR", None, None

    editor = cmdutil.getcommiteditor(editform=b'graft', **opts)
    dry_run = bool(opts.get("dry_run"))
    tool = opts.get('tool', b'')
    return "GRAFT", graftstate, (statedata, revs, editor, cont, dry_run, tool)


def _graft_revisions(
    ui,
    repo,
    graftstate,
    statedata,
    revs,
    editor,
    cont=False,
    dry_run=False,
    tool=b'',
):
    """actually graft some revisions"""
    for pos, ctx in enumerate(repo.set(b"%ld", revs)):
        desc = b'%d:%s "%s"' % (
            ctx.rev(),
            ctx,
            ctx.description().split(b'\n', 1)[0],
        )
        names = repo.nodetags(ctx.node()) + repo.nodebookmarks(ctx.node())
        if names:
            desc += b' (%s)' % b' '.join(names)
        ui.status(_(b'grafting %s\n') % desc)
        if dry_run:
            continue

        source = ctx.extra().get(b'source')
        extra = {}
        if source:
            extra[b'source'] = source
            extra[b'intermediate-source'] = ctx.hex()
        else:
            extra[b'source'] = ctx.hex()
        user = statedata.get(b'user', ctx.user())
        date = statedata.get(b'date', ctx.date())
        message = ctx.description()
        if statedata.get(b'log'):
            message += b'\n(grafted from %s)' % ctx.hex()

        # we don't merge the first commit when continuing
        if not cont:
            # perform the graft merge with p1(rev) as 'ancestor'
            overrides = {(b'ui', b'forcemerge'): tool}
            if b'base' in statedata:
                base = repo[statedata[b'base']]
            else:
                base = ctx.p1()
            with ui.configoverride(overrides, b'graft'):
                stats = mergemod.graft(
                    repo, ctx, base, [b'local', b'graft', b'parent of graft']
                )
            # report any conflicts
            if stats.unresolvedcount > 0:
                # write out state for --continue
                nodes = [repo[rev].hex() for rev in revs[pos:]]
                statedata[b'nodes'] = nodes
                stateversion = 1
                graftstate.save(stateversion, statedata)
                ui.error(_(b"abort: unresolved conflicts, can't continue\n"))
                ui.error(_(b"(use 'hg resolve' and 'hg graft --continue')\n"))
                return 1
        else:
            cont = False

        # commit if --no-commit is false
        if not statedata.get(b'no_commit'):
            node = repo.commit(
                text=message, user=user, date=date, extra=extra, editor=editor
            )
            if node is None:
                ui.warn(
                    _(b'note: graft of %d:%s created no changes to commit\n')
                    % (ctx.rev(), ctx)
                )
            # checking that newnodes exist because old state files won't have it
            elif statedata.get(b'newnodes') is not None:
                nn = statedata[b'newnodes']
                assert isinstance(nn, list)  # list of bytes
                nn.append(node)

    # remove state when we complete successfully
    if not dry_run:
        graftstate.delete()

    return 0


def _stopgraft(ui, repo, graftstate):
    """stop the interrupted graft"""
    if not graftstate.exists():
        raise error.StateError(_(b"no interrupted graft found"))
    pctx = repo[b'.']
    mergemod.clean_update(pctx)
    graftstate.delete()
    ui.status(_(b"stopped the interrupted graft\n"))
    ui.status(_(b"working directory is now at %s\n") % pctx.hex()[:12])
    return 0
