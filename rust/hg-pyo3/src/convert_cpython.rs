//! This module takes care of all conversions involving `rusthg` (hg-cpython)
//! objects in the PyO3 call context.
//!
//! For source code clarity, we only import (`use`) [`cpython`] traits and not
//! any of its data objects. We are instead using full qualifiers, such as
//! `cpython::PyObject`, and believe that the added heaviness is an acceptatble
//! price to pay to avoid confusion.
//!
//! Also it, is customary in [`cpython`] to label the GIL lifetime as `'p`,
//! whereas it is `'py` in PyO3 context. We keep both these conventions in
//! the arguments side of function signatures when they are not simply elided.
use pyo3::exceptions::PyTypeError;
use pyo3::prelude::*;

use cpython::ObjectProtocol;
use cpython::PythonObject;
use lazy_static::lazy_static;

use hg::revlog::index::Index as CoreIndex;
use rusthg::revlog::{InnerRevlog, PySharedIndex};

/// Force cpython's GIL handle with the appropriate lifetime
///
/// In `pyo3`, the fact that we have the GIL is expressed by the lifetime of
/// the incoming [`Bound`] smart pointer. We therefore simply instantiate
/// the `cpython` handle and coerce its lifetime by the function signature.
///
/// Reacquiring the GIL is also a possible alternative, as the CPython
/// documentation explicitely states that "recursive calls are allowed"
/// (we interpret that as saying that acquiring the GIL within a thread that
/// already has it works) *as long as it is properly released*
/// reference:
/// <https://docs.python.org/3.8/c-api/init.html#c.PyGILState_Ensure>
pub(crate) fn cpython_handle<'py, T>(
    _bound: &Bound<'py, T>,
) -> cpython::Python<'py> {
    // safety: this is safe because the returned object has the 'py lifetime
    unsafe { cpython::Python::assume_gil_acquired() }
}

/// Force PyO3 GIL handle from cpython's.
///
/// Very similar to [`cpython_handle`]
pub fn pyo3_handle(_py: cpython::Python<'_>) -> Python<'_> {
    // safety: this is safe because the returned object has the same lifetime
    // as the incoming object.
    unsafe { Python::assume_gil_acquired() }
}

/// Convert a PyO3 [`PyObject`] into a [`cpython::PyObject`]
///
/// During this process, the reference count is increased, then decreased.
/// This means that the GIL (symbolized by the lifetime on the `obj`
/// argument) is needed.
///
/// We could make something perhaps more handy by simply stealing the
/// pointer, forgetting the incoming and then implement `From` with "newtype".
/// It would be worth the effort for a generic cpython-to-pyo3 crate, perhaps
/// not for the current endeavour.
pub(crate) fn to_cpython_py_object<'py>(
    obj: &Bound<'py, PyAny>,
) -> (cpython::Python<'py>, cpython::PyObject) {
    let py = cpython_handle(obj);
    // public alias of the private cpython::fii::PyObject (!)
    let raw = obj.as_ptr() as *mut python3_sys::PyObject;
    // both pyo3 and rust-cpython will decrement the refcount on drop.
    // If we use from_owned_ptr, that's a segfault.
    (py, unsafe { cpython::PyObject::from_borrowed_ptr(py, raw) })
}

/// Convert a [`cpython::PyObject`] into a PyO3 [`PyObject`]
///
/// During this process, the reference count is increased, then decreased.
/// This means that the GIL (symbolized by the PyO3 [`Python`] handle is
/// needed.
///
/// We could make something perhaps more handy by simply stealing the
/// pointer, forgetting the incoming and then implement `From` with "newtype".
/// It would be worth the effort for a generic cpython-to-pyo3 crate, perhaps
/// not for the current endeavour.
pub(crate) fn from_cpython_py_object(
    py: Python<'_>,
    obj: cpython::PyObject,
) -> PyObject {
    let raw = obj.as_ptr() as *mut pyo3::ffi::PyObject;
    unsafe { Py::from_borrowed_ptr(py, raw) }
}

/// Convert [`cpython::PyErr`] into [`pyo3::PyErr`]
///
/// The exception class remains the same as the original exception,
/// hence if it is also defined in another dylib based on `cpython` crate,
/// it will need to be converted to be downcasted in this crate.
pub(crate) fn from_cpython_pyerr(
    py: cpython::Python<'_>,
    mut e: cpython::PyErr,
) -> PyErr {
    let pyo3_py = pyo3_handle(py);
    let cpython_exc_obj = e.instance(py);
    let pyo3_exc_obj = from_cpython_py_object(pyo3_py, cpython_exc_obj);
    PyErr::from_value(pyo3_exc_obj.into_bound(pyo3_py))
}

/// Retrieve the PyType for objects from the `mercurial.rustext` crate.
fn retrieve_cpython_py_type(
    submodule_name: &str,
    type_name: &str,
) -> cpython::PyResult<cpython::PyType> {
    let guard = cpython::Python::acquire_gil();
    let py = guard.python();
    let module = py.import(&format!("mercurial.rustext.{submodule_name}"))?;
    module.get(py, type_name)?.extract::<cpython::PyType>(py)
}

lazy_static! {
    static ref INNER_REVLOG_PY_TYPE: cpython::PyType = {
        retrieve_cpython_py_type("revlog", "InnerRevlog")
            .expect("Could not import InnerRevlog in Python")
    };
}

/// Downcast [`InnerRevlog`], with the appropriate Python type checking.
///
/// The PyType object representing the `InnerRevlog` Python class is not the
/// the same in this dylib as it is in the `mercurial.rustext` module.
/// This is because the code created with the [`cpython::py_class!`]
/// macro is itself duplicated in both dylibs. In the case of this crate, this
/// happens by linking to the [`rusthg`] crate and provides the `InnerRevlog`
/// that is visible from this crate. The `InnerRevlog::get_type` associated
/// function turns out to return a `static mut` (look for `TYPE_OBJECT` in
/// `py_class_impl3.rs`), which obviously is different in both dylibs.
///
/// The consequence of that is that downcasting an `InnerRevlog` originally
/// from the `mecurial.rustext` module to our `InnerRevlog` cannot be done with
/// the usual `extract::<InnerRevlog>(py)`, as it would perform the type
/// checking with the `PyType` that is embedded in `mercurial.pyo3_rustext`.
/// We must check the `PyType` that is within `mercurial.rustext` instead.
/// This is what this function does.
fn extract_inner_revlog(
    py: cpython::Python,
    inner_revlog: cpython::PyObject,
) -> PyResult<InnerRevlog> {
    if !(*INNER_REVLOG_PY_TYPE).is_instance(py, &inner_revlog) {
        return Err(PyTypeError::new_err("Not an InnerRevlog instance"));
    }
    // Safety: this is safe because we checked the PyType already, with the
    // value embedded in `mercurial.rustext`.
    Ok(unsafe { InnerRevlog::unchecked_downcast_from(inner_revlog) })
}

/// This is similar to [`rusthg.py_rust_index_to_graph`], with difference in
/// how we retrieve the [`InnerRevlog`].
pub fn py_rust_index_to_graph(
    py: cpython::Python,
    index_proxy: cpython::PyObject,
) -> PyResult<cpython::UnsafePyLeaked<PySharedIndex>> {
    let inner_revlog = extract_inner_revlog(
        py,
        index_proxy
            .getattr(py, "inner")
            .map_err(|e| from_cpython_pyerr(py, e))?,
    )?;

    let leaked = inner_revlog.pub_inner(py).leak_immutable();
    // Safety: we don't leak the "faked" reference out of the `UnsafePyLeaked`
    Ok(unsafe { leaked.map(py, |idx| PySharedIndex { inner: &idx.index }) })
}

/// Full extraction of the proxy index object as received in PyO3 to a
/// [`CoreIndex`] reference.
///
/// The safety invariants to maintain are those of the underlying
/// [`UnsafePyLeaked::try_borrow`]: the caller must not leak the inner
/// reference.
pub(crate) unsafe fn proxy_index_extract<'py>(
    index_proxy: &Bound<'py, PyAny>,
) -> PyResult<&'py CoreIndex> {
    let (py, idx_proxy) = to_cpython_py_object(index_proxy);
    let py_leaked = py_rust_index_to_graph(py, idx_proxy)?;
    let py_shared = &*unsafe {
        py_leaked
            .try_borrow(py)
            .map_err(|e| from_cpython_pyerr(py, e))?
    };
    Ok(py_shared.inner)
}
