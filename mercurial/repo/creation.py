# repo.creation - utility around repository creation
#
# Copyright 2010-2025 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from ..i18n import _
from .. import (
    error,
    policy,
    requirements as requirementsmod,
    scmutil,
    util,
)


def default_create_opts(ui, createopts=None):
    """Populate the default creation options for a repository.

    A dictionary of explicitly requested creation options can be passed
    in. Missing keys will be populated.
    """
    createopts = dict(createopts or {})

    if b'backend' not in createopts:
        # experimental config: storage.new-repo-backend
        createopts[b'backend'] = ui.config(b'storage', b'new-repo-backend')

    return createopts


def clone_requirements(ui, createopts, srcrepo):
    """clone the requirements of a local repo for a local clone

    The store requirements are unchanged while the working copy requirements
    depends on the configuration
    """
    target_requirements = set()
    if not srcrepo.requirements:
        # this is a legacy revlog "v0" repository, we cannot do anything fancy
        # with it.
        return target_requirements
    createopts = default_create_opts(ui, createopts=createopts)
    for r in new_repo_requirements(ui, createopts):
        if r in requirementsmod.WORKING_DIR_REQUIREMENTS:
            target_requirements.add(r)

    for r in srcrepo.requirements:
        if r not in requirementsmod.WORKING_DIR_REQUIREMENTS:
            target_requirements.add(r)
    return target_requirements


def new_repo_requirements(ui, createopts):
    """Determine the set of requirements for a new local repository.

    Extensions can wrap this function to specify custom requirements for
    new repositories.
    """

    if b'backend' not in createopts:
        raise error.ProgrammingError(
            b'backend key not present in createopts; '
            b'was defaultcreateopts() called?'
        )

    if createopts[b'backend'] != b'revlogv1':
        raise error.Abort(
            _(
                b'unable to determine repository requirements for '
                b'storage backend: %s'
            )
            % createopts[b'backend']
        )

    requirements = {requirementsmod.REVLOGV1_REQUIREMENT}
    if ui.configbool(b'format', b'usestore'):
        requirements.add(requirementsmod.STORE_REQUIREMENT)
        if ui.configbool(b'format', b'usefncache'):
            requirements.add(requirementsmod.FNCACHE_REQUIREMENT)
            if ui.configbool(b'format', b'dotencode'):
                requirements.add(requirementsmod.DOTENCODE_REQUIREMENT)

    if ui.configbool(
        b'format',
        b'exp-use-very-fragile-and-unsafe-plain-store-encoding',
    ):
        if requirementsmod.STORE_REQUIREMENT not in requirements:
            msg = _(b'"plain encoding" requires using the store')
            hint = _(b'set "format.usestore=yes"')
            raise error.Abort(msg, hint=hint)
        if requirementsmod.FNCACHE_REQUIREMENT not in requirements:
            msg = _(b'"plain encoding" requires using the fncache')
            hint = _(b'set "format.usefncache=yes"')
            raise error.Abort(msg, hint=hint)
        if requirementsmod.DOTENCODE_REQUIREMENT in requirements:
            msg = _(b'"plain encoding" is incompatible with dotencode')
            hint = _(b'set "format.dotencode=no"')
            raise error.Abort(msg, hint=hint)
        requirements.add(requirementsmod.PLAIN_ENCODE_REQUIREMENT)

    compengines = ui.configlist(b'format', b'revlog-compression')
    for compengine in compengines:
        if compengine in util.compengines:
            engine = util.compengines[compengine]
            if engine.available() and engine.revlogheader():
                break
    else:
        raise error.Abort(
            _(
                b'compression engines %s defined by '
                b'format.revlog-compression not available'
            )
            % b', '.join(b'"%s"' % e for e in compengines),
            hint=_(
                b'run "hg debuginstall" to list available '
                b'compression engines'
            ),
        )

    # zlib is the historical default and doesn't need an explicit requirement.
    if compengine == b'zstd':
        requirements.add(b'revlog-compression-zstd')
    elif compengine != b'zlib':
        requirements.add(b'exp-compression-%s' % compengine)

    enabled_gd = scmutil.gdinitconfig(ui)
    if enabled_gd:
        requirements.add(requirementsmod.GENERALDELTA_REQUIREMENT)
    if ui.configbool(b'format', b'sparse-revlog'):
        explicit_gd = scmutil.explicit_gd_config(ui)
        explicit_sr = ui.config_is_set(b'format', b'sparse-revlog')
        # If sparse-revlog is implicitly added, but generaldelta is explicitly
        # disabled, prioritize the explicit config and disable sparse-revlog
        #
        # If sparse-revlog is explicitly set, respect it enable sparse-revlog
        # anyway (force enabling general delta in the process).
        if explicit_sr or not explicit_gd or enabled_gd:
            requirements.add(requirementsmod.SPARSEREVLOG_REQUIREMENT)

    # experimental config: format.use-dirstate-v2
    # Keep this logic in sync with `has_dirstate_v2()` in `tests/hghave.py`
    if ui.configbool(b'format', b'use-dirstate-v2'):
        requirements.add(requirementsmod.DIRSTATE_V2_REQUIREMENT)

    # experimental config: format.exp-use-hasmeta-flag
    if ui.configbool(b'format', b'exp-use-hasmeta-flag'):
        requirements.add(requirementsmod.FILELOG_METAFLAG_REQUIREMENT)

    # experimental config: format.exp-use-hasmeta-flag
    if ui.configbool(b'format', b'exp-use-delta-info-flags'):
        requirements.add(requirementsmod.DELTA_INFO_REQUIREMENT)

    # enforce requirement dependencies
    #
    # note: In practice this mean we don't need to explicitly use the
    # "generaldelta" requirement for repository that already have the
    # "sparserevlog" requirement, etc…
    #
    # In practice this has been the case for a while and older clients might
    # rely on it. The redundancy does not hurt for now, but we could consider
    # using such implicit approach for newly introduced requirements.
    if requirementsmod.DELTA_INFO_REQUIREMENT in requirements:
        requirements.add(requirementsmod.SPARSEREVLOG_REQUIREMENT)
    if requirementsmod.SPARSEREVLOG_REQUIREMENT in requirements:
        requirements.add(requirementsmod.GENERALDELTA_REQUIREMENT)

    # experimental config: format.exp-use-copies-side-data-changeset
    if ui.configbool(b'format', b'exp-use-copies-side-data-changeset'):
        requirements.add(requirementsmod.CHANGELOGV2_REQUIREMENT)
        requirements.add(requirementsmod.COPIESSDC_REQUIREMENT)
    if ui.configbool(b'experimental', b'treemanifest'):
        requirements.add(requirementsmod.TREEMANIFEST_REQUIREMENT)

    changelogv2 = ui.config(b'format', b'exp-use-changelog-v2')
    if changelogv2 == b'enable-unstable-format-and-corrupt-my-data':
        requirements.add(requirementsmod.CHANGELOGV2_REQUIREMENT)

    revlogv2 = ui.config(b'experimental', b'revlogv2')
    if revlogv2 == b'enable-unstable-format-and-corrupt-my-data':
        requirements.discard(requirementsmod.REVLOGV1_REQUIREMENT)
        requirements.add(requirementsmod.REVLOGV2_REQUIREMENT)
    # experimental config: format.internal-phase
    if ui.configbool(b'format', b'use-internal-phase'):
        requirements.add(requirementsmod.INTERNAL_PHASE_REQUIREMENT)

    # experimental config: format.exp-archived-phase
    if ui.configbool(b'format', b'exp-archived-phase'):
        requirements.add(requirementsmod.ARCHIVED_PHASE_REQUIREMENT)

    if createopts.get(b'narrowfiles'):
        requirements.add(requirementsmod.NARROW_REQUIREMENT)

    if createopts.get(b'lfs'):
        requirements.add(b'lfs')

    if ui.configbool(b'format', b'bookmarks-in-store'):
        requirements.add(requirementsmod.BOOKMARKS_IN_STORE_REQUIREMENT)

    # The feature is disabled unless a fast implementation is available.
    persistent_nodemap_default = policy.importrust('revlog') is not None
    if ui.configbool(
        b'format', b'use-persistent-nodemap', persistent_nodemap_default
    ):
        requirements.add(requirementsmod.NODEMAP_REQUIREMENT)

    # if share-safe is enabled, let's create the new repository with the new
    # requirement
    if ui.configbool(b'format', b'use-share-safe'):
        requirements.add(requirementsmod.SHARESAFE_REQUIREMENT)

    # if we are creating a share-repo¹  we have to handle requirement
    # differently.
    #
    # [1] (i.e. reusing the store from another repository, just having a
    # working copy)
    if b'sharedrepo' in createopts:
        source_requirements = set(createopts[b'sharedrepo'].requirements)

        if requirementsmod.SHARESAFE_REQUIREMENT not in source_requirements:
            # share to an old school repository, we have to copy the
            # requirements and hope for the best.
            requirements = source_requirements
        else:
            # We have control on the working copy only, so "copy" the non
            # working copy part over, ignoring previous logic.
            to_drop = set()
            for req in requirements:
                if req in requirementsmod.WORKING_DIR_REQUIREMENTS:
                    continue
                if req in source_requirements:
                    continue
                to_drop.add(req)
            requirements -= to_drop
            requirements |= source_requirements

        if createopts.get(b'sharedrelative'):
            requirements.add(requirementsmod.RELATIVE_SHARED_REQUIREMENT)
        else:
            requirements.add(requirementsmod.SHARED_REQUIREMENT)

    if ui.configbool(b'format', b'use-dirstate-tracked-hint'):
        version = ui.configint(b'format', b'use-dirstate-tracked-hint.version')
        msg = _(b"ignoring unknown tracked key version: %d\n")
        hint = _(
            b"see `hg help config.format.use-dirstate-tracked-hint-version"
        )
        if version != 1:
            ui.warn(msg % version, hint=hint)
        else:
            requirements.add(requirementsmod.DIRSTATE_TRACKED_HINT_V1)

    return requirements


def check_requirements_compat(ui, requirements):
    """Checks compatibility of repository requirements enabled and disabled.

    Returns a set of requirements which needs to be dropped because dependend
    requirements are not enabled. Also warns users about it"""

    dropped = set()

    if requirementsmod.STORE_REQUIREMENT not in requirements:
        if requirementsmod.BOOKMARKS_IN_STORE_REQUIREMENT in requirements:
            ui.warn(
                _(
                    b'ignoring enabled \'format.bookmarks-in-store\' config '
                    b'beacuse it is incompatible with disabled '
                    b'\'format.usestore\' config\n'
                )
            )
            dropped.add(requirementsmod.BOOKMARKS_IN_STORE_REQUIREMENT)

        if (
            requirementsmod.SHARED_REQUIREMENT in requirements
            or requirementsmod.RELATIVE_SHARED_REQUIREMENT in requirements
        ):
            raise error.Abort(
                _(
                    b"cannot create shared repository as source was created"
                    b" with 'format.usestore' config disabled"
                )
            )

        if requirementsmod.SHARESAFE_REQUIREMENT in requirements:
            if ui.hasconfig(b'format', b'use-share-safe'):
                msg = _(
                    b"ignoring enabled 'format.use-share-safe' config because "
                    b"it is incompatible with disabled 'format.usestore'"
                    b" config\n"
                )
                ui.warn(msg)
            dropped.add(requirementsmod.SHARESAFE_REQUIREMENT)

    return dropped


def filter_known_create_opts(ui, createopts):
    """Filters a dict of repo creation options against options that are known.

    Receives a dict of repo creation options and returns a dict of those
    options that we don't know how to handle.

    This function is called as part of repository creation. If the
    returned dict contains any items, repository creation will not
    be allowed, as it means there was a request to create a repository
    with options not recognized by loaded code.

    Extensions can wrap this function to filter out creation options
    they know how to handle.
    """
    known = {
        b'backend',
        b'lfs',
        b'narrowfiles',
        b'sharedrepo',
        b'sharedrelative',
        b'shareditems',
        b'shallowfilestore',
    }

    return {k: v for k, v in createopts.items() if k not in known}
