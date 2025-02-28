use hg::{transaction::Transaction, utils::files::get_bytes_from_path};
use pyo3::{intern, types::PyBytes, PyObject, Python};

/// Wrapper around a Python transaction object, to keep `hg-core` oblivious
/// of the fact it's being called from Python.
pub struct PyTransaction {
    inner: PyObject,
}

impl PyTransaction {
    pub fn new(inner: PyObject) -> Self {
        Self { inner }
    }
}

impl Clone for PyTransaction {
    fn clone(&self) -> Self {
        Python::with_gil(|py| Self {
            inner: self.inner.clone_ref(py),
        })
    }
}

impl Transaction for PyTransaction {
    fn add(&mut self, file: impl AsRef<std::path::Path>, offset: usize) {
        Python::with_gil(|py| {
            let file = PyBytes::new(py, &get_bytes_from_path(file.as_ref()));
            self.inner
                .call_method(py, intern!(py, "add"), (file, offset), None)
                .expect("transaction add failed");
        })
    }
}
