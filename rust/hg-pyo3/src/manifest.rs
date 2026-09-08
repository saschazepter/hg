//! Bindings for the `hg::revlog::manifest_dict` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.manifest`

use std::sync::RwLockReadGuard;
use std::sync::RwLockWriteGuard;

use hg::Node;
use hg::revlog::RevlogError;
use hg::revlog::manifest::DecodedManifestEntry;
use hg::revlog::manifest::ManifestFlags;
use hg::revlog::manifest_dict::LazyManifest;
use hg::revlog::manifest_dict::LazyManifestIter;
use hg::revlog::manifest_dict::ManifestError;
use hg::utils::hg_path::HgPath;
use pyo3::Bound;
use pyo3::IntoPyObject;
use pyo3::Py;
use pyo3::PyAny;
use pyo3::PyRef;
use pyo3::PyRefMut;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::exceptions::PyKeyError;
use pyo3::exceptions::PyTypeError;
use pyo3::exceptions::PyValueError;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyAnyMethods;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyDictMethods;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3::types::PyTuple;
use pyo3_sharedref::PyShareable;
use pyo3_sharedref::py_shared_iterator;

use crate::exceptions::map_try_lock_error;
use crate::utils::HgPyErrExt;
use crate::utils::PyBytesDeref;
use crate::utils::new_submodule;

/// PyO3 wrapper class for [`LazyManifest`].
#[pyclass(name = "LazyManifest", mapping, frozen)]
struct PyLazyManifest {
    inner: PyShareable<LazyManifest>,
}

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
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(inner.contains(HgPath::new(key)))
        })
    }

    fn __iter__(slf: &Bound<'_, Self>) -> PyResult<PyPathIter> {
        PyPathIter::new(slf)
    }

    fn iterkeys(slf: &Bound<'_, Self>) -> PyResult<PyPathIter> {
        PyPathIter::new(slf)
    }

    fn iterentries(slf: &Bound<'_, Self>) -> PyResult<PyTupleIter> {
        PyTupleIter::new(slf)
    }

    fn __getitem__(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        key: &[u8],
    ) -> PyResult<Py<PyTuple>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            let entry = inner
                .get(HgPath::new(key))
                .into_pyerr(py)?
                .ok_or_else(|| PyKeyError::new_err(key.to_vec()))?;
            Ok(node_and_flags(py, &entry)?.unbind())
        })
    }

    fn __setitem__(
        slf: &Bound<'_, Self>,
        key: &[u8],
        value: (&[u8], &[u8]),
    ) -> PyResult<()> {
        // The PyTypeErrors here match the ones in mercurial/cext/manifest.c.
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            let (node, flags) = value;
            let node: Node = node.try_into().map_err(
                |_: std::array::TryFromSliceError| {
                    PyTypeError::new_err("node must be a 20 bytes string")
                },
            )?;
            let flags = match *flags {
                [] => Some(ManifestFlags::EMPTY),
                [b] => ManifestFlags::from_byte(b),
                _ => None,
            };
            let flags = flags
                .ok_or_else(|| PyTypeError::new_err("invalid manifest flag"))?;
            let _ = inner.set(HgPath::new(key), node, flags);
            Ok(())
        })
    }

    fn __delitem__(slf: &Bound<'_, Self>, key: &[u8]) -> PyResult<()> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            let _ = inner.remove(HgPath::new(key));
            Ok(())
        })
    }

    fn text(slf: &Bound<'_, Self>) -> PyResult<Py<PyBytes>> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            Ok(PyBytes::new(slf.py(), inner.compact()).unbind())
        })
    }

    fn copy(slf: &Bound<'_, Self>) -> PyResult<PyLazyManifest> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(Self { inner: inner.clone().into() })
        })
    }

    #[pyo3(signature = (m2, clean = false))]
    fn diff(
        slf: &Bound<'_, Self>,
        m2: &Bound<'_, Self>,
        clean: bool,
    ) -> PyResult<Py<PyDict>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            // Avoid trying to take the same lock again.
            if slf.is(m2) {
                return Self::diff_inner(slf.py(), &inner, &inner, clean);
            }
            Self::with_inner_read(m2, |_m2_ref, inner2| {
                Self::diff_inner(slf.py(), &inner, &inner2, clean)
            })
        })
    }

    fn filtercopy(
        slf: &Bound<'_, Self>,
        matchfn: &Bound<'_, PyAny>,
    ) -> PyResult<PyLazyManifest> {
        if !matchfn.is_callable() {
            return Err(PyTypeError::new_err("matchfn must be callable"));
        }
        Self::with_inner_read(slf, |_self_ref, inner| {
            let inner = inner.filter(|path| {
                let path = PyBytes::new(slf.py(), path.as_bytes());
                matchfn.call1((path,))?.is_truthy()
            })?;
            Ok(Self { inner: inner.into() })
        })
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

    /// Helper to get read-write access to [`Self::inner`].
    fn with_inner_write<'py, T, F>(slf: &Bound<'py, Self>, f: F) -> PyResult<T>
    where
        F: FnOnce(
            &PyRef<'py, Self>,
            RwLockWriteGuard<LazyManifest>,
        ) -> PyResult<T>,
    {
        let self_ref = slf.borrow();
        // Safety: We are the owner.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_write().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
    }

    /// Builds the dict for [`Self::diff`].
    fn diff_inner(
        py: Python<'_>,
        m1: &LazyManifest,
        m2: &LazyManifest,
        clean: bool,
    ) -> PyResult<Py<PyDict>> {
        let dict = PyDict::new(py);
        let missing =
            (py.None(), PyBytes::new(py, ManifestFlags::EMPTY.as_bytes()))
                .into_pyobject(py)?;
        let side = |entry: Option<DecodedManifestEntry<'_>>| match entry {
            Some(entry) => node_and_flags(py, &entry),
            None => Ok(missing.clone()),
        };
        for item in m1.diff(m2, clean) {
            let (left, right) = item.into_pyerr(py)?;
            let entry = left.or(right).expect("at least one side is present");
            let key = PyBytes::new(py, entry.path.as_bytes());
            let value = if clean && left == right {
                py.None().into_bound(py)
            } else {
                (side(left)?, side(right)?).into_pyobject(py)?.into_any()
            };
            dict.set_item(key, value)?;
        }
        Ok(dict.unbind())
    }
}

py_shared_iterator!(
    PyPathIter,
    PyBytes,
    PyLazyManifest,
    inner,
    LazyManifestIter<'static>,
    |lazy_manifest| lazy_manifest.iter(),
    convert_path_iter_item
);

fn convert_path_iter_item(
    py: Python,
    item: Result<DecodedManifestEntry<'_>, RevlogError>,
) -> PyResult<Option<Py<PyBytes>>> {
    let entry = item.into_pyerr(py)?;
    Ok(Some(PyBytes::new(py, entry.path.as_bytes()).unbind()))
}

py_shared_iterator!(
    PyTupleIter,
    PyTuple,
    PyLazyManifest,
    inner,
    LazyManifestIter<'static>,
    |lazy_manifest| lazy_manifest.iter(),
    convert_tuple_iter_item
);

fn convert_tuple_iter_item(
    py: Python,
    item: Result<DecodedManifestEntry<'_>, RevlogError>,
) -> PyResult<Option<Py<PyTuple>>> {
    let entry = item.into_pyerr(py)?;
    let tuple = (
        PyBytes::new(py, entry.path.as_bytes()),
        PyBytes::new(py, entry.node.as_bytes()),
        PyBytes::new(py, entry.flags.as_bytes()),
    );
    Ok(Some(tuple.into_pyobject(py)?.unbind()))
}

/// Returns the entry's node and flags as a Python tuple.
fn node_and_flags<'py>(
    py: Python<'py>,
    entry: &DecodedManifestEntry<'_>,
) -> PyResult<Bound<'py, PyTuple>> {
    let tuple = (
        PyBytes::new(py, entry.node.as_bytes()),
        PyBytes::new(py, entry.flags.as_bytes()),
    );
    tuple.into_pyobject(py)
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "manifest")?;
    m.add_class::<PyLazyManifest>()?;
    Ok(m)
}
