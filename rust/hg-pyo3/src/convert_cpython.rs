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
use pyo3::{pyclass::boolean_struct::False, PyClass};

use cpython::ObjectProtocol;
use cpython::PythonObject;
use lazy_static::lazy_static;

use hg::revlog::index::Index as CoreIndex;
use rusthg::revlog::{InnerRevlog, PySharedIndex};

/// Marker trait for PyO3 objects with a lifetime representing the acquired GIL
///
/// # Safety
///
/// This trait must not be implemented for objects with lifetimes that
/// do not imply in PyO3 that the GIL is acquired during the whole lifetime.
pub unsafe trait WithGIL<'py> {}

// Safety: the lifetime on these PyO3 objects all represent the acquired GIL
unsafe impl<'py> WithGIL<'py> for Python<'py> {}
unsafe impl<'py, T> WithGIL<'py> for Bound<'py, T> {}
unsafe impl<'py, T: PyClass> WithGIL<'py> for PyRef<'py, T> {}
unsafe impl<'py, T: PyClass<Frozen = False>> WithGIL<'py>
    for PyRefMut<'py, T>
{
}

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
pub(crate) fn cpython_handle<'py, T: WithGIL<'py>>(
    _with_gil: &T,
) -> cpython::Python<'py> {
    // safety: this is safe because the returned object has the same lifetime
    // as the incoming object.
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

pub(crate) fn proxy_index_py_leak<'py>(
    index_proxy: &Bound<'py, PyAny>,
) -> PyResult<(cpython::Python<'py>, cpython::UnsafePyLeaked<PySharedIndex>)> {
    let (py, idx_proxy) = to_cpython_py_object(index_proxy);
    let py_leaked = py_rust_index_to_graph(py, idx_proxy)?;
    Ok((py, py_leaked))
}

/// Full extraction of the proxy index object as received in PyO3 to a
/// [`CoreIndex`] reference.
///
/// # Safety
///
/// The invariants to maintain are those of the underlying
/// [`UnsafePyLeaked::try_borrow`]: the caller must not leak the inner
/// reference.
pub(crate) unsafe fn proxy_index_extract<'py>(
    index_proxy: &Bound<'py, PyAny>,
) -> PyResult<&'py CoreIndex> {
    let (py, py_leaked) = proxy_index_py_leak(index_proxy)?;
    let py_shared = &*unsafe {
        py_leaked
            .try_borrow(py)
            .map_err(|e| from_cpython_pyerr(py, e))?
    };
    Ok(py_shared.inner)
}

/// Generic borrow of [`cpython::UnsafePyLeaked`], with proper mapping.
///
/// # Safety
///
/// The invariants to maintain are those of the underlying
/// [`UnsafePyLeaked::try_borrow`]: the caller must not leak the inner
/// static reference. It is possible, depending on `T` that such a leak cannot
/// occur in practice. We may later on define a marker trait for this,
/// which will allow us to make declare this function to be safe.
#[allow(dead_code)]
pub(crate) unsafe fn py_leaked_borrow<'a, 'py: 'a, T>(
    py: &impl WithGIL<'py>,
    leaked: &'a cpython::UnsafePyLeaked<T>,
) -> PyResult<cpython::PyLeakedRef<'a, T>> {
    let py = cpython_handle(py);
    leaked.try_borrow(py).map_err(|e| from_cpython_pyerr(py, e))
}

/// Mutable variant of [`py_leaked_borrow`]
///
/// # Safety
///
/// See [`py_leaked_borrow`]
pub(crate) unsafe fn py_leaked_borrow_mut<'a, 'py: 'a, T>(
    py: &impl WithGIL<'py>,
    leaked: &'a mut cpython::UnsafePyLeaked<T>,
) -> PyResult<cpython::PyLeakedRefMut<'a, T>> {
    let py = cpython_handle(py);
    leaked
        .try_borrow_mut(py)
        .map_err(|e| from_cpython_pyerr(py, e))
}

/// Error propagation for an [`UnsafePyLeaked`] wrapping a [`Result`]
///
/// TODO (will consider when implementing UnsafePyLeaked in PyO3):
/// It would be nice for UnsafePyLeaked to provide this directly as a variant
/// of the `map` method with a signature such as:
///
/// ```
///   unsafe fn map_or_err(&self,
///                        py: Python,
///                        f: impl FnOnce(T) -> Result(U, E),
///                        convert_err: impl FnOnce(E) -> PyErr)
/// ```
///
/// This would spare users of the `cpython` crate the additional `unsafe` deref
/// to inspect the error and return it outside `UnsafePyLeaked`, and the
/// subsequent unwrapping that this function performs.
pub(crate) fn py_leaked_or_map_err<T, E: std::fmt::Debug + Copy>(
    py: cpython::Python,
    leaked: cpython::UnsafePyLeaked<Result<T, E>>,
    convert_err: impl FnOnce(E) -> PyErr,
) -> PyResult<cpython::UnsafePyLeaked<T>> {
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    if let Err(e) = *unsafe {
        leaked
            .try_borrow(py)
            .map_err(|e| from_cpython_pyerr(py, e))?
    } {
        return Err(convert_err(e));
    }
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    Ok(unsafe {
        leaked.map(py, |res| {
            res.expect("Error case should have already be treated")
        })
    })
}
