# clone.py - high level logic for cloning

from __future__ import annotations

from ..i18n import _
from ..interfaces.types import (
    RepoT,
    UiT,
)
from ..node import nullrev
from .. import (
    bundle2,
    bundlecaches,
    changegroup,
    discovery,
    error,
    logcmdutil,
    policy,
    pycompat,
    scmutil,
)
from ..repo import (
    factory as repo_factory,
)
from ..utils import urlutil


shape_mod = policy.importrust("shape")


def bundle(ui: UiT, repo: RepoT, fname: bytes, *dests, **opts):
    revs = None
    if 'rev' in opts:
        revstrings = opts['rev']
        revs = logcmdutil.revrange(repo, revstrings)
        if revstrings and not revs:
            raise error.InputError(_(b'no commits to bundle'))

    bundletype = opts.get('type', b'bzip2').lower()
    try:
        bundlespec = bundlecaches.parsebundlespec(
            repo, bundletype, strict=False
        )
    except error.UnsupportedBundleSpecification as e:
        raise error.InputError(
            pycompat.bytestr(e),
            hint=_(b"see 'hg help bundlespec' for supported values for --type"),
        )

    if bundlespec.params.get(b"shape") is not None:
        if shape_mod is None:
            raise error.InputError(
                _(
                    b"shape bundlespec option is only available"
                    b" with the Rust extensions"
                ),
            )
        # Give more a helpful error than a programming error later on
        if bundlespec.params.get(b"stream") is None:
            raise error.InputError(
                _(
                    b"shape bundlespec option is only implemented"
                    b" for stream bundles"
                ),
            )

    has_changegroup = bundlespec.params.get(b"changegroup", False)
    cgversion = bundlespec.params[b"cg.version"]

    # Packed bundles are a pseudo bundle format for now.
    if cgversion == b's1':
        raise error.InputError(
            _(b'packed bundles cannot be produced by "hg bundle"'),
            hint=_(b"use 'hg debugcreatestreamclonebundle'"),
        )
    base_opt = opts.get('base')
    if opts.get('all'):
        if dests:
            raise error.InputError(
                _(b"--all is incompatible with specifying destinations")
            )
        if base_opt:
            ui.warn(_(b"ignoring --base because --all was specified\n"))
        if opts.get('exact'):
            ui.warn(_(b"ignoring --exact because --all was specified\n"))
        base = [nullrev]
    elif opts.get('exact'):
        if dests:
            raise error.InputError(
                _(b"--exact is incompatible with specifying destinations")
            )
        if base_opt:
            ui.warn(_(b"ignoring --base because --exact was specified\n"))
        base = repo.revs(b'parents(%ld) - %ld', revs, revs)
        if not base:
            base = [nullrev]
    elif base_opt:
        base = logcmdutil.revrange(repo, base_opt)
        if not base:
            # base specified, but nothing was selected
            base = [nullrev]
    else:
        base = None
    supported_cg_versions = changegroup.supportedoutgoingversions(repo)
    if has_changegroup and cgversion not in supported_cg_versions:
        raise error.Abort(
            _(b"repository does not support bundle version %s") % cgversion
        )

    if base is not None:
        if dests:
            raise error.InputError(
                _(b"--base is incompatible with specifying destinations")
            )
        cl = repo.changelog
        common = [cl.node(rev) for rev in base]
        heads = [cl.node(r) for r in revs] if revs else None
        outgoing = discovery.outgoing(repo, common, heads)
        missing = outgoing.missing
        excluded = outgoing.excluded
    else:
        missing = set()
        excluded = set()
        for path in urlutil.get_push_paths(repo, ui, dests):
            other = repo_factory.peer(repo, pycompat.byteskwargs(opts), path)
            if revs is not None:
                hex_revs = [repo[r].hex() for r in revs]
            else:
                hex_revs = None
            branches = (path.branch, [])
            head_revs, checkout = urlutil.add_branch_revs(
                repo,
                repo,
                branches,
                hex_revs,
            )
            heads = (
                head_revs
                and pycompat.maplist(repo.lookup, head_revs)
                or head_revs
            )
            outgoing = discovery.findcommonoutgoing(
                repo,
                other,
                onlyheads=heads,
                force=opts.get('force'),
                portable=True,
            )
            missing.update(outgoing.missing)
            excluded.update(outgoing.excluded)

    if not missing:
        scmutil.nochangesfound(ui, repo, not base and excluded)
        return 1

    # internal changeset are internal implementation details that should not
    # leave the repository. Bundling with `hg bundle` create such risk.
    bundled_internal = repo.revs(b"%ln and _internal()", missing)
    if bundled_internal:
        msg = _(b"cannot bundle internal changesets")
        hint = _(b"%d internal changesets selected") % len(bundled_internal)
        raise error.Abort(msg, hint=hint)

    if heads:
        outgoing = discovery.outgoing(
            repo, missingroots=missing, ancestorsof=heads
        )
    else:
        outgoing = discovery.outgoing(repo, missingroots=missing)
    outgoing.excluded = sorted(excluded)

    if cgversion == b'01':  # bundle1
        bversion = b'HG10' + bundlespec.wirecompression
        bcompression = None
    elif cgversion in (b'02', b'03', b'04'):
        bversion = b'HG20'
        bcompression = bundlespec.wirecompression
    else:
        raise error.ProgrammingError(
            b'bundle: unexpected changegroup version %s' % cgversion
        )

    # TODO compression options should be derived from bundlespec parsing.
    # This is a temporary hack to allow adjusting bundle compression
    # level without a) formalizing the bundlespec changes to declare it
    # b) introducing a command flag.
    compopts = {}
    complevel = ui.configint(
        b'experimental', b'bundlecomplevel.' + bundlespec.compression
    )
    if complevel is None:
        complevel = ui.configint(b'experimental', b'bundlecomplevel')
    if complevel is not None:
        compopts[b'level'] = complevel

    compthreads = ui.configint(
        b'experimental', b'bundlecompthreads.' + bundlespec.compression
    )
    if compthreads is None:
        compthreads = ui.configint(b'experimental', b'bundlecompthreads')
    if compthreads is not None:
        compopts[b'threads'] = compthreads

    # Bundling of obsmarker and phases is optional as not all clients
    # support the necessary features.
    cfg = ui.configbool
    obsolescence_cfg = cfg(b'experimental', b'evolution.bundle-obsmarker')
    bundlespec.set_param(b'obsolescence', obsolescence_cfg, overwrite=False)
    obs_mand_cfg = cfg(b'experimental', b'evolution.bundle-obsmarker:mandatory')
    bundlespec.set_param(
        b'obsolescence-mandatory', obs_mand_cfg, overwrite=False
    )
    if not bundlespec.params.get(b'phases', False):
        phases_cfg = cfg(b'experimental', b'bundle-phases')
        bundlespec.set_param(b'phases', phases_cfg, overwrite=False)

    bundle2.writenewbundle(
        ui,
        repo,
        b'bundle',
        fname,
        bversion,
        outgoing,
        bundlespec.params,
        compression=bcompression,
        compopts=compopts,
    )
