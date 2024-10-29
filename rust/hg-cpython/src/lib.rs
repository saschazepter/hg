// lib.rs
//
// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Python bindings of `hg-core` objects using the `cpython` crate.
//! Once compiled, the resulting single shared library object can be placed in
//! the `mercurial` package directly as `rustext.so` or `rustext.dll`.
//! It holds several modules, so that from the point of view of Python,
//! it behaves as the `cext` package.
//!
//! Example:
//!
//! ```text
//! >>> from mercurial.rustext import ancestor
//! >>> ancestor.__doc__
//! 'Generic DAG ancestor algorithms - Rust implementation'
//! ```
#![allow(clippy::too_many_arguments)] // rust-cpython macros
#![allow(clippy::zero_ptr)] // rust-cpython macros
#![allow(clippy::needless_update)] // rust-cpython macros
#![allow(clippy::manual_strip)] // rust-cpython macros
#![allow(clippy::type_complexity)] // rust-cpython macros

use cpython::{FromPyObject, PyInt, Python, ToPyObject};
use hg::{BaseRevision, Revision};

/// This crate uses nested private macros, `extern crate` is still needed in
/// 2018 edition.
#[macro_use]
extern crate cpython;

pub mod ancestors;
mod cindex;
mod conversion;
#[macro_use]
pub mod ref_sharing;
pub mod copy_tracing;
pub mod dagops;
pub mod debug;
pub mod dirstate;
pub mod discovery;
pub mod exceptions;
mod pybytes_deref;
pub mod revlog;
pub mod update;
pub mod utils;
pub mod vfs;

/// Revision as exposed to/from the Python layer.
///
/// We need this indirection because of the orphan rule, meaning we can't
/// implement a foreign trait (like [`cpython::ToPyObject`])
/// for a foreign type (like [`hg::UncheckedRevision`]).
///
/// This also acts as a deterrent against blindly trusting Python to send
/// us valid revision numbers.
#[derive(Debug, Copy, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PyRevision(BaseRevision);

impl From<Revision> for PyRevision {
    fn from(r: Revision) -> Self {
        PyRevision(r.0)
    }
}

impl<'s> FromPyObject<'s> for PyRevision {
    fn extract(
        py: Python,
        obj: &'s cpython::PyObject,
    ) -> cpython::PyResult<Self> {
        Ok(Self(obj.extract::<BaseRevision>(py)?))
    }
}

impl ToPyObject for PyRevision {
    type ObjectType = PyInt;

    fn to_py_object(&self, py: Python) -> Self::ObjectType {
        self.0.to_py_object(py)
    }
}

py_module_initializer!(rustext, initrustext, PyInit_rustext, |py, m| {
    m.add(
        py,
        "__doc__",
        "Mercurial core concepts - Rust implementation",
    )?;

    let dotted_name: String = m.get(py, "__name__")?.extract(py)?;
    m.add(py, "ancestor", ancestors::init_module(py, &dotted_name)?)?;
    m.add(py, "dagop", dagops::init_module(py, &dotted_name)?)?;
    m.add(py, "debug", debug::init_module(py, &dotted_name)?)?;
    m.add(
        py,
        "copy_tracing",
        copy_tracing::init_module(py, &dotted_name)?,
    )?;
    m.add(py, "discovery", discovery::init_module(py, &dotted_name)?)?;
    m.add(py, "dirstate", dirstate::init_module(py, &dotted_name)?)?;
    m.add(py, "revlog", revlog::init_module(py, &dotted_name)?)?;
    m.add(py, "update", update::init_module(py, &dotted_name)?)?;
    m.add(py, "GraphError", py.get_type::<exceptions::GraphError>())?;
    Ok(())
});
