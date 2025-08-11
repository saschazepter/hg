# repo.vfs_options - small utilities around vfs-options computation
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from ..i18n import _
from .. import (
    dirstate,
    error,
    policy,
    requirements as requirementsmod,
    revlog,
    scmutil,
    util,
)

from ..revlogutils import (
    config as revlog_config,
    constants as revlogconst,
)


def resolve_store_vfs_options(ui, requirements, features):
    """Resolve the options to pass to the store vfs opener.

    The returned dict is used to influence behavior of the storage layer.
    """
    options = {}

    if requirementsmod.TREEMANIFEST_REQUIREMENT in requirements:
        options[b'treemanifest'] = True

    # experimental config: format.manifestcachesize
    manifestcachesize = ui.configint(b'format', b'manifestcachesize')
    if manifestcachesize is not None:
        options[b'manifestcachesize'] = manifestcachesize

    # In the absence of another requirement superseding a revlog-related
    # requirement, we have to assume the repo is using revlog version 0.
    # This revlog format is super old and we don't bother trying to parse
    # opener options for it because those options wouldn't do anything
    # meaningful on such old repos.
    if (
        requirementsmod.REVLOGV1_REQUIREMENT in requirements
        or requirementsmod.REVLOGV2_REQUIREMENT in requirements
    ):
        rso = resolve_revlog_store_vfs_options(ui, requirements, features)
        options.update(rso)
    else:  # explicitly mark repo as using revlogv0
        options[b'revlogv0'] = True

    if requirementsmod.COPIESSDC_REQUIREMENT in requirements:
        options[b'copies-storage'] = b'changeset-sidedata'
    else:
        writecopiesto = ui.config(b'experimental', b'copies.write-to')
        copiesextramode = (b'changeset-only', b'compatibility')
        if writecopiesto in copiesextramode:
            options[b'copies-storage'] = b'extra'

    if requirementsmod.FILEINDEXV1_REQUIREMENT in requirements:
        value = ui.configint(b'storage', b'fileindex.max-unused-percentage')
        if not 0 <= value <= 100:
            fallback = ui.configdefault(
                b'storage', b'fileindex.max-unused-percentage'
            )
            msg = _(
                b'warning: invalid storage.fileindex.max-unused-percentage '
                b'value %d (must be between 0 and 100); falling back to %d'
                % (value, fallback)
            )
            ui.warn(msg)
            value = fallback
        options[b'fileindex-max-unused-percentage'] = value

    return options


def resolve_revlog_store_vfs_options(ui, requirements, features):
    """Resolve opener options specific to revlogs."""

    options = {}
    options[b'flagprocessors'] = {}

    feature_config = options[b'feature-config'] = revlog_config.FeatureConfig()
    data_config = options[b'data-config'] = revlog_config.DataConfig()
    delta_config = options[b'delta-config'] = revlog_config.DeltaConfig()

    if requirementsmod.REVLOGV1_REQUIREMENT in requirements:
        options[b'revlogv1'] = True
    if requirementsmod.REVLOGV2_REQUIREMENT in requirements:
        options[b'revlogv2'] = True
    if requirementsmod.CHANGELOGV2_REQUIREMENT in requirements:
        options[b'changelogv2'] = True
        cmp_rank = ui.configbool(b'experimental', b'changelog-v2.compute-rank')
        options[b'changelogv2.compute-rank'] = cmp_rank

    if requirementsmod.GENERALDELTA_REQUIREMENT in requirements:
        options[b'generaldelta'] = True

    if requirementsmod.FILELOG_METAFLAG_REQUIREMENT in requirements:
        options[b'filelog_hasmeta_flag'] = True

    if requirementsmod.DELTA_INFO_REQUIREMENT in requirements:
        options[b'delta-info-flags'] = True

    # experimental config: format.chunkcachesize
    chunkcachesize = ui.configint(b'format', b'chunkcachesize')
    if chunkcachesize is not None:
        data_config.chunk_cache_size = chunkcachesize

    memory_profile = scmutil.get_resource_profile(ui, b'memory')
    if memory_profile >= scmutil.RESOURCE_MEDIUM:
        data_config.uncompressed_cache_count = 10_000
        data_config.uncompressed_cache_factor = 4
        if memory_profile >= scmutil.RESOURCE_HIGH:
            data_config.uncompressed_cache_factor = 10

    delta_config.delta_both_parents = ui.configbool(
        b'storage', b'revlog.optimize-delta-parent-choice'
    )
    delta_config.candidate_group_chunk_size = ui.configint(
        b'storage',
        b'revlog.delta-parent-search.candidate-group-chunk-size',
    )
    delta_config.debug_delta = ui.configbool(b'debug', b'revlog.debug-delta')

    issue6528 = ui.configbool(b'storage', b'revlog.issue6528.fix-incoming')
    options[b'issue6528.fix-incoming'] = issue6528

    lazydelta = ui.configbool(b'storage', b'revlog.reuse-external-delta')
    lazydeltabase = False
    if lazydelta:
        lazydeltabase = ui.configbool(
            b'storage', b'revlog.reuse-external-delta-parent'
        )
        if lazydeltabase is None:
            lazydeltabase = not scmutil.gddeltaconfig(ui)
    delta_config.lazy_delta = lazydelta
    delta_config.lazy_delta_base = lazydeltabase
    delta_config.filter_suspicious_delta = not ui.configbool(
        b'storage',
        b'revlog.reuse-external-suspicious-delta-parent',
    )

    chainspan = ui.configbytes(b'experimental', b'maxdeltachainspan')
    if 0 <= chainspan:
        delta_config.max_deltachain_span = chainspan

    has_populate = util.has_mmap_populate()
    if ui.configbool(b'storage', b'revlog.mmap.index', has_populate):
        data_config.mmap_index_threshold = ui.configbytes(
            b'storage',
            b'revlog.mmap.index:size-threshold',
        )

    withsparseread = ui.configbool(b'experimental', b'sparse-read')
    srdensitythres = float(
        ui.config(b'experimental', b'sparse-read.density-threshold')
    )
    srmingapsize = ui.configbytes(b'experimental', b'sparse-read.min-gap-size')
    data_config.with_sparse_read = withsparseread
    data_config.sr_density_threshold = srdensitythres
    data_config.sr_min_gap_size = srmingapsize

    sparserevlog = requirementsmod.SPARSEREVLOG_REQUIREMENT in requirements
    delta_config.sparse_revlog = sparserevlog
    if sparserevlog:
        options[b'generaldelta'] = True
        data_config.with_sparse_read = True

    maxchainlen = None
    if sparserevlog:
        maxchainlen = revlogconst.SPARSE_REVLOG_MAX_CHAIN_LENGTH
    # experimental config: format.maxchainlen
    maxchainlen = ui.configint(b'format', b'maxchainlen', maxchainlen)
    if maxchainlen is not None:
        delta_config.max_chain_len = maxchainlen

    file_comp_ratio = ui.configint(
        b'storage', b'filelog.expected-max-compression-ratio'
    )
    if file_comp_ratio > 0:
        delta_config.file_max_comp_ratio = file_comp_ratio

    use_folding = ui.config(
        b'storage',
        b'delta-fold-estimate',
    )
    if use_folding == b"always":
        delta_config.delta_fold_estimate = True
    if use_folding == b"when-fast":
        delta_config.delta_fold_estimate = policy.has_rust()
    elif use_folding == b"never":
        delta_config.delta_fold_estimate = False

    fold_tolerance = ui.configint(
        b'storage',
        b'delta-fold-tolerance-percentage',
    )
    if fold_tolerance < 0:
        delta_config.delta_fold_tolerance = None
    else:
        delta_config.delta_fold_tolerance = float((100 + fold_tolerance) / 100)

    for r in requirements:
        # we allow multiple compression engine requirement to co-exist because
        # strickly speaking, revlog seems to support mixed compression style.
        #
        # The compression used for new entries will be "the last one"
        prefix = r.startswith
        if prefix(b'revlog-compression-') or prefix(b'exp-compression-'):
            feature_config.compression_engine = r.split(b'-', 2)[2]

    zlib_level = ui.configint(b'storage', b'revlog.zlib.level')
    if zlib_level is not None:
        if not (0 <= zlib_level <= 9):
            msg = _(b'invalid value for `storage.revlog.zlib.level` config: %d')
            raise error.Abort(msg % zlib_level)
    feature_config.compression_engine_options[b'zlib.level'] = zlib_level
    zstd_level = ui.configint(b'storage', b'revlog.zstd.level')
    if zstd_level is not None:
        if not (0 <= zstd_level <= 22):
            msg = _(b'invalid value for `storage.revlog.zstd.level` config: %d')
            raise error.Abort(msg % zstd_level)
    feature_config.compression_engine_options[b'zstd.level'] = zstd_level

    if requirementsmod.NARROW_REQUIREMENT in requirements:
        feature_config.enable_ellipsis = True

    if ui.config(b"censor", b"policy") == b"ignore":
        feature_config.ignore_filelog_censored_revisions = True

    if ui.configbool(b'experimental', b'rust.index'):
        options[b'rust.index'] = True
    if requirementsmod.NODEMAP_REQUIREMENT in requirements:
        slow_path = ui.config(
            b'storage', b'revlog.persistent-nodemap.slow-path'
        )
        if slow_path == b'default':
            slow_path = ui.config(b'storage', b'all-slow-path')
        if slow_path not in (b'allow', b'warn', b'abort'):
            default = ui.config_default(b'storage', b'all-slow-path')
            msg = _(
                b'unknown value for config '
                b'"storage.revlog.persistent-nodemap.slow-path": "%s"\n'
            )
            ui.warn(msg % slow_path)
            if not ui.quiet:
                ui.warn(_(b'falling back to default value: %s\n') % default)
            slow_path = default

        msg = _(
            b"accessing `persistent-nodemap` repository without associated "
            b"fast implementation."
        )
        hint = _(
            b"check `hg help config.format.use-persistent-nodemap` "
            b"for details"
        )
        if not revlog.HAS_FAST_PERSISTENT_NODEMAP:
            if slow_path == b'warn':
                msg = b"warning: " + msg + b'\n'
                ui.warn(msg)
                if not ui.quiet:
                    hint = b'(' + hint + b')\n'
                    ui.warn(hint)
            if slow_path == b'abort':
                raise error.Abort(msg, hint=hint)
        options[b'persistent-nodemap'] = True
    if requirementsmod.DIRSTATE_V2_REQUIREMENT in requirements:
        slow_path = ui.config(b'storage', b'dirstate-v2.slow-path')
        if slow_path == b'default':
            slow_path = ui.config(b'storage', b'all-slow-path')
        if slow_path not in (b'allow', b'warn', b'abort'):
            default = ui.config_default(b'storage', b'all-slow-path')
            msg = _(b'unknown value for config "dirstate-v2.slow-path": "%s"\n')
            ui.warn(msg % slow_path)
            if not ui.quiet:
                ui.warn(_(b'falling back to default value: %s\n') % default)
            slow_path = default

        msg = _(
            b"accessing `dirstate-v2` repository without associated "
            b"fast implementation."
        )
        hint = _(
            b"check `hg help config.format.use-dirstate-v2` " b"for details"
        )
        if not dirstate.HAS_FAST_DIRSTATE_V2:
            if slow_path == b'warn':
                msg = b"warning: " + msg + b'\n'
                ui.warn(msg)
                if not ui.quiet:
                    hint = b'(' + hint + b')\n'
                    ui.warn(hint)
            if slow_path == b'abort':
                raise error.Abort(msg, hint=hint)
    if ui.configbool(b'storage', b'revlog.persistent-nodemap.mmap'):
        options[b'persistent-nodemap.mmap'] = True
    if ui.configbool(b'devel', b'persistent-nodemap'):
        options[b'devel-force-nodemap'] = True

    delta_config.validate_base = ui.configbool(
        b'storage', b'revlog.validate-delta-base'
    )

    return options
