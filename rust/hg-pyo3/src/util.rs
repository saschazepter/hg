use pyo3::buffer::{Element, PyBuffer};
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyDict;
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
    m.add("__doc__", "DAG operations - Rust implementation")?;

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
