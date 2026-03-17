# revlogutils/config.py - small config class for Revlogs
#
# Copyright 2023 Pierre-Yves David <pierre-yves.david@octobus,net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import typing
from typing import Optional

from ..thirdparty import attr

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr


class _Config:
    """Abstract Revlog Config class"""

    def copy(self):
        return self.__class__(**self.__dict__)


@attr.s()
class FeatureConfig(_Config):
    """Hold configuration values about the available revlog features"""

    # the default compression engine
    compression_engine = attr.ib(default=b'zlib', type=bytes)
    # compression engines options
    compression_engine_options = attr.ib(
        default=attr.Factory(dict),
        type=dict[bytes, Optional[int]],
    )

    # can we use censor on this revlog
    censorable = attr.ib(default=False, type=bool)
    # do we ignore filelog censored revisions and return an empty string
    ignore_filelog_censored_revisions = attr.ib(default=False)
    # does this revlog use the "side data" feature
    has_side_data = attr.ib(default=False, type=bool)
    # might remove rank configuration once the computation has no impact
    compute_rank = attr.ib(default=False, type=bool)
    # parent order is supposed to be semantically irrelevant, so we
    # normally resort parents to ensure that the first parent is non-null,
    # if there is a non-null parent at all.
    # filelog abuses the parent order as flag to mark some instances of
    # meta-encoded files, so allow it to disable this behavior.
    canonical_parent_order = attr.ib(default=True, type=bool)
    # can ellipsis commit be used
    enable_ellipsis = attr.ib(default=False, type=bool)

    # use a flag to signal that a filerevision constains metadata
    hasmeta_flag = attr.ib(default=False, type=bool)

    # When true, it is a valid option to use inline revlog for that revlog.
    #
    # This does mean the revlog is actually using inline. When set to False,
    # creating a new inline revlog will be prevented and existing inlined
    # revlog will we split at the first opportunity.
    may_inline = attr.ib(default=True, type=bool)

    def copy(self):
        new = super().copy()
        new.compression_engine_options = self.compression_engine_options.copy()
        return new


@attr.s()
class DataConfig(_Config):
    """Hold configuration value about how the revlog data are read"""

    # should we try to open the "pending" version of the revlog
    try_pending = attr.ib(default=False, type=bool)
    # should we try to open the "splitted" version of the revlog
    try_split = attr.ib(default=False, type=bool)
    #  When True, indexfile should be opened with checkambig=True at writing,
    #  to avoid file stat ambiguity.
    check_ambig = attr.ib(default=False, type=bool)

    # If true, use mmap instead of reading to deal with large index
    mmap_large_index = attr.ib(default=False, type=bool)
    # how much data is large
    mmap_index_threshold = attr.ib(default=None, type=Optional[int])
    # How much data to read and cache into the raw revlog data cache.
    chunk_cache_size = attr.ib(default=65536, type=int)

    # The size of the uncompressed cache compared to the largest revision seen.
    uncompressed_cache_factor = attr.ib(default=None, type=Optional[int])

    # The number of chunk cached
    uncompressed_cache_count = attr.ib(default=None, type=Optional[int])

    # Allow sparse reading of the revlog data
    with_sparse_read = attr.ib(default=False, type=bool)
    # minimal density of a sparse read chunk
    sr_density_threshold = attr.ib(default=0.50, type=float)
    # minimal size of data we skip when performing sparse read
    sr_min_gap_size = attr.ib(default=262144, type=int)

    # are delta encoded against arbitrary bases.
    generaldelta = attr.ib(default=False, type=bool)

    # index contains extra delta information
    #
    # (It is useful to have it here in addition to the one in DeltaConfig when
    # we need to exchange related information)
    delta_info = attr.ib(default=False)


@attr.s()
class DeltaConfig(_Config):
    """Hold configuration value about how new delta are computed

    Some attributes are duplicated from DataConfig to help havign each object
    self contained.
    """

    # should we attemps to store delta at all (typically false for changelog)
    store_delta_chain = attr.ib(default=True, type=bool)
    # can delta be encoded against arbitrary bases.
    general_delta = attr.ib(default=False, type=bool)
    # Allow sparse writing of the revlog data
    sparse_revlog = attr.ib(default=False, type=bool)
    # index contains extra delta information
    delta_info = attr.ib(default=False)
    # store delta quality information when possible
    store_quality = attr.ib(default=True, type=bool)
    # maximum length of a delta chain
    max_chain_len = attr.ib(default=None, type=Optional[int])
    # Maximum distance between delta chain base start and end
    max_deltachain_span = attr.ib(default=-1, type=int)
    # If `upper_bound_comp` is not None, this is the expected maximal gain from
    # compression for the data content.
    upper_bound_comp = attr.ib(default=None, type=int)
    # Should we try a delta against both parent
    delta_both_parents = attr.ib(default=True, type=bool)
    # Test delta base candidate group by chunk of this maximal size.
    candidate_group_chunk_size = attr.ib(default=0, type=int)
    # Should we display debug information about delta computation
    debug_delta = attr.ib(default=False, type=bool)
    # trust incoming delta by default
    lazy_delta = attr.ib(default=True, type=bool)
    # trust the base of incoming delta by default
    lazy_delta_base = attr.ib(default=False, type=bool)
    # trust the incoming compression if available (and compatible)
    lazy_compression = attr.ib(default=True, type=bool)
    # don't used incoming delta if they don't look optimal
    filter_suspicious_delta = attr.ib(default=False, type=bool)
    # check integrity of candidate bases before computing a delta against them
    validate_base = attr.ib(default=False, type=bool)
    # A theoretical maximum compression ratio for file content
    # Used to estimate delta size before compression. value <= 0 disable such
    # estimate.
    file_max_comp_ratio = attr.ib(default=10, type=int)
    # Use delta folding to estimate the size of a delta before actually
    # computing it.
    delta_fold_estimate = attr.ib(default=True, type=bool)
    # the maximal ratio between the original delta and a new delta optimized by folding.
    #
    # a value of None means the feature is disabled.
    delta_fold_tolerance = attr.ib(default=True, type=Optional[float])


@attr.s()
class RevlogConfigs:
    """Gather the revlog config object for ease of use

    It still make sense to split the config into multiple sub object because
    they can be passed around independently."""

    data = attr.ib(default=attr.Factory(lambda: DataConfig()), type=DataConfig)
    delta = attr.ib(
        default=attr.Factory(lambda: DeltaConfig()), type=DeltaConfig
    )
    feature = attr.ib(
        default=attr.Factory(lambda: FeatureConfig()), type=FeatureConfig
    )

    def copy(self):
        return self.__class__(
            data=self.data.copy(),
            delta=self.delta.copy(),
            feature=self.feature.copy(),
        )

    @classmethod
    def from_opts(
        cls,
        options,
        data_config=None,
        delta_config=None,
        feature_config=None,
    ):
        """Build a RevlogConfigs object from the vfs's options

        The function will fallback to default value when the vfs's options
        don't hold the relevant information.
        """
        if feature_config is not None:
            feature = feature_config.copy()
        elif b'feature-config' in options:
            feature = options[b'feature-config'].copy()
        else:
            feature = FeatureConfig()
        if data_config is not None:
            data = data_config.copy()
        elif b'data-config' in options:
            data = options[b'data-config'].copy()
        else:
            data = DataConfig()
        if delta_config is not None:
            delta = delta_config.copy()
        elif b'delta-config' in options:
            delta = options[b'delta-config'].copy()
        else:
            delta = DeltaConfig()
        return cls(
            data=data,
            delta=delta,
            feature=feature,
        )
