//! Bindings for the `hg::revlog::manifest_dict` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.manifest`

use pyo3::Bound;
use pyo3::Py;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::exceptions::PyNotImplementedError;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyFunction;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;

use crate::utils::new_submodule;

/// PyO3 wrapper class for [`LazyManifest`].
#[pyclass(name = "LazyManifest", mapping, frozen)]
struct PyLazyManifest {
    // TODO: actually store manifest
}

#[expect(unused_variables)]
#[pymethods]
impl PyLazyManifest {
    #[new]
    fn new(nodelen: usize, data: Bound<'_, PyBytes>) -> PyResult<Self> {
        Ok(Self {})
    }

    fn __len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Err(PyNotImplementedError::new_err("LazyManifest.__len__"))
    }

    fn __nonzero__(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Err(PyNotImplementedError::new_err("LazyManifest.__nonzero__"))
    }

    fn __bool__(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Err(PyNotImplementedError::new_err("LazyManifest.__bool__"))
    }

    fn __contains__(slf: &Bound<'_, Self>, key: &[u8]) -> PyResult<bool> {
        Err(PyNotImplementedError::new_err("LazyManifest.__contains__"))
    }

    fn __iter__(slf: &Bound<'_, Self>) -> PyResult<()> {
        Err(PyNotImplementedError::new_err("LazyManifest.__iter__"))
    }

    fn iterkeys(slf: &Bound<'_, Self>) -> PyResult<()> {
        Err(PyNotImplementedError::new_err("LazyManifest.iterkeys"))
    }

    fn iterentries(slf: &Bound<'_, Self>) -> PyResult<()> {
        Err(PyNotImplementedError::new_err("LazyManifest.iterentries"))
    }

    fn __getitem__(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        key: &[u8],
    ) -> PyResult<(Py<PyBytes>, Py<PyBytes>)> {
        Err(PyNotImplementedError::new_err("LazyManifest.__getitem__"))
    }

    fn __setitem__(
        slf: &Bound<'_, Self>,
        key: &[u8],
        value: (&[u8], &[u8]),
    ) -> PyResult<()> {
        Err(PyNotImplementedError::new_err("LazyManifest.__setitem__"))
    }

    fn __delitem__(slf: &Bound<'_, Self>, key: &[u8]) -> PyResult<()> {
        Err(PyNotImplementedError::new_err("LazyManifest.__delitem__"))
    }

    fn text(slf: &Bound<'_, Self>) -> PyResult<Py<PyBytes>> {
        Err(PyNotImplementedError::new_err("LazyManifest.text"))
    }

    fn copy(slf: &Bound<'_, Self>) -> PyResult<PyLazyManifest> {
        Err(PyNotImplementedError::new_err("LazyManifest.copy"))
    }

    fn diff(
        slf: &Bound<'_, Self>,
        m2: &PyLazyManifest,
        clean: bool,
    ) -> PyResult<Py<PyDict>> {
        Err(PyNotImplementedError::new_err("LazyManifest.diff"))
    }

    fn filtercopy(
        slf: &Bound<'_, Self>,
        filterfn: &Bound<'_, PyFunction>,
    ) -> PyResult<PyLazyManifest> {
        Err(PyNotImplementedError::new_err("LazyManifest.filtercopy"))
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "manifest")?;
    m.add_class::<PyLazyManifest>()?;
    Ok(m)
}
