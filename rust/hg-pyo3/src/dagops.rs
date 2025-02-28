// dagops.rs
//
// Copyright 2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::dagops` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.dagop`
use pyo3::prelude::*;

use std::collections::HashSet;

use hg::{dagops, Revision};

use crate::exceptions::GraphError;
use crate::revision::{rev_pyiter_collect, PyRevision};
use crate::utils::{new_submodule, proxy_index_extract};

/// Using the the `index_proxy`, return heads out of any Python iterable of
/// Revisions
///
/// This is the Rust counterpart for `mercurial.dagop.headrevs`
#[pyfunction]
pub fn headrevs(
    index_proxy: &Bound<'_, PyAny>,
    revs: &Bound<'_, PyAny>,
) -> PyResult<HashSet<PyRevision>> {
    // Safety: we don't leak the "faked" reference out of `SharedByPyObject`
    let index = unsafe { proxy_index_extract(index_proxy)? };
    let mut as_set: HashSet<Revision> = rev_pyiter_collect(revs, index)?;
    dagops::retain_heads(index, &mut as_set).map_err(GraphError::from_hg)?;
    Ok(as_set.into_iter().map(Into::into).collect())
}

/// Computes the rank, i.e. the number of ancestors including itself,
/// of a node represented by its parents.
///
/// Currently, the pure Rust index supports only the REVLOGV1 format, hence
/// the only possible return value is that the rank is unknown.
///
/// References:
/// - C implementation, function `index_fast_rank()`.
/// - `impl vcsgraph::graph::RankedGraph for Index` in `crate::cindex`.
#[pyfunction]
pub fn rank(
    _index: &Bound<'_, PyAny>,
    _p1r: PyRevision,
    _p2r: PyRevision,
) -> PyResult<()> {
    Err(GraphError::from_vcsgraph(
        vcsgraph::graph::GraphReadError::InconsistentGraphData,
    ))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "dagop")?;
    m.add_function(wrap_pyfunction!(headrevs, &m)?)?;
    m.add_function(wrap_pyfunction!(rank, &m)?)?;
    Ok(m)
}
