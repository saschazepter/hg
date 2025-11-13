use hg::transaction::Transaction;
use hg::utils::files::get_bytes_from_path;
use pyo3::intern;
use pyo3::types::PyBytes;
use pyo3::Py;
use pyo3::PyAny;
use pyo3::Python;

/// Wrapper around a Python transaction object, to keep `hg-core` oblivious
/// of the fact it's being called from Python.
pub struct PyTransaction {
    inner: Py<PyAny>,
}

impl PyTransaction {
    pub fn new(inner: Py<PyAny>) -> Self {
        Self { inner }
    }
}

impl Clone for PyTransaction {
    fn clone(&self) -> Self {
        Python::attach(|py| Self { inner: self.inner.clone_ref(py) })
    }
}

impl Transaction for PyTransaction {
    fn add(&mut self, file: impl AsRef<std::path::Path>, offset: usize) {
        Python::attach(|py| {
            let file = PyBytes::new(py, &get_bytes_from_path(file.as_ref()));
            self.inner
                .call_method(py, intern!(py, "add"), (file, offset), None)
                .expect("transaction add failed");
        })
    }
}
