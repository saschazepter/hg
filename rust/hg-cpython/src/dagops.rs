// dagops.rs
//
// Copyright 2019 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::dagops` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.rustext.dagop`
use crate::PyRevision;
use crate::{conversion::rev_pyiter_collect, exceptions::GraphError};
use cpython::{PyDict, PyModule, PyObject, PyResult, Python};
use hg::dagops;
use hg::Revision;
use std::collections::HashSet;
use vcsgraph::graph::Rank;

use crate::revlog::py_rust_index_to_graph;

/// Using the the `index`, return heads out of any Python iterable of Revisions
///
/// This is the Rust counterpart for `mercurial.dagop.headrevs`
pub fn headrevs(
    py: Python,
    index: PyObject,
    revs: PyObject,
) -> PyResult<HashSet<PyRevision>> {
    let py_leaked = py_rust_index_to_graph(py, index)?;
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    let index = &*unsafe { py_leaked.try_borrow(py)? };
    let mut as_set: HashSet<Revision> = rev_pyiter_collect(py, &revs, index)?;
    dagops::retain_heads(index, &mut as_set)
        .map_err(|e| GraphError::pynew(py, e))?;
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
pub fn rank(
    py: Python,
    _index: PyObject,
    _p1r: PyRevision,
    _p2r: PyRevision,
) -> PyResult<Rank> {
    Err(GraphError::pynew_from_vcsgraph(
        py,
        vcsgraph::graph::GraphReadError::InconsistentGraphData,
    ))
}

/// Create the module, with `__package__` given from parent
pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.dagop", package);
    let m = PyModule::new(py, dotted_name)?;
    m.add(py, "__package__", package)?;
    m.add(py, "__doc__", "DAG operations - Rust implementation")?;
    m.add(
        py,
        "headrevs",
        py_fn!(py, headrevs(index: PyObject, revs: PyObject)),
    )?;
    m.add(
        py,
        "rank",
        py_fn!(py, rank(index: PyObject, p1r: PyRevision, p2r: PyRevision)),
    )?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;
    // Example C code (see pyexpat.c and import.c) will "give away the
    // reference", but we won't because it will be consumed once the
    // Rust PyObject is dropped.
    Ok(m)
}
