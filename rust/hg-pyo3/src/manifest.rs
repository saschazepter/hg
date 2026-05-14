//! Bindings for the `hg::revlog::manifest_dict` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.manifest`

use std::sync::RwLockReadGuard;

use hg::revlog::manifest_dict::LazyManifest;
use hg::revlog::manifest_dict::ManifestError;
use pyo3::Bound;
use pyo3::Py;
use pyo3::PyRef;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::exceptions::PyNotImplementedError;
use pyo3::exceptions::PyValueError;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyFunction;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3_sharedref::PyShareable;

use crate::exceptions::map_try_lock_error;
use crate::utils::PyBytesDeref;
use crate::utils::new_submodule;

/// PyO3 wrapper class for [`LazyManifest`].
#[pyclass(name = "LazyManifest", mapping, frozen)]
struct PyLazyManifest {
    inner: PyShareable<LazyManifest>,
}

#[expect(unused_variables)]
#[pymethods]
impl PyLazyManifest {
    #[new]
    fn new(nodelen: usize, data: Bound<'_, PyBytes>) -> PyResult<Self> {
        let data = PyBytesDeref::new(data.py(), data.unbind());
        let lazy_manifest = LazyManifest::new(nodelen, data).map_err(|e| {
            PyValueError::new_err(match e {
                ManifestError::UnsupportedNodeLength(length) => {
                    format!("Unsupported node length ({length} bytes)")
                }
                ManifestError::NoTrailingNewline => {
                    "Manifest did not end in a newline".to_string()
                }
                ManifestError::InvalidLine => {
                    "Invalid manifest line".to_string()
                }
                ManifestError::EmptyPath => {
                    "Manifest had an entry with a zero-length filename"
                        .to_string()
                }
                ManifestError::LineTooShort(length) => {
                    format!(
                        "Manifest had implausibly-short line ({length} bytes)"
                    )
                }
                ManifestError::NotSorted => {
                    "Manifest lines not in sorted order".to_string()
                }
            })
        })?;
        Ok(Self { inner: lazy_manifest.into() })
    }

    fn __len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_inner_read(slf, |_self_ref, inner| Ok(inner.len()))
    }

    fn __nonzero__(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_inner_read(slf, |_self_ref, inner| Ok(!inner.is_empty()))
    }

    fn __bool__(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_inner_read(slf, |_self_ref, inner| Ok(!inner.is_empty()))
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

impl PyLazyManifest {
    /// Helper to get read-only access to [`Self::inner`].
    fn with_inner_read<'py, T, F>(slf: &Bound<'py, Self>, f: F) -> PyResult<T>
    where
        F: FnOnce(
            &PyRef<'py, Self>,
            RwLockReadGuard<LazyManifest>,
        ) -> PyResult<T>,
    {
        let self_ref = slf.borrow();
        // Safety: We are the owner.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_read().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
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
