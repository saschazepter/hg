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
//! - [`PartialDiscover`] is the Rust implementation of
//!   `mercurial.setdiscovery.partialdiscovery`.

use crate::conversion::{py_set, rev_pyiter_collect};
use cindex::Index;
use cpython::{
    ObjectProtocol, PyDict, PyModule, PyObject, PyResult, Python,
    PythonObject, ToPyObject,
};
use exceptions::GraphError;
use hg::discovery::PartialDiscovery as CorePartialDiscovery;
use hg::Revision;

use std::cell::RefCell;

py_class!(pub class PartialDiscovery |py| {
    data inner: RefCell<Box<CorePartialDiscovery<Index>>>;

    def __new__(
        _cls,
        index: PyObject,
        targetheads: PyObject
    ) -> PyResult<PartialDiscovery> {
        Self::create_instance(
            py,
            RefCell::new(Box::new(CorePartialDiscovery::new(
                Index::new(py, index)?,
                rev_pyiter_collect(py, &targetheads)?,
            )))
        )
    }

    def addcommons(&self, commons: PyObject) -> PyResult<PyObject> {
        let mut inner = self.inner(py).borrow_mut();
        let commons_vec: Vec<Revision> = rev_pyiter_collect(py, &commons)?;
        inner.add_common_revisions(commons_vec)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    def addmissings(&self, missings: PyObject) -> PyResult<PyObject> {
        let mut inner = self.inner(py).borrow_mut();
        let missings_vec: Vec<Revision> = rev_pyiter_collect(py, &missings)?;
        inner.add_missing_revisions(missings_vec)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    def addinfo(&self, sample: PyObject) -> PyResult<PyObject> {
        let mut missing: Vec<Revision> = Vec::new();
        let mut common: Vec<Revision> = Vec::new();
        for info in sample.iter(py)? { // info is a pair (Revision, bool)
            let mut revknown = info?.iter(py)?;
            let rev: Revision = revknown.next().unwrap()?.extract(py)?;
            let known: bool = revknown.next().unwrap()?.extract(py)?;
            if known {
                common.push(rev);
            } else {
                missing.push(rev);
            }
        }
        let mut inner = self.inner(py).borrow_mut();
        inner.add_common_revisions(common)
            .map_err(|e| GraphError::pynew(py, e))?;
        inner.add_missing_revisions(missing)
            .map_err(|e| GraphError::pynew(py, e))?;
        Ok(py.None())
    }

    def hasinfo(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().has_info())
    }

    def iscomplete(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().is_complete())
    }

    def stats(&self) -> PyResult<PyDict> {
        let stats = self.inner(py).borrow().stats();
        let as_dict: PyDict = PyDict::new(py);
        as_dict.set_item(py, "undecided",
                         stats.undecided.map(
                             |l| l.to_py_object(py).into_object())
                             .unwrap_or_else(|| py.None()))?;
        Ok(as_dict)
    }

    def commonheads(&self) -> PyResult<PyObject> {
        py_set(
            py,
            &self.inner(py).borrow().common_heads()
                .map_err(|e| GraphError::pynew(py, e))?
        )
    }
});

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
