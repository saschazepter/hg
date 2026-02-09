//! Bindings to the hg-core `matchers` module for Python consumption

use hg::matchers::Matcher;
use hg::utils::hg_path::HgPath;
use pyo3::Bound;
use pyo3::Py;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;

use crate::utils::new_submodule;

#[pyclass]
pub struct PyMatcher {
    inner: Box<dyn Matcher + Send>,
}

impl PyMatcher {
    pub fn new(inner: Box<dyn Matcher + Send>) -> Self {
        Self { inner }
    }
}

#[pymethods]
impl PyMatcher {
    fn __call__(&self, path: &[u8]) -> PyResult<bool> {
        Ok(self.inner.matches(HgPath::new(path)))
    }

    fn always(&self) -> bool {
        self.inner.matches_everything()
    }

    fn isexact(&self) -> bool {
        self.inner.is_exact()
    }

    fn prefix(&self) -> bool {
        // TODO might be a lie, but this is an optimization, not a guarantee
        false
    }

    fn files(&self, py: Python) -> PyResult<Py<PyList>> {
        let Some(files) = self.inner.file_set() else {
            return Ok(PyList::empty(py).unbind());
        };

        let iter = files.iter().map(|f| PyBytes::new(py, f.as_bytes()));
        Ok(PyList::new(py, iter)?.unbind())
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "matchers")?;
    m.add_class::<PyMatcher>()?;
    Ok(m)
}
