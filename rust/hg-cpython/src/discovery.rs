// discovery.rs
//
// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::discovery` module provided by the
//! `hg-core` crate. From Python, this will be seen as `rustext.discovery`
//!
//! # Classes visible from Python:
//! - [`PartialDiscovery`] is the Rust implementation of
//!   `mercurial.setdiscovery.partialdiscovery`.

use crate::PyRevision;
use crate::{
    conversion::rev_pyiter_collect, exceptions::GraphError,
    revlog::PySharedIndex,
};
use cpython::{
    ObjectProtocol, PyClone, PyDict, PyModule, PyObject, PyResult, PyTuple,
    Python, PythonObject, ToPyObject, UnsafePyLeaked,
};
use hg::discovery::PartialDiscovery as CorePartialDiscovery;
use hg::Revision;
use std::collections::HashSet;

use std::cell::RefCell;

use crate::revlog::py_rust_index_to_graph;

py_class!(pub class PartialDiscovery |py| {
    data inner: RefCell<UnsafePyLeaked<CorePartialDiscovery<PySharedIndex>>>;
    data index: RefCell<UnsafePyLeaked<PySharedIndex>>;

    // `_respectsize` is currently only here to replicate the Python API and
    // will be used in future patches inside methods that are yet to be
    // implemented.
    def __new__(
        _cls,
        repo: PyObject,
        targetheads: PyObject,
        respectsize: bool,
        randomize: bool = true
    ) -> PyResult<PartialDiscovery> {
        Self::inner_new(py, repo, targetheads, respectsize, randomize)
    }

    def addcommons(&self, commons: PyObject) -> PyResult<PyObject> {
        self.inner_addcommons(py, commons)
    }

    def addmissings(&self, missings: PyObject) -> PyResult<PyObject> {
        self.inner_addmissings(py, missings)
    }

    def addinfo(&self, sample: PyObject) -> PyResult<PyObject> {
        self.inner_addinfo(py, sample)
    }

    def hasinfo(&self) -> PyResult<bool> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { leaked.try_borrow(py)? };
        Ok(inner.has_info())
    }

    def iscomplete(&self) -> PyResult<bool> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { leaked.try_borrow(py)? };
        Ok(inner.is_complete())
    }

    def stats(&self) -> PyResult<PyDict> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { leaked.try_borrow(py)? };
        let stats = inner.stats();
        let as_dict: PyDict = PyDict::new(py);
        as_dict.set_item(py, "undecided",
                         stats.undecided.map(
                             |l| l.to_py_object(py).into_object())
                             .unwrap_or_else(|| py.None()))?;
        Ok(as_dict)
    }

    def commonheads(&self) -> PyResult<HashSet<PyRevision>> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { leaked.try_borrow(py)? };
        let res = inner.common_heads()
                    .map_err(|e| GraphError::pynew(py, e))?;
        Ok(res.into_iter().map(Into::into).collect())
    }

    def takefullsample(&self, headrevs: PyObject,
                       size: usize) -> PyResult<PyObject> {
        self.inner_takefullsample(py, headrevs, size)
    }

    def takequicksample(&self, headrevs: PyObject,
                        size: usize) -> PyResult<PyObject> {
        self.inner_takequicksample(py, headrevs, size)
    }

});

impl PartialDiscovery {
    fn inner_new(
        py: Python,
        repo: PyObject,
        targetheads: PyObject,
        respectsize: bool,
        randomize: bool,
    ) -> PyResult<Self> {
        let index = repo.getattr(py, "changelog")?.getattr(py, "index")?;
        let cloned_index = py_rust_index_to_graph(py, index.clone_ref(py))?;
        let index = py_rust_index_to_graph(py, index)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let target_heads = {
            let borrowed_idx = unsafe { index.try_borrow(py)? };
            rev_pyiter_collect(py, &targetheads, &*borrowed_idx)?
        };
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let lazy_disco = unsafe {
            index.map(py, |idx| {
                CorePartialDiscovery::new(
                    idx,
                    target_heads,
                    respectsize,
                    randomize,
                )
            })
        };
        Self::create_instance(
            py,
            RefCell::new(lazy_disco),
            RefCell::new(cloned_index),
        )
    }

    /// Convert a Python iterator of revisions into a vector
    fn pyiter_to_vec(
        &self,
        py: Python,
        iter: &PyObject,
    ) -> PyResult<Vec<Revision>> {
        let leaked = self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let index = unsafe { leaked.try_borrow(py)? };
        rev_pyiter_collect(py, iter, &*index)
    }

    fn inner_addinfo(
        &self,
        py: Python,
        sample: PyObject,
    ) -> PyResult<PyObject> {
        let mut missing: Vec<Revision> = Vec::new();
        let mut common: Vec<Revision> = Vec::new();
        for info in sample.iter(py)? {
            // info is a pair (Revision, bool)
            let mut revknown = info?.iter(py)?;
            let rev: PyRevision = revknown.next().unwrap()?.extract(py)?;
            // This is fine since we're just using revisions as integers
            // for the purposes of discovery
            let rev = Revision(rev.0);
            let known: bool = revknown.next().unwrap()?.extract(py)?;
            if known {
                common.push(rev);
            } else {
                missing.push(rev);
            }
        }
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        inner
            .add_common_revisions(common)
            .map_err(|e| GraphError::pynew(py, e))?;
        inner
            .add_missing_revisions(missing)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    fn inner_addcommons(
        &self,
        py: Python,
        commons: PyObject,
    ) -> PyResult<PyObject> {
        let commons_vec = self.pyiter_to_vec(py, &commons)?;
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        inner
            .add_common_revisions(commons_vec)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    fn inner_addmissings(
        &self,
        py: Python,
        missings: PyObject,
    ) -> PyResult<PyObject> {
        let missings_vec = self.pyiter_to_vec(py, &missings)?;
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        inner
            .add_missing_revisions(missings_vec)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    fn inner_takefullsample(
        &self,
        py: Python,
        _headrevs: PyObject,
        size: usize,
    ) -> PyResult<PyObject> {
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        let sample = inner
            .take_full_sample(size)
            .map_err(|e| GraphError::pynew(py, e))?;
        let as_vec: Vec<PyObject> = sample
            .iter()
            .map(|rev| PyRevision(rev.0).to_py_object(py).into_object())
            .collect();
        Ok(PyTuple::new(py, as_vec.as_slice()).into_object())
    }

    fn inner_takequicksample(
        &self,
        py: Python,
        headrevs: PyObject,
        size: usize,
    ) -> PyResult<PyObject> {
        let revsvec = self.pyiter_to_vec(py, &headrevs)?;
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        let sample = inner
            .take_quick_sample(revsvec, size)
            .map_err(|e| GraphError::pynew(py, e))?;
        let as_vec: Vec<PyObject> = sample
            .iter()
            .map(|rev| PyRevision(rev.0).to_py_object(py).into_object())
            .collect();
        Ok(PyTuple::new(py, as_vec.as_slice()).into_object())
    }
}

/// Create the module, with __package__ given from parent
pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.discovery", package);
    let m = PyModule::new(py, dotted_name)?;
    m.add(py, "__package__", package)?;
    m.add(
        py,
        "__doc__",
        "Discovery of common node sets - Rust implementation",
    )?;
    m.add_class::<PartialDiscovery>(py)?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;
    // Example C code (see pyexpat.c and import.c) will "give away the
    // reference", but we won't because it will be consumed once the
    // Rust PyObject is dropped.
    Ok(m)
}
