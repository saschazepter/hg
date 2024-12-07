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
use pyo3::types::PyTuple;

use std::collections::HashSet;
use std::sync::RwLock;

use hg::MissingAncestors as CoreMissing;
use vcsgraph::lazy_ancestors::{
    AncestorsIterator as VCGAncestorsIterator,
    LazyAncestors as VCGLazyAncestors,
};

use crate::convert_cpython::{
    proxy_index_py_leak, py_leaked_borrow, py_leaked_borrow_mut,
    py_leaked_or_map_err,
};
use crate::exceptions::{map_lock_error, GraphError};
use crate::revision::{rev_pyiter_collect_with_py_index, PyRevision};
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
        let initvec: Vec<_> =
            rev_pyiter_collect_with_py_index(initrevs, index_proxy)?;
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

#[pyclass(sequence)]
struct LazyAncestors {
    inner: RwLock<UnsafePyLeaked<VCGLazyAncestors<PySharedIndex>>>,
    proxy_index: PyObject,
    initrevs: PyObject,
    stoprev: PyRevision,
    inclusive: bool,
}

#[pymethods]
impl LazyAncestors {
    #[new]
    fn new(
        index_proxy: &Bound<'_, PyAny>,
        initrevs: &Bound<'_, PyAny>,
        stoprev: PyRevision,
        inclusive: bool,
    ) -> PyResult<Self> {
        let cloned_proxy = index_proxy.clone().unbind();
        let initvec: Vec<_> =
            rev_pyiter_collect_with_py_index(initrevs, index_proxy)?;
        let (py, leaked_idx) = proxy_index_py_leak(index_proxy)?;
        // Safety: we don't leak the "faked" reference out of
        // `UnsafePyLeaked`
        let res_lazy = unsafe {
            leaked_idx.map(py, |idx| {
                VCGLazyAncestors::new(
                    idx,
                    initvec.into_iter().map(|r| r.0),
                    stoprev.0,
                    inclusive,
                )
            })
        };
        let lazy =
            py_leaked_or_map_err(py, res_lazy, GraphError::from_vcsgraph)?;
        Ok(Self {
            inner: lazy.into(),
            proxy_index: cloned_proxy,
            initrevs: initrevs.clone().unbind(),
            stoprev,
            inclusive,
        })
    }

    fn __bool__(slf: PyRef<'_, Self>) -> PyResult<bool> {
        let leaked = slf.inner.read().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { py_leaked_borrow(&slf, &leaked) }?;
        Ok(!inner.is_empty())
    }

    fn __contains__(
        slf: PyRefMut<'_, Self>,
        obj: &Bound<'_, PyAny>,
    ) -> PyResult<bool> {
        PyRevision::extract_bound(obj).map_or(Ok(false), |rev| {
            let mut leaked = slf.inner.write().map_err(map_lock_error)?;
            // Safety: we don't leak the "faked" reference out of
            // `UnsafePyLeaked`
            let mut inner =
                unsafe { py_leaked_borrow_mut(&slf, &mut leaked) }?;
            inner.contains(rev.0).map_err(GraphError::from_vcsgraph)
        })
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyResult<AncestorsIterator> {
        let py = slf.py();
        AncestorsIterator::new(
            slf.proxy_index.clone_ref(py).bind(py),
            slf.initrevs.clone_ref(py).bind(py),
            slf.stoprev,
            slf.inclusive,
        )
    }
}

#[pyclass]
struct MissingAncestors {
    inner: RwLock<UnsafePyLeaked<CoreMissing<PySharedIndex>>>,
    proxy_index: PyObject,
}

#[pymethods]
impl MissingAncestors {
    #[new]
    fn new(
        index_proxy: &Bound<'_, PyAny>,
        bases: &Bound<'_, PyAny>,
    ) -> PyResult<Self> {
        let cloned_proxy = index_proxy.clone().unbind();
        let bases_vec: Vec<_> =
            rev_pyiter_collect_with_py_index(bases, index_proxy)?;
        let (py, leaked_idx) = proxy_index_py_leak(index_proxy)?;

        // Safety: we don't leak the "faked" reference out of
        // `UnsafePyLeaked`
        let inner = unsafe {
            leaked_idx.map(py, |idx| CoreMissing::new(idx, bases_vec))
        };
        Ok(Self {
            inner: inner.into(),
            proxy_index: cloned_proxy,
        })
    }

    fn hasbases(slf: PyRef<'_, Self>) -> PyResult<bool> {
        let leaked = slf.inner.read().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { py_leaked_borrow(&slf, &leaked) }?;
        Ok(inner.has_bases())
    }

    fn addbases(
        slf: PyRefMut<'_, Self>,
        bases: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let index_proxy = slf.proxy_index.bind(slf.py());
        let bases_vec: Vec<_> =
            rev_pyiter_collect_with_py_index(bases, index_proxy)?;

        let mut leaked = slf.inner.write().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { py_leaked_borrow_mut(&slf, &mut leaked) }?;
        inner.add_bases(bases_vec);
        Ok(())
    }

    fn bases(slf: PyRef<'_, Self>) -> PyResult<HashSet<PyRevision>> {
        let leaked = slf.inner.read().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { py_leaked_borrow(&slf, &leaked) }?;
        Ok(inner.get_bases().iter().map(|r| PyRevision(r.0)).collect())
    }

    fn basesheads(slf: PyRef<'_, Self>) -> PyResult<HashSet<PyRevision>> {
        let leaked = slf.inner.read().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { py_leaked_borrow(&slf, &leaked) }?;
        Ok(inner
            .bases_heads()
            .map_err(GraphError::from_hg)?
            .iter()
            .map(|r| PyRevision(r.0))
            .collect())
    }

    fn removeancestorsfrom(
        slf: PyRef<'_, Self>,
        revs: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        // Original comment from hg-cpython:
        //   this is very lame: we convert to a Rust set, update it in place
        //   and then convert back to Python, only to have Python remove the
        //   excess (thankfully, Python is happy with a list or even an
        //   iterator)
        //   Leads to improve this:
        //    - have the CoreMissing instead do something emit revisions to
        //      discard
        //    - define a trait for sets of revisions in the core and implement
        //      it for a Python set rewrapped with the GIL marker
        // PyO3 additional comment: the trait approach would probably be
        // simpler because we can implement it without a Py wrappper, just
        // on &Bound<'py, PySet>
        let index_proxy = slf.proxy_index.bind(slf.py());
        let mut revs_set: HashSet<_> =
            rev_pyiter_collect_with_py_index(revs, index_proxy)?;

        let mut leaked = slf.inner.write().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { py_leaked_borrow_mut(&slf, &mut leaked) }?;

        inner
            .remove_ancestors_from(&mut revs_set)
            .map_err(GraphError::from_hg)?;
        // convert as Python tuple and discard from original `revs`
        let remaining_tuple =
            PyTuple::new(slf.py(), revs_set.iter().map(|r| PyRevision(r.0)))?;
        revs.call_method("intersection_update", (remaining_tuple,), None)?;
        Ok(())
    }

    fn missingancestors(
        slf: PyRefMut<'_, Self>,
        bases: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<PyRevision>> {
        let index_proxy = slf.proxy_index.bind(slf.py());
        let revs_vec: Vec<_> =
            rev_pyiter_collect_with_py_index(bases, index_proxy)?;

        let mut leaked = slf.inner.write().map_err(map_lock_error)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { py_leaked_borrow_mut(&slf, &mut leaked) }?;

        let missing_vec = inner
            .missing_ancestors(revs_vec)
            .map_err(GraphError::from_hg)?;
        Ok(missing_vec.iter().map(|r| PyRevision(r.0)).collect())
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "ancestor")?;
    m.add_class::<AncestorsIterator>()?;
    m.add_class::<LazyAncestors>()?;
    m.add_class::<MissingAncestors>()?;
    Ok(m)
}
