// ancestors.rs
//
// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::ancestors` module provided by the
//! `hg-core` crate. From Python, this will be seen as `rustext.ancestor`
//! and can be used as replacement for the the pure `ancestor` Python module.
//!
//! # Classes visible from Python:
//! - [`LazyAncestors`] is the Rust implementation of
//!   `mercurial.ancestor.lazyancestors`. The only difference is that it is
//!   instantiated with a C `parsers.index` instance instead of a parents
//!   function.
//!
//! - [`MissingAncestors`] is the Rust implementation of
//!   `mercurial.ancestor.incrementalmissingancestors`.
//!
//!   API differences:
//!    + it is instantiated with a C `parsers.index`
//!      instance instead of a parents function.
//!    + `MissingAncestors.bases` is a method returning a tuple instead of
//!      a set-valued attribute. We could return a Python set easily if our
//!      [PySet PR](https://github.com/dgrunwald/rust-cpython/pull/165)
//!      is accepted.
//!
//! - [`AncestorsIterator`] is the Rust counterpart of the
//!   `ancestor._lazyancestorsiter` Python generator. From Python, instances of
//!   this should be mainly obtained by calling `iter()` on a [`LazyAncestors`]
//!   instance.
//!
//! [`LazyAncestors`]: struct.LazyAncestors.html
//! [`MissingAncestors`]: struct.MissingAncestors.html
//! [`AncestorsIterator`]: struct.AncestorsIterator.html
use crate::revlog::pyindex_to_graph;
use crate::PyRevision;
use crate::{
    cindex::Index, conversion::rev_pyiter_collect, exceptions::GraphError,
};
use cpython::{
    ObjectProtocol, PyClone, PyDict, PyList, PyModule, PyObject, PyResult,
    Python, PythonObject, ToPyObject,
};
use hg::MissingAncestors as CoreMissing;
use hg::Revision;
use std::cell::RefCell;
use std::collections::HashSet;
use vcsgraph::lazy_ancestors::{
    AncestorsIterator as VCGAncestorsIterator,
    LazyAncestors as VCGLazyAncestors,
};

py_class!(pub class AncestorsIterator |py| {
    data inner: RefCell<Box<VCGAncestorsIterator<Index>>>;

    def __next__(&self) -> PyResult<Option<PyRevision>> {
        match self.inner(py).borrow_mut().next() {
            Some(Err(e)) => Err(GraphError::pynew_from_vcsgraph(py, e)),
            None => Ok(None),
            Some(Ok(r)) => Ok(Some(PyRevision(r))),
        }
    }

    def __contains__(&self, rev: PyRevision) -> PyResult<bool> {
        self.inner(py).borrow_mut().contains(rev.0)
            .map_err(|e| GraphError::pynew_from_vcsgraph(py, e))
    }

    def __iter__(&self) -> PyResult<Self> {
        Ok(self.clone_ref(py))
    }

    def __new__(
        _cls,
        index: PyObject,
        initrevs: PyObject,
        stoprev: PyRevision,
        inclusive: bool
    ) -> PyResult<AncestorsIterator> {
        let index = pyindex_to_graph(py, index)?;
        let initvec: Vec<_> = rev_pyiter_collect(py, &initrevs, &index)?;
        let ait = VCGAncestorsIterator::new(
            index,
            initvec.into_iter().map(|r| r.0),
            stoprev.0,
            inclusive,
        )
        .map_err(|e| GraphError::pynew_from_vcsgraph(py, e))?;
        AncestorsIterator::from_inner(py, ait)
    }

});

impl AncestorsIterator {
    pub fn from_inner(
        py: Python,
        ait: VCGAncestorsIterator<Index>,
    ) -> PyResult<Self> {
        Self::create_instance(py, RefCell::new(Box::new(ait)))
    }
}

py_class!(pub class LazyAncestors |py| {
    data inner: RefCell<Box<VCGLazyAncestors<Index>>>;

    def __contains__(&self, rev: PyRevision) -> PyResult<bool> {
        self.inner(py)
            .borrow_mut()
            .contains(rev.0)
            .map_err(|e| GraphError::pynew_from_vcsgraph(py, e))
    }

    def __iter__(&self) -> PyResult<AncestorsIterator> {
        AncestorsIterator::from_inner(py, self.inner(py).borrow().iter())
    }

    def __bool__(&self) -> PyResult<bool> {
        Ok(!self.inner(py).borrow().is_empty())
    }

    def __new__(
        _cls,
        index: PyObject,
        initrevs: PyObject,
        stoprev: PyRevision,
        inclusive: bool
    ) -> PyResult<Self> {
        let index = pyindex_to_graph(py, index)?;
        let initvec: Vec<_> = rev_pyiter_collect(py, &initrevs, &index)?;

        let lazy =
            VCGLazyAncestors::new(
                index,
                initvec.into_iter().map(|r| r.0),
                stoprev.0,
                inclusive
            )
            .map_err(|e| GraphError::pynew_from_vcsgraph(py, e))?;

        Self::create_instance(py, RefCell::new(Box::new(lazy)))
        }

});

py_class!(pub class MissingAncestors |py| {
    data inner: RefCell<Box<CoreMissing<Index>>>;
    data index: RefCell<Index>;

    def __new__(
        _cls,
        index: PyObject,
        bases: PyObject
    )
    -> PyResult<MissingAncestors> {
        let index = pyindex_to_graph(py, index)?;
        let bases_vec: Vec<_> = rev_pyiter_collect(py, &bases, &index)?;

        let inner = CoreMissing::new(index.clone_ref(py), bases_vec);
        MissingAncestors::create_instance(
            py,
            RefCell::new(Box::new(inner)),
            RefCell::new(index)
        )
    }

    def hasbases(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().has_bases())
    }

    def addbases(&self, bases: PyObject) -> PyResult<PyObject> {
        let index = self.index(py).borrow();
        let bases_vec: Vec<_> = rev_pyiter_collect(py, &bases, &*index)?;
        let mut inner = self.inner(py).borrow_mut();
        inner.add_bases(bases_vec);
        // cpython doc has examples with PyResult<()> but this gives me
        //   the trait `cpython::ToPyObject` is not implemented for `()`
        // so let's return an explicit None
        Ok(py.None())
    }

    def bases(&self) -> PyResult<HashSet<PyRevision>> {
        Ok(
            self.inner(py)
                .borrow()
                .get_bases()
                .iter()
                .map(|r| PyRevision(r.0))
                .collect()
        )
    }

    def basesheads(&self) -> PyResult<HashSet<PyRevision>> {
        let inner = self.inner(py).borrow();
        Ok(
            inner
                .bases_heads()
                .map_err(|e| GraphError::pynew(py, e))?
                .into_iter()
                .map(|r| PyRevision(r.0))
                .collect()
        )
    }

    def removeancestorsfrom(&self, revs: PyObject) -> PyResult<PyObject> {
        let index = self.index(py).borrow();
        // this is very lame: we convert to a Rust set, update it in place
        // and then convert back to Python, only to have Python remove the
        // excess (thankfully, Python is happy with a list or even an iterator)
        // Leads to improve this:
        //  - have the CoreMissing instead do something emit revisions to
        //    discard
        //  - define a trait for sets of revisions in the core and implement
        //    it for a Python set rewrapped with the GIL marker
        let mut revs_pyset: HashSet<Revision> = rev_pyiter_collect(
            py, &revs, &*index
        )?;
        let mut inner = self.inner(py).borrow_mut();
        inner.remove_ancestors_from(&mut revs_pyset)
            .map_err(|e| GraphError::pynew(py, e))?;

        // convert as Python list
        let mut remaining_pyint_vec: Vec<PyObject> = Vec::with_capacity(
            revs_pyset.len());
        for rev in revs_pyset {
            remaining_pyint_vec.push(
                PyRevision(rev.0).to_py_object(py).into_object()
            );
        }
        let remaining_pylist = PyList::new(py, remaining_pyint_vec.as_slice());
        revs.call_method(py, "intersection_update", (remaining_pylist, ), None)
    }

    def missingancestors(&self, revs: PyObject) -> PyResult<PyList> {
        let index = self.index(py).borrow();
        let revs_vec: Vec<Revision> = rev_pyiter_collect(py, &revs, &*index)?;

        let mut inner = self.inner(py).borrow_mut();
        let missing_vec = match inner.missing_ancestors(revs_vec) {
            Ok(missing) => missing,
            Err(e) => {
                return Err(GraphError::pynew(py, e));
            }
        };
        // convert as Python list
        let mut missing_pyint_vec: Vec<PyObject> = Vec::with_capacity(
            missing_vec.len());
        for rev in missing_vec {
            missing_pyint_vec.push(
                PyRevision(rev.0).to_py_object(py).into_object()
            );
        }
        Ok(PyList::new(py, missing_pyint_vec.as_slice()))
    }
});

/// Create the module, with __package__ given from parent
pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.ancestor", package);
    let m = PyModule::new(py, dotted_name)?;
    m.add(py, "__package__", package)?;
    m.add(
        py,
        "__doc__",
        "Generic DAG ancestor algorithms - Rust implementation",
    )?;
    m.add_class::<AncestorsIterator>(py)?;
    m.add_class::<LazyAncestors>(py)?;
    m.add_class::<MissingAncestors>(py)?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;
    // Example C code (see pyexpat.c and import.c) will "give away the
    // reference", but we won't because it will be consumed once the
    // Rust PyObject is dropped.
    Ok(m)
}
