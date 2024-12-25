// revlog/config.rs
//
// Copyright 2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
use pyo3::conversion::FromPyObject;
use pyo3::exceptions::PyValueError;
use pyo3::intern;

use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyDict, PyDictMethods};

use std::sync::OnceLock;

use hg::revlog::{
    compression::CompressionConfig,
    options::{RevlogDataConfig, RevlogDeltaConfig, RevlogFeatureConfig},
    RevlogType,
};

/// Helper trait for configuration dicts
///
/// In Mercurial, it is customary for such dicts to have bytes keys.
trait ConfigPyDict<'a, 'py: 'a, D: FromPyObject<'py>> {
    fn extract_item(&'a self, key: &[u8]) -> PyResult<Option<D>>;
}

impl<'a, 'py, D> ConfigPyDict<'a, 'py, D> for Bound<'py, PyDict>
where
    'py: 'a,
    D: FromPyObject<'py>,
{
    fn extract_item(&'a self, key: &[u8]) -> PyResult<Option<D>> {
        let py_item = self.get_item(PyBytes::new(self.py(), key))?;
        match py_item {
            Some(value) => {
                if value.is_none() {
                    Ok(None)
                } else {
                    Ok(Some(value.extract()?))
                }
            }
            None => Ok(None),
        }
    }
}

/// Extraction helper for PyObject attributes.
///
/// `$obj` is a `Bound('_, PyAny)` and `$attr` is a static String slice.
/// This is both syntactic sugar and more efficient than using `getattr()`
/// manually, as this uses [`intern!`] for efficiency.
///
/// See the many examples in this module.
///
/// This does not work to return references (e.g. bytes). Quoting the
/// compiler: "returns a value referencing data owned by the current function"
macro_rules! extract_attr {
    ($obj: expr, $attr: expr) => {
        $obj.getattr(intern!($obj.py(), $attr))
            .and_then(|a| a.extract())
    };
}

// There are no static generics in Rust (because their implementation is
// hard, I'm guessing it's due to different compilation stages, etc.).
// So manually generate all three caches and use them in
// `with_filelog_cache`.
static DELTA_CONFIG_CACHE: OnceLock<(PyObject, RevlogDeltaConfig)> =
    OnceLock::new();
static DATA_CONFIG_CACHE: OnceLock<(PyObject, RevlogDataConfig)> =
    OnceLock::new();
static FEATURE_CONFIG_CACHE: OnceLock<(PyObject, RevlogFeatureConfig)> =
    OnceLock::new();

/// TODO don't do this and build a `Config` in Rust, expose it to Python and
/// downcast it (after refactoring Python to re-use the same config objects?).
///
/// Cache the first conversion from Python of filelog config. Other
/// revlog types are not cached.
///
/// All filelogs in a given repository *most likely* have the
/// exact same config, hence it makes a difference to look it up
/// from Python code only once, especially given that it can be in a
/// loop.
fn with_filelog_config_cache<T: Copy>(
    py_config: &Bound<'_, PyAny>,
    revlog_type: RevlogType,
    cache: &OnceLock<(PyObject, T)>,
    callback: impl Fn() -> PyResult<T>,
) -> PyResult<T> {
    let mut was_cached = false;
    if revlog_type == RevlogType::Filelog {
        if let Some((cached_py_config, rust_config)) = cache.get() {
            was_cached = true;
            // it's not impossible that some extensions
            // do some magic with configs or that this code will be used
            // for longer-running processes. So compare the source
            // `PyObject` in case the source changed, at
            // the cost of some overhead. We can't use
            // `py_config.eq(cached_py_config)` because all config
            // objects are different in Python and `a is b` is false.
            if py_config.compare(cached_py_config)?.is_eq() {
                return Ok(*rust_config);
            }
        }
    }
    let config = callback()?;
    // Do not call the lock unnecessarily if it's already been set.
    if !was_cached && revlog_type == RevlogType::Filelog {
        cache.set((py_config.clone().unbind(), config)).ok();
    }
    Ok(config)
}

pub fn extract_delta_config(
    conf: &Bound<'_, PyAny>,
    revlog_type: RevlogType,
) -> PyResult<RevlogDeltaConfig> {
    with_filelog_config_cache(conf, revlog_type, &DELTA_CONFIG_CACHE, || {
        let max_deltachain_span: i64 =
            extract_attr!(conf, "max_deltachain_span")?;
        let revlog_delta_config = RevlogDeltaConfig {
            general_delta: extract_attr!(conf, "general_delta")?,
            sparse_revlog: extract_attr!(conf, "sparse_revlog")?,
            max_chain_len: extract_attr!(conf, "max_chain_len")?,
            max_deltachain_span: if max_deltachain_span < 0 {
                None
            } else {
                Some(max_deltachain_span as u64)
            },
            upper_bound_comp: extract_attr!(conf, "upper_bound_comp")?,
            delta_both_parents: extract_attr!(conf, "delta_both_parents")?,
            candidate_group_chunk_size: extract_attr!(
                conf,
                "candidate_group_chunk_size"
            )?,
            debug_delta: extract_attr!(conf, "debug_delta")?,
            lazy_delta: extract_attr!(conf, "lazy_delta")?,
            lazy_delta_base: extract_attr!(conf, "lazy_delta_base")?,
        };
        Ok(revlog_delta_config)
    })
}

pub fn extract_data_config(
    conf: &Bound<'_, PyAny>,
    revlog_type: RevlogType,
) -> PyResult<RevlogDataConfig> {
    with_filelog_config_cache(conf, revlog_type, &DATA_CONFIG_CACHE, || {
        Ok(RevlogDataConfig {
            try_pending: extract_attr!(conf, "try_pending")?,
            try_split: extract_attr!(conf, "try_split")?,
            check_ambig: extract_attr!(conf, "check_ambig")?,
            mmap_large_index: extract_attr!(conf, "mmap_large_index")?,
            mmap_index_threshold: extract_attr!(conf, "mmap_index_threshold")?,
            chunk_cache_size: extract_attr!(conf, "chunk_cache_size")?,
            uncompressed_cache_factor: extract_attr!(
                conf,
                "uncompressed_cache_factor"
            )?,
            uncompressed_cache_count: extract_attr!(
                conf,
                "uncompressed_cache_count"
            )?,
            with_sparse_read: extract_attr!(conf, "with_sparse_read")?,
            sr_density_threshold: extract_attr!(conf, "sr_density_threshold")?,
            sr_min_gap_size: extract_attr!(conf, "sr_min_gap_size")?,
            general_delta: extract_attr!(conf, "generaldelta")?,
        })
    })
}

fn extract_compression_config(
    conf: &Bound<'_, PyAny>,
) -> PyResult<CompressionConfig> {
    let compression_options: Bound<'_, PyDict> =
        extract_attr!(conf, "compression_engine_options")?;

    let name_bound = conf.getattr("compression_engine")?;
    let name_bytes: &[u8] = name_bound.extract()?;

    let compression_engine = match name_bytes {
        b"zlib" => {
            let level = compression_options.extract_item(b"zlib.level")?;
            let mut engine = CompressionConfig::default();
            if let Some(level) = level {
                engine
                    .set_level(level)
                    .expect("invalid compression level from Python");
            }
            engine
        }
        b"zstd" => {
            let zstd_level =
                compression_options.extract_item(b"zstd.level")?;
            let level = if let Some(level) = zstd_level {
                Some(level)
            } else {
                compression_options.extract_item(b"level")?
            };

            CompressionConfig::zstd(level)
                .expect("invalid compression level from Python")
        }
        b"none" => CompressionConfig::None,
        unknown => {
            return Err(PyValueError::new_err(format!(
                "invalid compression engine {}",
                String::from_utf8_lossy(unknown)
            )));
        }
    };
    Ok(compression_engine)
}

pub fn extract_feature_config(
    conf: &Bound<'_, PyAny>,
    revlog_type: RevlogType,
) -> PyResult<RevlogFeatureConfig> {
    with_filelog_config_cache(conf, revlog_type, &FEATURE_CONFIG_CACHE, || {
        Ok(RevlogFeatureConfig {
            compression_engine: extract_compression_config(conf)?,
            censorable: extract_attr!(conf, "censorable")?,
            has_side_data: extract_attr!(conf, "has_side_data")?,
            compute_rank: extract_attr!(conf, "compute_rank")?,
            canonical_parent_order: extract_attr!(
                conf,
                "canonical_parent_order"
            )?,
            enable_ellipsis: extract_attr!(conf, "enable_ellipsis")?,
        })
    })
}
