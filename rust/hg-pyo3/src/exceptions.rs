use hg::UncheckedRevision;
use hg::dirstate::DirstateError;
use hg::errors::HgError;
use hg::revlog::RevlogError;
use hg::revlog::nodemap::NodeMapError;
use pyo3::PyErr;
use pyo3::Python;
use pyo3::create_exception;
use pyo3::exceptions::PyRuntimeError;
use pyo3::exceptions::PyValueError;
use pyo3::import_exception;

use crate::revision::PyRevision;
use crate::utils::hg_err_to_py_err;

create_exception!(pyo3_rustext, GraphError, PyValueError);
create_exception!(pyo3_rustext, FallbackError, PyRuntimeError);
import_exception!(mercurial.error, WdirUnsupported);

impl GraphError {
    pub fn from_hg(inner: &hg::GraphError) -> PyErr {
        match inner.kind {
            hg::GraphErrorKind::ParentOutOfRange(r) => {
                GraphError::new_err(("ParentOutOfRange", PyRevision(r.0)))
            }
            hg::GraphErrorKind::ParentOutOfOrder(r) => {
                GraphError::new_err(("ParentOutOfOrder", PyRevision(r.0)))
            }
            hg::GraphErrorKind::P1OutOfRange(r) => {
                // For backwards compatibility with Python tests, to be changed
                // once revlog-v2 is more fleshed out
                GraphError::new_err(("ParentOutOfRange", PyRevision(r.0)))
            }
            hg::GraphErrorKind::P2OutOfRange(r) => {
                // For backwards compatibility with Python tests, to be changed
                // once revlog-v2 is more fleshed out
                GraphError::new_err(("ParentOutOfRange", PyRevision(r.0)))
            }
            hg::GraphErrorKind::InconsistentGraphData => {
                // For backwards compatibility with Python tests, to be changed
                // once revlog-v2 is more fleshed out
                GraphError::new_err(("InconsistentGraphData",))
            }
        }
    }
}

pub fn map_lock_error<T>(e: std::sync::PoisonError<T>) -> PyErr {
    PyRuntimeError::new_err(format!("In Rust PyO3 bindings: {e}"))
}

pub fn map_try_lock_error<T>(e: std::sync::TryLockError<T>) -> PyErr {
    PyRuntimeError::new_err(format!("In Rust PyO3 bindings: {e}"))
}

pub mod mercurial_py_errors {
    pyo3::import_exception!(mercurial.error, RustRevlogError);
    pyo3::import_exception!(mercurial.error, RevlogError);
}

pub fn revlog_error_from_io(err: impl Into<HgError>) -> PyErr {
    let hg_error = err.into();
    match hg_error {
        HgError::IO(err) => {
            mercurial_py_errors::RustRevlogError::new_err(err.to_string())
        }
        // Still handle other cases in case we're missing anything. This
        // should get cleaned up along the rest of the error refactor.
        _ => mercurial_py_errors::RevlogError::new_err(hg_error.to_string()),
    }
}

pub fn revlog_error_bare() -> PyErr {
    mercurial_py_errors::RustRevlogError::new_err(("None",))
}

pub fn revlog_error(revlog_error: RevlogError) -> PyErr {
    mercurial_py_errors::RustRevlogError::new_err(revlog_error.to_string())
}

pub fn rev_not_in_index(rev: UncheckedRevision) -> PyErr {
    PyValueError::new_err(format!("revlog index out of range: {}", rev))
}

pub fn nodemap_error(err: NodeMapError) -> PyErr {
    match err {
        NodeMapError::MultipleResults => {
            mercurial_py_errors::RustRevlogError::new_err("")
        }

        NodeMapError::RevisionNotInIndex(rev) => {
            PyValueError::new_err(format!(
                "Inconsistency: Revision {} found in nodemap \
             is not in revlog index",
                rev
            ))
        }
    }
}

pub fn graph_error(_err: hg::GraphError) -> PyErr {
    // ParentOutOfRange is currently the only alternative
    // in `hg::GraphError`. The C index always raises this simple ValueError.
    PyValueError::new_err("parent out of range")
}

pub fn dirstate_error(py: Python<'_>, err: impl Into<DirstateError>) -> PyErr {
    hg_err_to_py_err(py, err.into())
}
