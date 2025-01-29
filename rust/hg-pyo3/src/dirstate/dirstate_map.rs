// dirstate_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for the `hg::dirstate::dirstate_map` file provided by the
//! `hg-core` package.

use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyBytesMethods, PyTuple};
use pyo3_sharedref::PyShareable;

use hg::dirstate::{
    dirstate_map::DirstateIdentity as CoreDirstateIdentity,
    owning::OwningDirstateMap,
};

use crate::{exceptions::dirstate_error, node::PyNode, utils::PyBytesDeref};

#[pyclass]
pub struct DirstateMap {
    #[allow(dead_code)]
    inner: PyShareable<OwningDirstateMap>,
}

#[pymethods]
impl DirstateMap {
    #[staticmethod]
    #[pyo3(signature = (on_disk, identity))]
    /// Returns a `(dirstate_map, parents)` tuple
    ///
    /// The Python call site is using the positional argument style, hence
    /// despite the fact that `identity` can be `None`, we specify the
    /// matching signature.
    fn new_v1(
        py: Python,
        on_disk: Py<PyBytes>,
        identity: Option<&Bound<'_, DirstateIdentity>>,
    ) -> PyResult<Py<PyTuple>> {
        let on_disk = PyBytesDeref::new(py, on_disk);
        let (map, parents) = OwningDirstateMap::new_v1(
            on_disk,
            identity.map(|i| i.borrow().inner),
        )
        .map_err(dirstate_error)?;
        let map = Self { inner: map.into() };
        let parents = (PyNode(parents.p1), PyNode(parents.p2));
        Ok((map, parents).into_pyobject(py)?.into())
    }

    #[staticmethod]
    #[pyo3(signature = (on_disk, data_size, tree_metadata, uuid, identity))]
    fn new_v2(
        py: Python,
        on_disk: Py<PyBytes>,
        data_size: usize,
        tree_metadata: &Bound<'_, PyBytes>,
        uuid: &Bound<'_, PyBytes>,
        identity: Option<&Bound<'_, DirstateIdentity>>,
    ) -> PyResult<Self> {
        Ok(Self {
            inner: OwningDirstateMap::new_v2(
                PyBytesDeref::new(py, on_disk),
                data_size,
                tree_metadata.as_bytes(),
                uuid.as_bytes().to_owned(),
                identity.map(|i| i.borrow().inner),
            )
            .map_err(dirstate_error)?
            .into(),
        })
    }

    #[staticmethod]
    fn new_empty() -> PyResult<Self> {
        Ok(Self {
            inner: OwningDirstateMap::new_empty(vec![], None).into(),
        })
    }
}

#[pyclass]
pub struct DirstateIdentity {
    #[allow(dead_code)]
    inner: CoreDirstateIdentity,
}

#[pymethods]
impl DirstateIdentity {
    #[new]
    #[allow(clippy::too_many_arguments)]
    fn new(
        mode: u32,
        dev: u64,
        ino: u64,
        nlink: u64,
        uid: u32,
        gid: u32,
        size: u64,
        mtime: i64,
        mtime_nsec: i64,
        ctime: i64,
        ctime_nsec: i64,
    ) -> PyResult<Self> {
        Ok(Self {
            inner: CoreDirstateIdentity {
                mode,
                dev,
                ino,
                nlink,
                uid,
                gid,
                size,
                mtime,
                mtime_nsec,
                ctime,
                ctime_nsec,
            },
        })
    }
}
