// dirstate_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for the `hg::dirstate::dirstate_map` file provided by the
//! `hg-core` package.

use pyo3::exceptions::PyKeyError;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyBytesMethods, PyTuple};
use pyo3_sharedref::{py_shared_iterator, PyShareable};

use std::sync::RwLockReadGuard;

use hg::{
    dirstate::{
        dirstate_map::{
            DirstateIdentity as CoreDirstateIdentity, DirstateMapWriteMode,
        },
        entry::DirstateEntry,
        on_disk::DirstateV2ParseError,
        owning::OwningDirstateMap,
        StateMapIter,
    },
    utils::hg_path::HgPath,
    DirstateParents,
};

use super::item::DirstateItem;
use crate::{
    exceptions::{dirstate_error, dirstate_v2_error, map_try_lock_error},
    node::{node_from_py_bytes, PyNode},
    path::PyHgPathRef,
    utils::PyBytesDeref,
};

#[pyclass(mapping)]
pub struct DirstateMap {
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

    #[pyo3(signature = (key, default=None))]
    fn get(
        slf: &Bound<'_, Self>,
        key: &Bound<'_, PyBytes>,
        default: Option<PyObject>,
    ) -> PyResult<Option<PyObject>> {
        let path = HgPath::new(key.as_bytes());

        Self::with_inner_read(slf, |_self_ref, inner| {
            match inner.get(path).map_err(dirstate_v2_error)? {
                Some(entry) => Ok(Some(
                    DirstateItem::new_as_py(slf.py(), entry)?.into_any(),
                )),
                None => Ok(default),
            }
        })
    }

    /// Returns suitable data for writing on disk in v1 format
    ///
    /// Despite the name, this is not a mutation of the object.
    fn write_v1(
        slf: &Bound<'_, Self>,
        py: Python,
        p1: &Bound<'_, PyBytes>,
        p2: &Bound<'_, PyBytes>,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            let parents = DirstateParents {
                p1: node_from_py_bytes(p1)?,
                p2: node_from_py_bytes(p2)?,
            };
            let packed = inner.pack_v1(parents).map_err(dirstate_error)?;
            // TODO optim, see `write_v2()`
            Ok(PyBytes::new(py, &packed).unbind())
        })
    }

    /// Returns suitable new data for writing on disk in v2 format
    ///
    /// Despite the name, this is not a mutation of the object.
    ///
    /// The new data together with whether that data should be appended to
    /// the existing data file whose content is at `self.on_disk` (True),
    /// instead of written to a new data file (False).
    fn write_v2(
        slf: &Bound<'_, Self>,
        py: Python,
        write_mode: usize,
    ) -> PyResult<Py<PyTuple>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            let rust_write_mode = match write_mode {
                0 => DirstateMapWriteMode::Auto,
                1 => DirstateMapWriteMode::ForceNewDataFile,
                2 => DirstateMapWriteMode::ForceAppend,
                _ => DirstateMapWriteMode::Auto, // XXX should we error out?
            };
            let (packed, tree_metadata, append, _old_data_size) =
                inner.pack_v2(rust_write_mode).map_err(dirstate_error)?;
            // TODO optim. In theory we should be able to avoid these copies,
            // since we have full ownership of `packed` and `tree_metadata`.
            // But the copy is done by CPython itself, in
            // `PyBytes_FromStringAndSize()`. Perhaps something better can
            // be done with `PyBytes_FromObject` (buffer protocol).
            let packed = PyBytes::new(py, &packed).unbind();
            let tree_metadata =
                PyBytes::new(py, tree_metadata.as_bytes()).unbind();
            Ok((packed, tree_metadata, append).into_pyobject(py)?.into())
        })
    }

    fn __len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_inner_read(slf, |_self_ref, inner| Ok(inner.len()))
    }

    fn __contains__(
        slf: &Bound<'_, Self>,
        key: &Bound<'_, PyBytes>,
    ) -> PyResult<bool> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            inner
                .contains_key(HgPath::new(key.as_bytes()))
                .map_err(dirstate_v2_error)
        })
    }

    fn __getitem__(
        slf: &Bound<'_, Self>,
        key: &Bound<'_, PyBytes>,
    ) -> PyResult<Py<DirstateItem>> {
        let key_bytes = key.as_bytes();
        let path = HgPath::new(key_bytes);
        Self::with_inner_read(slf, |_self_ref, inner| {
            match inner.get(path).map_err(dirstate_v2_error)? {
                Some(entry) => DirstateItem::new_as_py(slf.py(), entry),
                None => Err(PyKeyError::new_err(
                    String::from_utf8_lossy(key_bytes).to_string(),
                )),
            }
        })
    }

    fn keys(slf: &Bound<'_, Self>) -> PyResult<DirstateMapKeysIterator> {
        DirstateMapKeysIterator::new(slf)
    }

    fn items(slf: &Bound<'_, Self>) -> PyResult<DirstateMapItemsIterator> {
        DirstateMapItemsIterator::new(slf)
    }

    fn __iter__(slf: &Bound<'_, Self>) -> PyResult<DirstateMapKeysIterator> {
        Self::keys(slf)
    }

    fn debug_iter(
        slf: &Bound<'_, Self>,
        py: Python,
        all: bool,
    ) -> PyResult<PyObject> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            // the iterator returned by `debug_iter()` does not
            // implement ExactSizeIterator, which is needed by
            // `PyList::new()`, so we need to collect. Probably not a
            // performance issue, as this is a debug method.
            let as_vec: PyResult<Vec<_>> = inner
                .debug_iter(all)
                .map(|item| {
                    let (path, (state, mode, size, mtime)) =
                        item.map_err(dirstate_v2_error)?;
                    Ok((PyHgPathRef(path), state, mode, size, mtime))
                })
                .collect();
            // `IntoPyObject` on `Vec` and `&[T]` gives  `PyList` or `PyBytes`
            Ok(as_vec?.into_pyobject(py)?.unbind())
        })
    }
}

py_shared_iterator!(
    DirstateMapKeysIterator,
    PyBytes,
    DirstateMap,
    inner,
    StateMapIter<'static>,
    |dsm| dsm.iter(),
    DirstateMap::keys_next_result
);

py_shared_iterator!(
    DirstateMapItemsIterator,
    PyTuple,
    DirstateMap,
    inner,
    StateMapIter<'static>,
    |dsm| dsm.iter(),
    DirstateMap::items_next_result
);

impl DirstateMap {
    fn keys_next_result(
        py: Python,
        res: Result<(&HgPath, DirstateEntry), DirstateV2ParseError>,
    ) -> PyResult<Option<Py<PyBytes>>> {
        let key = res.map_err(dirstate_v2_error)?.0;
        Ok(Some(PyHgPathRef(key).into_pyobject(py)?.unbind()))
    }

    fn items_next_result(
        py: Python,
        res: Result<(&HgPath, DirstateEntry), DirstateV2ParseError>,
    ) -> PyResult<Option<Py<PyTuple>>> {
        let (key, entry) = res.map_err(dirstate_v2_error)?;
        let py_entry = DirstateItem::new_as_py(py, entry)?;
        Ok(Some((PyHgPathRef(key), py_entry).into_pyobject(py)?.into()))
    }

    pub fn with_inner_read<'py, T>(
        slf: &Bound<'py, Self>,
        f: impl FnOnce(
            &PyRef<'py, Self>,
            RwLockReadGuard<OwningDirstateMap>,
        ) -> PyResult<T>,
    ) -> PyResult<T> {
        let self_ref = slf.borrow();
        // Safety: the owner is the right one. We will anyway
        // not actually `share` it.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_read().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
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
