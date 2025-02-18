use hg::errors::HgError;
use hg::revlog::index::Index as CoreIndex;
use hg::revlog::inner_revlog::RevisionBuffer;
use pyo3::buffer::{Element, PyBuffer};
use pyo3::exceptions::{
    PyIOError, PyKeyboardInterrupt, PyRuntimeError, PyValueError,
};
use pyo3::types::{PyBytes, PyDict};
use pyo3::{intern, prelude::*};
use pyo3_sharedref::SharedByPyObject;
use stable_deref_trait::StableDeref;

use crate::exceptions::FallbackError;
use crate::revlog::{InnerRevlog, PySharedIndex};

/// Create the module, with `__package__` given from parent
///
/// According to PyO3 documentation, which links to
/// <https://github.com/PyO3/pyo3/issues/1517>, the same convoluted
/// write to sys.modules has to be made as with the `cpython` crate.
pub(crate) fn new_submodule<'py>(
    py: Python<'py>,
    package_name: &str,
    name: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let dotted_name = &format!("{}.{}", package_name, name);
    let m = PyModule::new(py, name)?;
    m.add("__package__", package_name)?;

    let sys = PyModule::import(py, "sys")?;
    // according to the doc, we could make a static PyString out of
    // "modules" with the `intern!` macro, but this is used only at
    // registration so it may not be worth the effort.
    let sys_modules: Bound<'_, PyDict> = sys.getattr("modules")?.extract()?;
    sys_modules.set_item(dotted_name, &m)?;
    // Example C code (see pyexpat.c and import.c) will "give away the
    // reference", but we won't because it will be consumed once the
    // Rust PyObject is dropped.
    Ok(m)
}

/// Retrieve the shared index wrapper (which contains the core index)
/// from the Python index proxy.
pub fn py_rust_index_to_graph(
    index_proxy: &Bound<'_, PyAny>,
) -> PyResult<SharedByPyObject<PySharedIndex>> {
    let py_irl = index_proxy.getattr("inner")?;
    let py_irl_ref = py_irl.downcast::<InnerRevlog>()?.borrow();
    let shareable_irl = &py_irl_ref.irl;

    // Safety: the owner is the actual one and we do not leak any
    // internal reference.
    let index =
        unsafe { shareable_irl.share_map(&py_irl, |irl| (&irl.index).into()) };
    Ok(index)
}

/// Error propagation for an [`SharedByPyObject`] wrapping a [`Result`]
///
/// It would be nice for [`SharedByPyObject`] to provide this directly as
/// a variant of the `map` method with a signature such as:
///
/// ```
///   unsafe fn map_or_err(&self,
///                        py: Python,
///                        f: impl FnOnce(T) -> Result(U, E),
///                        convert_err: impl FnOnce(E) -> PyErr)
/// ```
///
/// This would spare users of the `pyo3` crate the additional `unsafe` deref
/// to inspect the error and return it outside `SharedByPyObject`, and the
/// subsequent unwrapping that this function performs.
pub(crate) fn py_shared_or_map_err<T, E: std::fmt::Debug + Copy>(
    py: Python,
    leaked: SharedByPyObject<Result<T, E>>,
    convert_err: impl FnOnce(E) -> PyErr,
) -> PyResult<SharedByPyObject<T>> {
    // Safety: we don't leak the "faked" reference out of `SharedByPyObject`
    if let Err(e) = *unsafe { leaked.try_borrow(py)? } {
        return Err(convert_err(e));
    }
    // Safety: we don't leak the "faked" reference out of `SharedByPyObject`
    Ok(unsafe {
        leaked.map(py, |res| {
            res.expect("Error case should have already be treated")
        })
    })
}

/// Full extraction of the proxy index object as received in PyO3 to a
/// [`CoreIndex`] reference.
///
/// # Safety
///
/// The invariants to maintain are those of the underlying
/// [`SharedByPyObject::try_borrow`]: the caller must not leak the inner
/// reference.
pub(crate) unsafe fn proxy_index_extract<'py>(
    index_proxy: &Bound<'py, PyAny>,
) -> PyResult<&'py CoreIndex> {
    let py_shared = py_rust_index_to_graph(index_proxy)?;
    let py_shared = &*unsafe { py_shared.try_borrow(index_proxy.py())? };
    Ok(unsafe { py_shared.static_inner() })
}

/// Type shortcut for the kind of bytes slice trait objects that are used in
/// particular for mmap data
type BoxedBytesSlice =
    Box<dyn std::ops::Deref<Target = [u8]> + Send + Sync + 'static>;

/// Take a Python object backed by a Python buffer, and return the underlying
/// [`PyBuffer`] along with the Rust slice into said buffer.
///
/// The caller needs to make sure that the Python buffer is not freed before
/// the slice, otherwise we'd get a dangling pointer once the incoming
/// object is freed from Python side. This can be achieved by storing it a
/// Python object.
///
/// The typical use case is to extract mmap data to make it useable in the
/// constructs from the `hg` crate.
///
/// # Safety
///
/// The caller must make sure that the incoming Python object is kept around
/// for at least as long as the returned [`BoxedBytesSlice`].
// TODO in PyO3, we already get a reference with two lifetimes, and we
// could even take a `Borrowed<'a, 'py, T>`.
// So perhaps we could tie everything together with a lifetime so that is
// is, after all, safe, and this could be called something like `share_buffer`.
#[deny(unsafe_op_in_unsafe_fn)]
pub unsafe fn take_buffer_with_slice(
    data: &Bound<'_, PyAny>,
) -> PyResult<(PyBuffer<u8>, BoxedBytesSlice)> {
    let buf = PyBuffer::<u8>::get(data)?;
    let len = buf.item_count();

    // Build a slice from the buffer data
    let cbuf = buf.buf_ptr();
    let bytes = if std::mem::size_of::<u8>() == buf.item_size()
        && buf.is_c_contiguous()
        && u8::is_compatible_format(buf.format())
        && buf.dimensions() == 1
        && buf.readonly()
    {
        unsafe { std::slice::from_raw_parts(cbuf as *const u8, len) }
    } else {
        return Err(PyValueError::new_err(
            "buffer has an invalid memory representation",
        ));
    };

    Ok((buf, Box::new(bytes)))
}

/// Takes an initialization function `init` which writes bytes to a
/// Python-backed buffer, to save on a (potentially large) memory allocation
/// and copy. If `init` fails to write the full expected length `len`, an error
/// is raised.
pub fn with_pybytes_buffer<F>(
    py: Python,
    len: usize,
    init: F,
) -> Result<Py<PyBytes>, hg::revlog::RevlogError>
where
    F: FnOnce(
        &mut dyn RevisionBuffer<Target = Py<PyBytes>>,
    ) -> Result<(), hg::revlog::RevlogError>,
{
    // Largely inspired by code in PyO3
    // https://pyo3.rs/main/doc/pyo3/types/struct.pybytes#method.new_bound_with
    unsafe {
        let pyptr = pyo3::ffi::PyBytes_FromStringAndSize(
            std::ptr::null(),
            len as pyo3::ffi::Py_ssize_t,
        );
        let pybytes = Bound::from_owned_ptr_or_err(py, pyptr)
            .map_err(|e| HgError::abort_simple(e.to_string()))?
            .downcast_into_unchecked();
        let buffer: *mut u8 = pyo3::ffi::PyBytes_AsString(pyptr).cast();
        debug_assert!(!buffer.is_null());
        let mut rev_buf = PyRevisionBuffer::new(pybytes.unbind(), buffer, len);
        // Initialise the bytestring in init
        // If init returns an Err, the buffer is deallocated by `pybytes`
        init(&mut rev_buf).map(|_| rev_buf.finish())
    }
}

/// Safe abstraction over a `PyBytes` together with the `&[u8]` slice
/// that borrows it. Implements `Deref<Target = [u8]>`.
///
/// Calling `PyBytes::data` requires a GIL marker but we want to access the
/// data in a thread that (ideally) does not need to acquire the GIL.
/// This type allows separating the call an the use.
///
/// It also enables using a (wrapped) `PyBytes` in GIL-unaware generic code.
pub struct PyBytesDeref {
    #[allow(unused)]
    keep_alive: Py<PyBytes>,

    /// Borrows the buffer inside `self.keep_alive`,
    /// but the borrow-checker cannot express self-referential structs.
    data: &'static [u8],
}

impl PyBytesDeref {
    pub fn new(py: Python, bytes: Py<PyBytes>) -> Self {
        let as_raw: *const [u8] = bytes.as_bytes(py);
        Self {
            // Safety: the raw pointer is valid as long as the PyBytes is still
            // alive, and the objecs owns it.
            data: unsafe { &*as_raw },
            keep_alive: bytes,
        }
    }

    #[allow(unused)]
    pub fn unwrap(self) -> Py<PyBytes> {
        self.keep_alive
    }
}

impl std::ops::Deref for PyBytesDeref {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        self.data
    }
}

unsafe impl StableDeref for PyBytesDeref {}

fn require_send<T: Send>() {}

#[allow(unused)]
fn static_assert_pybytes_is_send() {
    #[allow(clippy::no_effect)]
    require_send::<Py<PyBytes>>;
}

// Safety: `[Py<PyBytes>]` is Send. Raw pointers are not by default,
// but here sending one to another thread is fine since we ensure it stays
// valid.
unsafe impl Send for PyBytesDeref {}

/// Wrapper around a Python-provided buffer into which the revision contents
/// will be written. Done for speed in order to save a large allocation + copy.
struct PyRevisionBuffer {
    py_bytes: Py<PyBytes>,
    _buf: *mut u8,
    len: usize,
    current_buf: *mut u8,
    current_len: usize,
}

impl PyRevisionBuffer {
    /// # Safety
    ///
    /// `buf` should be the start of the allocated bytes of `bytes`, and `len`
    /// exactly the length of said allocated bytes.
    #[inline]
    unsafe fn new(bytes: Py<PyBytes>, buf: *mut u8, len: usize) -> Self {
        Self {
            py_bytes: bytes,
            _buf: buf,
            len,
            current_len: 0,
            current_buf: buf,
        }
    }

    /// Number of bytes that have been copied to. Will be different to the
    /// total allocated length of the buffer unless the revision is done being
    /// written.
    #[inline]
    fn current_len(&self) -> usize {
        self.current_len
    }
}

impl RevisionBuffer for PyRevisionBuffer {
    type Target = Py<PyBytes>;

    #[inline]
    fn extend_from_slice(&mut self, slice: &[u8]) {
        assert!(self.current_len + slice.len() <= self.len);
        unsafe {
            // We cannot use `copy_from_nonoverlapping` since it's *possible*
            // to create a slice from the same Python memory region using
            // [`PyBytesDeref`]. Probable that LLVM has an optimization anyway?
            self.current_buf.copy_from(slice.as_ptr(), slice.len());
            self.current_buf = self.current_buf.add(slice.len());
        }
        self.current_len += slice.len()
    }

    #[inline]
    fn finish(self) -> Self::Target {
        // catch unzeroed bytes before it becomes undefined behavior
        assert_eq!(
            self.current_len(),
            self.len,
            "not enough bytes read for revision"
        );
        self.py_bytes
    }
}

/// Extension trait to help with generic error conversions from hg-core to
/// Python.
pub(crate) trait HgPyErrExt<T> {
    fn into_pyerr(self, py: Python) -> PyResult<T>;
}

impl<T, E> HgPyErrExt<T> for Result<T, E>
where
    HgError: From<E>,
{
    fn into_pyerr(self, py: Python) -> PyResult<T> {
        self.map_err(|e| match e.into() {
            err @ HgError::IoError { .. } => {
                PyIOError::new_err(err.to_string())
            }
            HgError::UnsupportedFeature(e) => {
                FallbackError::new_err(e.to_string())
            }
            HgError::RaceDetected(_) => {
                unreachable!("must not surface to the user")
            }
            HgError::Path(path_error) => {
                let msg = PyBytes::new(py, path_error.to_string().as_bytes());
                let cls = py
                    .import(intern!(py, "mercurial.error"))
                    .and_then(|m| m.getattr(intern!(py, "InputError")))
                    .expect("failed to import InputError");
                PyErr::from_value(
                    cls.call1((msg,))
                        .expect("initializing an InputError failed"),
                )
            }
            HgError::InterruptReceived => PyKeyboardInterrupt::new_err(()),
            e => PyRuntimeError::new_err(e.to_string()),
        })
    }
}

/// Wrap a call to `func` so that Python's `SIGINT` handler is first stored,
/// then restored after the call to `func` and finally raised if
/// `func` returns a [`HgError::InterruptReceived`].
///
/// We cannot use [`Python::check_signals`] because it only works from the main
/// thread of the main interpreter. To that end, long-running Rust functions
/// need to cooperate by listening to their own `SIGINT` signal and return
/// the appropriate error on catching that signal: this is especially helpful
/// in multithreaded operations.
pub fn with_sigint_wrapper<R>(
    py: Python,
    func: impl Fn() -> Result<R, HgError>,
) -> PyResult<Result<R, HgError>> {
    let signal_py_mod = py.import(intern!(py, "signal"))?;
    let sigint_py_const = signal_py_mod.getattr(intern!(py, "SIGINT"))?;
    let old_handler = signal_py_mod
        .call_method1(intern!(py, "getsignal"), (sigint_py_const.clone(),))?;
    let res = func();
    // Reset the old signal handler in Python because we may have changed it
    signal_py_mod.call_method1(
        intern!(py, "signal"),
        (sigint_py_const.clone(), old_handler),
    )?;
    if let Err(HgError::InterruptReceived) = res {
        // Trigger the signal in Python
        signal_py_mod
            .call_method1(intern!(py, "raise_signal"), (sigint_py_const,))?;
    }
    Ok(res)
}
