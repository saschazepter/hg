//! Bindings to the hg-core `matchers` module for Python consumption

use hg::matchers::Matcher;
use hg::utils::hg_path::HgPath;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3::Bound;
use pyo3::PyResult;
use pyo3::Python;

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
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "matchers")?;
    m.add_class::<PyMatcher>()?;
    Ok(m)
}
