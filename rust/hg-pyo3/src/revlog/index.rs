// revlog/index.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//           2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Utilities for dealing with the index at the Python boundary
use hg::{BaseRevision, Graph};
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyTuple};
use vcsgraph::graph::Graph as VCSGraph;

use hg::revlog::{
    index::{Index, RevisionDataParams},
    Node, Revision, RevlogIndex,
};

#[derive(derive_more::From, Clone)]
pub struct PySharedIndex {
    /// The underlying hg-core index
    inner: &'static Index,
}

impl PySharedIndex {
    /// Return a reference to the inner index, bound by `self`
    pub fn inner(&self) -> &Index {
        self.inner
    }

    /// Return an unsafe "faked" `'static` reference to the inner index, for
    /// the purposes of Python <-> Rust memory sharing.
    pub unsafe fn static_inner(&self) -> &'static Index {
        self.inner
    }
}

impl RevlogIndex for PySharedIndex {
    fn len(&self) -> usize {
        self.inner.len()
    }
    fn node(&self, rev: Revision) -> Option<&Node> {
        self.inner.node(rev)
    }
}

impl Graph for PySharedIndex {
    #[inline(always)]
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], hg::GraphError> {
        self.inner.parents(rev)
    }
}

impl VCSGraph for PySharedIndex {
    #[inline(always)]
    fn parents(
        &self,
        rev: BaseRevision,
    ) -> Result<vcsgraph::graph::Parents, vcsgraph::graph::GraphReadError>
    {
        // FIXME This trait should be reworked to decide between Revision
        // and UncheckedRevision, get better errors names, etc.
        match Graph::parents(self, Revision(rev)) {
            Ok(parents) => {
                Ok(vcsgraph::graph::Parents([parents[0].0, parents[1].0]))
            }
            Err(hg::GraphError::ParentOutOfRange(rev)) => {
                Err(vcsgraph::graph::GraphReadError::KeyedInvalidKey(rev.0))
            }
            Err(hg::GraphError::ParentOutOfOrder(rev)) => {
                Err(vcsgraph::graph::GraphReadError::KeyedInvalidKey(rev.0))
            }
        }
    }
}

pub fn py_tuple_to_revision_data_params(
    tuple: &Bound<'_, PyTuple>,
) -> PyResult<RevisionDataParams> {
    // no need to check length: in PyO3 tup.get_item() does return
    // proper errors
    let offset_or_flags: u64 = tuple.get_item(0)?.extract()?;
    let node_id = tuple
        .get_item(7)?
        .downcast::<PyBytes>()?
        .as_bytes()
        .try_into()
        .expect("nodeid should be set");
    let flags = (offset_or_flags & 0xFFFF) as u16;
    let data_offset = offset_or_flags >> 16;
    Ok(RevisionDataParams {
        flags,
        data_offset,
        data_compressed_length: tuple.get_item(1)?.extract()?,
        data_uncompressed_length: tuple.get_item(2)?.extract()?,
        data_delta_base: tuple.get_item(3)?.extract()?,
        link_rev: tuple.get_item(4)?.extract()?,
        parent_rev_1: tuple.get_item(5)?.extract()?,
        parent_rev_2: tuple.get_item(6)?.extract()?,
        node_id,
        ..Default::default()
    })
}

pub fn revision_data_params_to_py_tuple(
    py: Python<'_>,
    params: RevisionDataParams,
) -> PyResult<Bound<'_, PyTuple>> {
    PyTuple::new(
        py,
        &[
            params.data_offset.into_pyobject(py)?.into_any(),
            params.data_compressed_length.into_pyobject(py)?.into_any(),
            params
                .data_uncompressed_length
                .into_pyobject(py)?
                .into_any(),
            params.data_delta_base.into_pyobject(py)?.into_any(),
            params.link_rev.into_pyobject(py)?.into_any(),
            params.parent_rev_1.into_pyobject(py)?.into_any(),
            params.parent_rev_2.into_pyobject(py)?.into_any(),
            PyBytes::new(py, &params.node_id).into_any().into_any(),
            params._sidedata_offset.into_pyobject(py)?.into_any(),
            params
                ._sidedata_compressed_length
                .into_pyobject(py)?
                .into_any(),
            params.data_compression_mode.into_pyobject(py)?.into_any(),
            params
                ._sidedata_compression_mode
                .into_pyobject(py)?
                .into_any(),
            params._rank.into_pyobject(py)?.into_any(),
        ],
    )
}
