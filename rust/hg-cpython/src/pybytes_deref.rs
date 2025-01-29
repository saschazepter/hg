use crate::cpython::buffer::Element;
use cpython::{
    buffer::PyBuffer, exc::ValueError, PyBytes, PyErr, PyResult, Python,
};
use stable_deref_trait::StableDeref;

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
    keep_alive: PyBytes,

    /// Borrows the buffer inside `self.keep_alive`,
    /// but the borrow-checker cannot express self-referential structs.
    data: &'static [u8],
}

impl PyBytesDeref {
    pub fn new(py: Python, bytes: PyBytes) -> Self {
        let as_raw: *const [u8] = bytes.data(py);
        Self {
            // Safety: the raw pointer is valid as long as the PyBytes is still
            // alive, and the objecs owns it.
            data: unsafe { &*as_raw },
            keep_alive: bytes,
        }
    }

    pub fn unwrap(self) -> PyBytes {
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
    require_send::<PyBytes>;
}

// Safety: PyBytes is Send. Raw pointers are not by default,
// but here sending one to another thread is fine since we ensure it stays
// valid.
unsafe impl Send for PyBytesDeref {}

///
/// It also enables using a (wrapped) `PyBuffer` in GIL-unaware generic code.
pub struct PyBufferDeref {
    #[allow(unused)]
    keep_alive: PyBuffer,

    /// Borrows the buffer inside `self.keep_alive`,
    /// but the borrow-checker cannot express self-referential structs.
    data: *const [u8],
}

fn get_buffer<'a>(py: Python, buf: &'a PyBuffer) -> PyResult<&'a [u8]> {
    let len = buf.item_count();

    let cbuf = buf.buf_ptr();
    let has_correct_item_size = std::mem::size_of::<u8>() == buf.item_size();
    let is_valid_buffer = has_correct_item_size
        && buf.is_c_contiguous()
        && u8::is_compatible_format(buf.format())
        && buf.readonly();

    let bytes = if is_valid_buffer {
        unsafe { std::slice::from_raw_parts(cbuf as *const u8, len) }
    } else {
        return Err(PyErr::new::<ValueError, _>(
            py,
            "Buffer has an invalid memory representation",
        ));
    };
    Ok(bytes)
}

impl PyBufferDeref {
    pub fn new(py: Python, buf: PyBuffer) -> PyResult<Self> {
        Ok(Self {
            data: get_buffer(py, &buf)?,
            keep_alive: buf,
        })
    }
}

impl std::ops::Deref for PyBufferDeref {
    type Target = [u8];

    fn deref(&self) -> &[u8] {
        // Safety: the raw pointer is valid as long as the PyBuffer is still
        // alive, and the returned slice borrows `self`.
        unsafe { &*self.data }
    }
}

unsafe impl StableDeref for PyBufferDeref {}

#[allow(unused)]
fn static_assert_pybuffer_is_send() {
    #[allow(clippy::no_effect)]
    require_send::<PyBuffer>;
}

// Safety: PyBuffer is Send. Raw pointers are not by default,
// but here sending one to another thread is fine since we ensure it stays
// valid.
unsafe impl Send for PyBufferDeref {}
