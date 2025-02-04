// copy_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for `hg::dirstate::dirstate_map::CopyMap` provided by the
//! `hg-core` package.

use pyo3::exceptions::PyKeyError;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyDict, PyTuple};
use pyo3_sharedref::py_shared_iterator;

use std::sync::{RwLockReadGuard, RwLockWriteGuard};

use hg::{
    dirstate::{
        on_disk::DirstateV2ParseError, owning::OwningDirstateMap, CopyMapIter,
    },
    utils::hg_path::HgPath,
};

use super::dirstate_map::DirstateMap;
use crate::{
    exceptions::dirstate_v2_error,
    path::{PyHgPathBuf, PyHgPathRef},
};

#[pyclass(mapping)]
pub struct CopyMap {
    dirstate_map: Py<DirstateMap>,
}

#[pymethods]
impl CopyMap {
    #[new]
    pub fn new(dsm: &Bound<'_, DirstateMap>) -> PyResult<Self> {
        Ok(Self {
            dirstate_map: dsm.clone().unbind(),
        })
    }

    fn __getitem__(
        &self,
        py: Python,
        key: &Bound<'_, PyBytes>,
    ) -> PyResult<Py<PyBytes>> {
        let key = key.as_bytes();
        self.with_dirstate_map_read(py, |inner_dsm| {
            inner_dsm
                .copy_map_get(HgPath::new(key))
                .map_err(dirstate_v2_error)?
                .ok_or_else(|| {
                    PyKeyError::new_err(
                        String::from_utf8_lossy(key).to_string(),
                    )
                })
                .and_then(|copy| {
                    Ok(PyHgPathRef(copy).into_pyobject(py)?.unbind())
                })
        })
    }

    fn __len__(&self, py: Python) -> PyResult<usize> {
        self.with_dirstate_map_read(py, |inner_dsm| {
            Ok(inner_dsm.copy_map_len())
        })
    }

    fn __contains__(
        &self,
        py: Python,
        key: &Bound<'_, PyBytes>,
    ) -> PyResult<bool> {
        let key = key.as_bytes();
        self.with_dirstate_map_read(py, |inner_dsm| {
            inner_dsm
                .copy_map_contains_key(HgPath::new(key))
                .map_err(dirstate_v2_error)
        })
    }

    #[pyo3(signature = (key, default=None))]
    fn get(
        &self,
        py: Python,
        key: &Bound<'_, PyBytes>,
        default: Option<PyObject>,
    ) -> PyResult<Option<PyObject>> {
        let key = key.as_bytes();
        self.with_dirstate_map_read(py, |inner_dsm| {
            match inner_dsm
                .copy_map_get(HgPath::new(key))
                .map_err(dirstate_v2_error)?
            {
                Some(copy) => Ok(Some(
                    PyHgPathRef(copy).into_pyobject(py)?.unbind().into(),
                )),
                None => Ok(default),
            }
        })
    }

    #[pyo3(signature = (key, default=None))]
    fn pop(
        &self,
        py: Python,
        key: &Bound<'_, PyBytes>,
        default: Option<PyObject>,
    ) -> PyResult<Option<PyObject>> {
        let path = HgPath::new(key.as_bytes());
        self.with_dirstate_map_write(py, |mut inner_dsm| {
            match inner_dsm.copy_map_remove(path).map_err(dirstate_v2_error)? {
                Some(copy) => Ok(Some(
                    PyHgPathBuf(copy).into_pyobject(py)?.unbind().into(),
                )),
                None => Ok(default),
            }
        })
    }

    fn __iter__(&self, py: Python) -> PyResult<CopyMapKeysIterator> {
        self.keys(py)
    }

    fn keys(&self, py: Python) -> PyResult<CopyMapKeysIterator> {
        CopyMapKeysIterator::new(self.dirstate_map.bind(py))
    }

    fn items(&self, py: Python) -> PyResult<CopyMapItemsIterator> {
        CopyMapItemsIterator::new(self.dirstate_map.bind(py))
    }

    fn __setitem__(
        &self,
        py: Python,
        key: &Bound<'_, PyBytes>,
        value: &Bound<'_, PyBytes>,
    ) -> PyResult<()> {
        let key = HgPath::new(key.as_bytes());
        let value = HgPath::new(value.as_bytes());
        self.with_dirstate_map_write(py, |mut inner_dsm| {
            inner_dsm
                .copy_map_insert(key, value)
                .map_err(dirstate_v2_error)
        })?;
        Ok(())
    }

    fn copy(&self, py: Python) -> PyResult<Py<PyDict>> {
        let dict = PyDict::new(py);
        // The `IntoPyDict` trait just does the same, but is not applicable
        // here because it is meant to work on infallible iterators
        self.with_dirstate_map_read(py, |inner_dsm| {
            for item in inner_dsm.copy_map_iter() {
                let (key, value) = item.map_err(dirstate_v2_error)?;
                dict.set_item(PyHgPathRef(key), PyHgPathRef(value))?;
            }
            Ok(())
        })?;
        Ok(dict.unbind())
    }
}

py_shared_iterator!(
    CopyMapKeysIterator,
    PyBytes,
    DirstateMap,
    inner,
    CopyMapIter<'static>,
    |dsm| dsm.copy_map_iter(),
    CopyMap::keys_next_result
);

py_shared_iterator!(
    CopyMapItemsIterator,
    PyTuple,
    DirstateMap,
    inner,
    CopyMapIter<'static>,
    |dsm| dsm.copy_map_iter(),
    CopyMap::items_next_result
);

impl CopyMap {
    fn keys_next_result(
        py: Python,
        res: Result<(&HgPath, &HgPath), DirstateV2ParseError>,
    ) -> PyResult<Option<Py<PyBytes>>> {
        let key = res.map_err(dirstate_v2_error)?.0;
        Ok(Some(PyHgPathRef(key).into_pyobject(py)?.unbind()))
    }

    fn items_next_result(
        py: Python,
        res: Result<(&HgPath, &HgPath), DirstateV2ParseError>,
    ) -> PyResult<Option<Py<PyTuple>>> {
        let (key, value) = res.map_err(dirstate_v2_error)?;
        Ok(Some(
            (PyHgPathRef(key), PyHgPathRef(value))
                .into_pyobject(py)?
                .unbind(),
        ))
    }

    fn with_dirstate_map_read<T>(
        &self,
        py: Python,
        f: impl FnOnce(RwLockReadGuard<OwningDirstateMap>) -> PyResult<T>,
    ) -> PyResult<T> {
        let dsm = self.dirstate_map.bind(py);
        DirstateMap::with_inner_read(dsm, |_dsm, inner| f(inner))
    }

    fn with_dirstate_map_write<T>(
        &self,
        py: Python,
        f: impl FnOnce(RwLockWriteGuard<OwningDirstateMap>) -> PyResult<T>,
    ) -> PyResult<T> {
        let dsm = self.dirstate_map.bind(py);
        DirstateMap::with_inner_write(dsm, |_dsm, inner| f(inner))
    }
}
