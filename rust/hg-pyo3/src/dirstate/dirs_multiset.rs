// copy_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for `hg::dirstate::dirs_multiset` file provided by the
//! `hg-core` package.
use pyo3::exceptions::PyTypeError;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyDict};
use pyo3_sharedref::{py_shared_iterator, PyShareable};

use std::sync::{RwLockReadGuard, RwLockWriteGuard};

use hg::{
    dirstate::dirs_multiset::{DirsMultiset, DirsMultisetIter},
    utils::hg_path::{HgPath, HgPathBuf},
};

use crate::exceptions::{map_try_lock_error, to_string_value_error};
use crate::path::PyHgPathRef;

#[pyclass(mapping)]
pub struct Dirs {
    pub(super) inner: PyShareable<DirsMultiset>,
}

#[pymethods]
impl Dirs {
    #[new]
    fn new(map: &Bound<'_, PyAny>) -> PyResult<Self> {
        if map.downcast::<PyDict>().is_ok() {
            return Err(PyTypeError::new_err(
                "pathutil.dirs() with a dict should only be used by the \
                 Python dirstatemap and should not be used \
                 when Rust is enabled",
            ));
        }
        let map: Result<Vec<_>, PyErr> = map
            .try_iter()?
            .map(|o| Ok(HgPathBuf::from_bytes(o?.extract()?)))
            .collect();
        Ok(Self {
            inner: DirsMultiset::from_manifest(&map?)
                .map_err(to_string_value_error)?
                .into(),
        })
    }

    fn addpath(
        slf: &Bound<'_, Self>,
        path: &Bound<'_, PyBytes>,
    ) -> PyResult<()> {
        let path = HgPath::new(path.as_bytes());
        Self::with_inner_write(slf, |mut inner| {
            inner.add_path(path).map_err(to_string_value_error)
        })
    }

    fn delpath(
        slf: &Bound<'_, Self>,
        path: &Bound<'_, PyBytes>,
    ) -> PyResult<()> {
        let path = HgPath::new(path.as_bytes());
        Self::with_inner_write(slf, |mut inner| {
            inner.delete_path(path).map_err(to_string_value_error)
        })
    }

    fn __iter__(slf: &Bound<'_, Self>) -> PyResult<DirsMultisetKeysIterator> {
        DirsMultisetKeysIterator::new(slf)
    }

    fn __contains__(
        slf: &Bound<'_, Self>,
        key: &Bound<'_, PyAny>,
    ) -> PyResult<bool> {
        let path = if let Ok(k) = key.extract::<&[u8]>() {
            HgPath::new(k)
        } else {
            return Ok(false);
        };

        Self::with_inner_read(slf, |inner| Ok(inner.contains(path)))
    }
}

py_shared_iterator!(
    DirsMultisetKeysIterator,
    PyBytes,
    Dirs,
    inner,
    DirsMultisetIter<'static>,
    |ms| ms.iter(),
    Dirs::keys_next_result
);

impl Dirs {
    fn keys_next_result(
        py: Python,
        res: &HgPathBuf,
    ) -> PyResult<Option<Py<PyBytes>>> {
        Ok(Some(PyHgPathRef(res).into_pyobject(py)?.unbind()))
    }

    pub(super) fn with_inner_read<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(RwLockReadGuard<DirsMultiset>) -> PyResult<T>,
    ) -> PyResult<T> {
        let self_ref = slf.borrow();
        // Safety: the owner is the right one. We will anyway
        // not actually `share` it.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_read().map_err(map_try_lock_error)?;
        f(guard)
    }

    pub(super) fn with_inner_write<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(RwLockWriteGuard<DirsMultiset>) -> PyResult<T>,
    ) -> PyResult<T> {
        let self_ref = slf.borrow();
        // Safety: the owner is the right one. We will anyway
        // not actually `share` it.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_write().map_err(map_try_lock_error)?;
        f(guard)
    }
}
