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
//!    + it is instantiated with a C `parsers.index` instance instead of a
//!      parents function.
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
use crate::revlog::py_rust_index_to_graph;
use crate::PyRevision;
use crate::{
    conversion::rev_pyiter_collect, exceptions::GraphError,
    revlog::PySharedIndex,
};
use cpython::{
    ObjectProtocol, PyClone, PyDict, PyErr, PyList, PyModule, PyObject,
    PyResult, Python, PythonObject, ToPyObject, UnsafePyLeaked,
};

use hg::MissingAncestors as CoreMissing;
use hg::Revision;
use std::cell::RefCell;
use std::collections::HashSet;
use vcsgraph::lazy_ancestors::{
    AncestorsIterator as VCGAncestorsIterator,
    LazyAncestors as VCGLazyAncestors,
};

// Error propagation for an [`UnsafePyLeaked`] wrapping a [`Result`]
//
// It would be nice for UnsharedPyLeaked to provide this directly as a variant
// of the `map` method with a signature such as:
//
// ```
//   unsafe fn map_or_err(py: Python,
//                        f: impl FnOnce(T) -> Result(U, E),
//                        convert_err: impl FnOnce(Python, E) -> PyErr)
// ```
//
// This would spare users of the `cpython` crate the additional `unsafe` deref
// to inspect the error and return it outside `UnsafePyLeaked`, and the
// subsequent unwrapping that this function performs.
fn pyleaked_or_map_err<T, E: std::fmt::Debug + Copy>(
    py: Python,
    leaked: UnsafePyLeaked<Result<T, E>>,
    convert_err: impl FnOnce(Python, E) -> PyErr,
) -> PyResult<UnsafePyLeaked<T>> {
    // Result.inspect_err is unstable in Rust 1.61
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    if let Err(e) = *unsafe { leaked.try_borrow(py)? } {
        return Err(convert_err(py, e));
    }
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    Ok(unsafe {
        leaked.map(py, |res| {
            res.expect("Error case should have already be treated")
        })
    })
}

py_class!(pub class AncestorsIterator |py| {
    data inner: RefCell<UnsafePyLeaked<VCGAncestorsIterator<PySharedIndex>>>;

    def __next__(&self) -> PyResult<Option<PyRevision>> {
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        match inner.next() {
            Some(Err(e)) => Err(GraphError::pynew_from_vcsgraph(py, e)),
            None => Ok(None),
            Some(Ok(r)) => Ok(Some(PyRevision(r))),
        }
    }

    def __contains__(&self, rev: PyRevision) -> PyResult<bool> {
        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let mut inner = unsafe { leaked.try_borrow_mut(py)? };
        inner.contains(rev.0)
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
        Self::inner_new(py, index, initrevs, stoprev, inclusive)
    }

});

impl AncestorsIterator {
    pub fn from_inner(
        py: Python,
        ait: UnsafePyLeaked<VCGAncestorsIterator<PySharedIndex>>,
    ) -> PyResult<Self> {
        Self::create_instance(py, RefCell::new(ait))
    }

    pub fn inner_new(
        py: Python,
        index: PyObject,
        initrevs: PyObject,
        stoprev: PyRevision,
        inclusive: bool,
    ) -> PyResult<AncestorsIterator> {
        let index = py_rust_index_to_graph(py, index)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let initvec: Vec<_> = {
            let borrowed_idx = unsafe { index.try_borrow(py)? };
            rev_pyiter_collect(py, &initrevs, &*borrowed_idx)?
        };
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let res_ait = unsafe {
            index.map(py, |idx| {
                VCGAncestorsIterator::new(
                    idx,
                    initvec.into_iter().map(|r| r.0),
                    stoprev.0,
                    inclusive,
                )
            })
        };
        let ait =
            pyleaked_or_map_err(py, res_ait, GraphError::pynew_from_vcsgraph)?;
        AncestorsIterator::from_inner(py, ait)
    }
}

py_class!(pub class LazyAncestors |py| {
    data inner: RefCell<UnsafePyLeaked<
        RefCell<VCGLazyAncestors<PySharedIndex>>
        >>;
    data index: PyObject;
    data initrevs: PyObject;
    data stoprev: PyRevision;
    data inclusive: bool;

    def __contains__(&self, rev: PyRevision) -> PyResult<bool> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &RefCell<VCGLazyAncestors<PySharedIndex>> =
            &*unsafe { leaked.try_borrow(py)? };
        let inner_mut: &mut VCGLazyAncestors<PySharedIndex> =
            &mut inner.borrow_mut();
        inner_mut.contains(rev.0)
            .map_err(|e| GraphError::pynew_from_vcsgraph(py, e))
    }

    def __iter__(&self) -> PyResult<AncestorsIterator> {
        let index = self.index(py).clone_ref(py);
        let initrevs = self.initrevs(py).clone_ref(py);
        AncestorsIterator::inner_new(py, index, initrevs,
                                     *self.stoprev(py),
                                     *self.inclusive(py))
    }

    def __bool__(&self) -> PyResult<bool> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe { leaked.try_borrow(py)? };
        let empty = inner.borrow().is_empty();
        Ok(!empty)
    }

    def __new__(
        _cls,
        index: PyObject,
        initrevs: PyObject,
        stoprev: PyRevision,
        inclusive: bool
    ) -> PyResult<Self> {
        let cloned_index = index.clone_ref(py);
        let index = py_rust_index_to_graph(py, index)?;
        let initvec: Vec<_> = {
            // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
            let borrowed_idx =  unsafe {index.try_borrow(py)?};
            rev_pyiter_collect(py, &initrevs, &*borrowed_idx)?
        };

        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let res_lazy =
            unsafe { index.map(py, |idx| VCGLazyAncestors::new(
                idx,
                initvec.into_iter().map(|r| r.0),
                stoprev.0,
                inclusive
            ))};
        let lazy = pyleaked_or_map_err(py, res_lazy,
                                       GraphError::pynew_from_vcsgraph)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let lazy_cell = unsafe { lazy.map(py, RefCell::new)};
        let res = Self::create_instance(
            py, RefCell::new(lazy_cell),
            cloned_index, initrevs, stoprev, inclusive)?;
        Ok(res)
        }

});

py_class!(pub class MissingAncestors |py| {
    data inner: RefCell<UnsafePyLeaked<
        CoreMissing<PySharedIndex>
        >>;
    data index: PyObject;

    def __new__(
        _cls,
        index: PyObject,
        bases: PyObject
    )
    -> PyResult<MissingAncestors> {
        let cloned_index = index.clone_ref(py);
        let inner_index = py_rust_index_to_graph(py, index)?;
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let bases_vec: Vec<_> = {
            let borrowed_idx = unsafe { inner_index.try_borrow(py)? };
            rev_pyiter_collect(py, &bases, &*borrowed_idx)?
        };

        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner = unsafe {
            inner_index.map(py, |idx| CoreMissing::new(idx, bases_vec))
        };
        MissingAncestors::create_instance(
            py,
            RefCell::new(inner),
            cloned_index,
        )
    }

    def hasbases(&self) -> PyResult<bool> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &CoreMissing<PySharedIndex> =
            &*unsafe { leaked.try_borrow(py)? };
        Ok(inner.has_bases())
    }

    def addbases(&self, bases: PyObject) -> PyResult<PyObject> {
        let bases_vec: Vec<_> = {
            let leaked = py_rust_index_to_graph(py,
                                               self.index(py).clone_ref(py))?;
            // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
            let index = &*unsafe { leaked.try_borrow(py)? };
            rev_pyiter_collect(py, &bases, index)?
        };

        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &mut CoreMissing<PySharedIndex> =
            &mut *unsafe { leaked.try_borrow_mut(py)? };

        inner.add_bases(bases_vec);
        // cpython doc has examples with PyResult<()> but this gives me
        //   the trait `cpython::ToPyObject` is not implemented for `()`
        // so let's return an explicit None
        Ok(py.None())
    }

    def bases(&self) -> PyResult<HashSet<PyRevision>> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &CoreMissing<PySharedIndex> =
            &*unsafe { leaked.try_borrow(py)? };
        Ok(inner.get_bases()
           .iter()
           .map(|r| PyRevision(r.0))
           .collect()
        )
    }

    def basesheads(&self) -> PyResult<HashSet<PyRevision>> {
        let leaked = self.inner(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &CoreMissing<PySharedIndex> =
            &*unsafe { leaked.try_borrow(py)? };
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
        let mut revs_pyset: HashSet<Revision> = {
            // this is very lame: we convert to a Rust set, update it in place
            // and then convert back to Python, only to have Python remove the
            // excess (thankfully, Python is happy with a list or even an
            // iterator)
            // Leads to improve this:
            //  - have the CoreMissing instead do something emit revisions to
            //    discard
            //  - define a trait for sets of revisions in the core and
            //    implement it for a Python set rewrapped with the GIL marker
            let leaked = py_rust_index_to_graph(py,
                                               self.index(py).clone_ref(py))?;
            // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
            let index = &*unsafe { leaked.try_borrow(py)? };
            rev_pyiter_collect(py, &revs, index)?
        };

        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &mut CoreMissing<PySharedIndex> =
            &mut *unsafe { leaked.try_borrow_mut(py)? };

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
        let revs_vec: Vec<Revision> = {
            let leaked = py_rust_index_to_graph(py,
                                               self.index(py).clone_ref(py))?;
            // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
            let index = &*unsafe { leaked.try_borrow(py)? };
            rev_pyiter_collect(py, &revs, index)?
        };

        let mut leaked = self.inner(py).borrow_mut();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let inner: &mut CoreMissing<PySharedIndex> =
            &mut *unsafe { leaked.try_borrow_mut(py)? };

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
