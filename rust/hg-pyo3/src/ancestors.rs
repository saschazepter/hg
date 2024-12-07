// ancestors.rs
//
// Copyright 2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::ancestors` module provided by the
//! `hg-core` crate. From Python, this will be seen as `pyo3_rustext.ancestor`
//! and can be used as replacement for the the pure `ancestor` Python module.
use cpython::UnsafePyLeaked;
use pyo3::prelude::*;

use std::sync::RwLock;

use vcsgraph::lazy_ancestors::AncestorsIterator as VCGAncestorsIterator;

use crate::convert_cpython::{
    proxy_index_extract, proxy_index_py_leak, py_leaked_borrow_mut,
    py_leaked_or_map_err,
};
use crate::exceptions::{map_lock_error, GraphError};
use crate::revision::{rev_pyiter_collect, PyRevision};
use crate::util::new_submodule;
use rusthg::revlog::PySharedIndex;

#[pyclass]
struct AncestorsIterator {
    inner: RwLock<UnsafePyLeaked<VCGAncestorsIterator<PySharedIndex>>>,
}

#[pymethods]
impl AncestorsIterator {
    #[new]
    fn new(
        index_proxy: &Bound<'_, PyAny>,
        initrevs: &Bound<'_, PyAny>,
        stoprev: PyRevision,
        inclusive: bool,
    ) -> PyResult<Self> {
        // Safety: we don't leak the "faked" reference out of
        // `UnsafePyLeaked`
        let initvec: Vec<_> = {
            let borrowed_idx = unsafe { proxy_index_extract(index_proxy)? };
            rev_pyiter_collect(initrevs, borrowed_idx)?
        };
        let (py, leaked_idx) = proxy_index_py_leak(index_proxy)?;
        let res_ait = unsafe {
            leaked_idx.map(py, |idx| {
                VCGAncestorsIterator::new(
                    idx,
                    initvec.into_iter().map(|r| r.0),
                    stoprev.0,
                    inclusive,
                )
            })
        };
        let ait =
            py_leaked_or_map_err(py, res_ait, GraphError::from_vcsgraph)?;
        let inner = ait.into();
        Ok(Self { inner })
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
        slf
    }

    fn __next__(slf: PyRefMut<'_, Self>) -> PyResult<Option<PyRevision>> {
        let mut leaked = slf.inner.write().map_err(map_lock_error)?;
        // Safety: we don't leak the inner 'static ref out of UnsafePyLeaked
        let mut inner = unsafe { py_leaked_borrow_mut(&slf, &mut leaked)? };
        match inner.next() {
            Some(Err(e)) => Err(GraphError::from_vcsgraph(e)),
            None => Ok(None),
            Some(Ok(r)) => Ok(Some(PyRevision(r))),
        }
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "ancestor")?;
    m.add_class::<AncestorsIterator>()?;
    Ok(m)
}
