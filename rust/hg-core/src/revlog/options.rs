//! Helpers for the revlog config and opening options

use std::collections::HashSet;

use crate::{
    config::{Config, ResourceProfileValue},
    errors::HgError,
    requirements::{
        CHANGELOGV2_REQUIREMENT, GENERALDELTA_REQUIREMENT, NARROW_REQUIREMENT,
        NODEMAP_REQUIREMENT, REVLOGV1_REQUIREMENT, REVLOGV2_REQUIREMENT,
        SPARSEREVLOG_REQUIREMENT,
    },
};

use super::{compression::CompressionConfig, RevlogType};

const DEFAULT_CHUNK_CACHE_SIZE: u64 = 65536;
const DEFAULT_SPARSE_READ_DENSITY_THRESHOLD: f64 = 0.50;
const DEFAULT_SPARSE_READ_MIN_GAP_SIZE: u64 = 262144;

/// The known revlog versions and their options
#[derive(Debug, Copy, Clone, PartialEq)]
pub enum RevlogVersionOptions {
    V0,
    V1 { general_delta: bool, inline: bool },
    V2,
    ChangelogV2 { compute_rank: bool },
}

/// Options to govern how a revlog should be opened, usually from the
/// repository configuration or requirements.
#[derive(Debug, Copy, Clone)]
pub struct RevlogOpenOptions {
    /// The revlog version, along with any option specific to this version
    pub version: RevlogVersionOptions,
    /// Whether the revlog uses a persistent nodemap.
    pub use_nodemap: bool,
    pub delta_config: RevlogDeltaConfig,
    pub data_config: RevlogDataConfig,
    pub feature_config: RevlogFeatureConfig,
}

#[cfg(test)]
impl Default for RevlogOpenOptions {
    fn default() -> Self {
        Self {
            version: RevlogVersionOptions::V1 {
                general_delta: true,
                inline: false,
            },
            use_nodemap: true,
            data_config: Default::default(),
            delta_config: Default::default(),
            feature_config: Default::default(),
        }
    }
}

impl RevlogOpenOptions {
    pub fn new(
        inline: bool,
        data_config: RevlogDataConfig,
        delta_config: RevlogDeltaConfig,
        feature_config: RevlogFeatureConfig,
    ) -> Self {
        Self {
            version: RevlogVersionOptions::V1 {
                general_delta: data_config.general_delta,
                inline,
            },
            use_nodemap: false,
            data_config,
            delta_config,
            feature_config,
        }
    }

    pub fn index_header(&self) -> super::index::IndexHeader {
        super::index::IndexHeader {
            header_bytes: match self.version {
                RevlogVersionOptions::V0 => [0, 0, 0, 0],
                RevlogVersionOptions::V1 {
                    general_delta,
                    inline,
                } => [
                    0,
                    if general_delta && inline {
                        3
                    } else if general_delta {
                        2
                    } else {
                        u8::from(inline)
                    },
                    0,
                    1,
                ],
                RevlogVersionOptions::V2 => 0xDEADu32.to_be_bytes(),
                RevlogVersionOptions::ChangelogV2 { compute_rank: _ } => {
                    0xD34Du32.to_be_bytes()
                }
            },
        }
    }
}

/// Technically only Linux 2.5.46+ has `MAP_POPULATE` and only `2.6.23` on
/// private mappings, but if you're using such ancient Linux, you have other
/// problems.
#[cfg(target_os = "linux")]
const fn can_populate_mmap() -> bool {
    true
}

/// There is a of populating mmaps for Windows, but it would need testing.
#[cfg(not(target_os = "linux"))]
const fn can_populate_mmap() -> bool {
    false
}

#[derive(Debug, Clone, Copy, PartialEq)]
/// Holds configuration values about how the revlog data is read
pub struct RevlogDataConfig {
    /// Should we try to open the "pending" version of the revlog
    pub try_pending: bool,
    /// Should we try to open the "split" version of the revlog
    pub try_split: bool,
    /// When True, `indexfile` should be opened with `checkambig=True` at
    /// writing time, to avoid file stat ambiguity
    pub check_ambig: bool,
    /// If true, use mmap instead of reading to deal with large indexes
    pub mmap_large_index: bool,
    /// How much data is considered large
    pub mmap_index_threshold: Option<u64>,
    /// How much data to read and cache into the raw revlog data cache
    pub chunk_cache_size: u64,
    /// The size of the uncompressed cache compared to the largest revision
    /// seen
    pub uncompressed_cache_factor: Option<f64>,
    /// The number of chunks cached
    pub uncompressed_cache_count: Option<u64>,
    /// Allow sparse reading of the revlog data
    pub with_sparse_read: bool,
    /// Minimal density of a sparse read chunk
    pub sr_density_threshold: f64,
    /// Minimal size of the data we skip when performing sparse reads
    pub sr_min_gap_size: u64,
    /// Whether deltas are encoded against arbitrary bases
    pub general_delta: bool,
}

impl RevlogDataConfig {
    pub fn new(
        config: &Config,
        requirements: &HashSet<String>,
    ) -> Result<Self, HgError> {
        let mut data_config = Self::default();
        if let Some(chunk_cache_size) =
            config.get_byte_size(b"format", b"chunkcachesize")?
        {
            data_config.chunk_cache_size = chunk_cache_size;
        }

        let memory_profile = config.get_resource_profile(Some("memory"));
        if memory_profile.value >= ResourceProfileValue::Medium {
            data_config.uncompressed_cache_count = Some(10_000);
            data_config.uncompressed_cache_factor = Some(4.0);
            if memory_profile.value >= ResourceProfileValue::High {
                data_config.uncompressed_cache_factor = Some(10.0)
            }
        }

        // Use mmap if requested, or by default if we can fully populate it
        let mmap_index = config
            .get_option_no_default(b"storage", b"revlog.mmap.index")?
            .unwrap_or(can_populate_mmap());
        if mmap_index {
            if let Some(mmap_index_threshold) = config.get_byte_size(
                b"storage",
                b"revlog.mmap.index:size-threshold",
            )? {
                // Only mmap if above the requested size threshold
                data_config.mmap_index_threshold = Some(mmap_index_threshold);
            }
        }

        let with_sparse_read =
            config.get_bool(b"experimental", b"sparse-read")?;
        if let Some(sr_density_threshold) = config
            .get_f64(b"experimental", b"sparse-read.density-threshold")?
        {
            data_config.sr_density_threshold = sr_density_threshold;
        }
        data_config.with_sparse_read = with_sparse_read;
        if let Some(sr_min_gap_size) = config
            .get_byte_size(b"experimental", b"sparse-read.min-gap-size")?
        {
            data_config.sr_min_gap_size = sr_min_gap_size;
        }

        data_config.with_sparse_read =
            requirements.contains(SPARSEREVLOG_REQUIREMENT);

        Ok(data_config)
    }
}

impl Default for RevlogDataConfig {
    fn default() -> Self {
        Self {
            chunk_cache_size: DEFAULT_CHUNK_CACHE_SIZE,
            sr_density_threshold: DEFAULT_SPARSE_READ_DENSITY_THRESHOLD,
            sr_min_gap_size: DEFAULT_SPARSE_READ_MIN_GAP_SIZE,
            try_pending: Default::default(),
            try_split: Default::default(),
            check_ambig: Default::default(),
            mmap_large_index: Default::default(),
            mmap_index_threshold: Default::default(),
            uncompressed_cache_factor: Default::default(),
            uncompressed_cache_count: Default::default(),
            with_sparse_read: Default::default(),
            general_delta: Default::default(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
/// Holds configuration values about how new deltas are computed.
///
/// Some attributes are duplicated from [`RevlogDataConfig`] to help having
/// each object self contained.
pub struct RevlogDeltaConfig {
    /// Whether deltas can be encoded against arbitrary bases
    pub general_delta: bool,
    /// Allow sparse writing of the revlog data
    pub sparse_revlog: bool,
    /// Maximum length of a delta chain
    pub max_chain_len: Option<u64>,
    /// Maximum distance between a delta chain's start and end
    pub max_deltachain_span: Option<u64>,
    /// If `upper_bound_comp` is not None, this is the expected maximal
    /// gain from compression for the data content
    pub upper_bound_comp: Option<f64>,
    /// Should we try a delta against both parents
    pub delta_both_parents: bool,
    /// Test delta base candidate groups by chunks of this maximal size
    pub candidate_group_chunk_size: u64,
    /// Should we display debug information about delta computation
    pub debug_delta: bool,
    /// Trust incoming deltas by default
    pub lazy_delta: bool,
    /// Trust the base of incoming deltas by default
    pub lazy_delta_base: bool,
}

impl RevlogDeltaConfig {
    pub fn new(
        config: &Config,
        requirements: &HashSet<String>,
        revlog_type: RevlogType,
    ) -> Result<Self, HgError> {
        let mut delta_config = Self {
            delta_both_parents: config
                .get_option_no_default(
                    b"storage",
                    b"revlog.optimize-delta-parent-choice",
                )?
                .unwrap_or(true),
            candidate_group_chunk_size: config
                .get_u64(
                    b"storage",
                    b"revlog.delta-parent-search.candidate-group-chunk-size",
                )?
                .unwrap_or_default(),
            ..Default::default()
        };

        delta_config.debug_delta =
            config.get_bool(b"debug", b"revlog.debug-delta")?;

        delta_config.general_delta =
            requirements.contains(GENERALDELTA_REQUIREMENT);

        let lazy_delta =
            config.get_bool(b"storage", b"revlog.reuse-external-delta")?;

        if revlog_type == RevlogType::Manifestlog {
            // upper bound of what we expect from compression
            // (real life value seems to be 3)
            delta_config.upper_bound_comp = Some(3.0)
        }

        let mut lazy_delta_base = false;
        if lazy_delta {
            lazy_delta_base = match config.get_option_no_default(
                b"storage",
                b"revlog.reuse-external-delta-parent",
            )? {
                Some(base) => base,
                None => config.get_bool(b"format", b"generaldelta")?,
            };
        }
        delta_config.lazy_delta = lazy_delta;
        delta_config.lazy_delta_base = lazy_delta_base;

        delta_config.max_deltachain_span =
            match config.get_i64(b"experimental", b"maxdeltachainspan")? {
                Some(span) => {
                    if span < 0 {
                        None
                    } else {
                        Some(span as u64)
                    }
                }
                None => None,
            };

        delta_config.sparse_revlog =
            requirements.contains(SPARSEREVLOG_REQUIREMENT);

        delta_config.max_chain_len =
            config.get_byte_size_no_default(b"format", b"maxchainlen")?;

        Ok(delta_config)
    }
}

impl Default for RevlogDeltaConfig {
    fn default() -> Self {
        Self {
            delta_both_parents: true,
            lazy_delta: true,
            general_delta: Default::default(),
            sparse_revlog: Default::default(),
            max_chain_len: Default::default(),
            max_deltachain_span: Default::default(),
            upper_bound_comp: Default::default(),
            candidate_group_chunk_size: Default::default(),
            debug_delta: Default::default(),
            lazy_delta_base: Default::default(),
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq)]
/// Holds configuration values about the available revlog features
pub struct RevlogFeatureConfig {
    /// The compression engine and its options
    pub compression_engine: CompressionConfig,
    /// Can we use censor on this revlog
    pub censorable: bool,
    /// Does this revlog use the "side data" feature
    pub has_side_data: bool,
    /// Might remove this configuration once the rank computation has no
    /// impact
    pub compute_rank: bool,
    /// Parent order is supposed to be semantically irrelevant, so we
    /// normally re-sort parents to ensure that the first parent is non-null,
    /// if there is a non-null parent at all.
    /// filelog abuses the parent order as a flag to mark some instances of
    /// meta-encoded files, so allow it to disable this behavior.
    pub canonical_parent_order: bool,
    /// Can ellipsis commit be used
    pub enable_ellipsis: bool,
}

impl RevlogFeatureConfig {
    pub fn new(
        config: &Config,
        requirements: &HashSet<String>,
    ) -> Result<Self, HgError> {
        Ok(Self {
            compression_engine: CompressionConfig::new(config, requirements)?,
            enable_ellipsis: requirements.contains(NARROW_REQUIREMENT),
            ..Default::default()
        })
    }
}

/// Return the default options for a revlog of `revlog_type` according to the
/// current config and requirements.
pub fn default_revlog_options(
    config: &Config,
    requirements: &HashSet<String>,
    revlog_type: RevlogType,
) -> Result<RevlogOpenOptions, HgError> {
    let is_changelog = revlog_type == RevlogType::Changelog;
    let version =
        if is_changelog && requirements.contains(CHANGELOGV2_REQUIREMENT) {
            let compute_rank = config
                .get_bool(b"experimental", b"changelog-v2.compute-rank")?;
            RevlogVersionOptions::ChangelogV2 { compute_rank }
        } else if requirements.contains(REVLOGV2_REQUIREMENT) {
            RevlogVersionOptions::V2
        } else if requirements.contains(REVLOGV1_REQUIREMENT) {
            RevlogVersionOptions::V1 {
                general_delta: requirements.contains(GENERALDELTA_REQUIREMENT),
                inline: !is_changelog,
            }
        } else {
            RevlogVersionOptions::V0
        };
    Ok(RevlogOpenOptions {
        version,
        // We don't need to dance around the slow path like in the Python
        // implementation since we know we have access to the fast code.
        use_nodemap: requirements.contains(NODEMAP_REQUIREMENT),
        delta_config: RevlogDeltaConfig::new(
            config,
            requirements,
            revlog_type,
        )?,
        data_config: RevlogDataConfig::new(config, requirements)?,
        feature_config: RevlogFeatureConfig::new(config, requirements)?,
    })
}
