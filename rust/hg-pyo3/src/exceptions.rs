use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::import_exception;
use pyo3::{create_exception, PyErr};

use hg::revlog::nodemap::NodeMapError;

use crate::revision::PyRevision;

create_exception!(pyo3_rustext, GraphError, PyValueError);
import_exception!(mercurial.error, WdirUnsupported);

impl GraphError {
    pub fn from_hg(inner: hg::GraphError) -> PyErr {
        match inner {
            hg::GraphError::ParentOutOfRange(r) => {
                GraphError::new_err(("ParentOutOfRange", PyRevision(r.0)))
            }
            hg::GraphError::ParentOutOfOrder(r) => {
                GraphError::new_err(("ParentOutOfOrder", PyRevision(r.0)))
            }
        }
    }
    pub fn from_vcsgraph(inner: vcsgraph::graph::GraphReadError) -> PyErr {
        match inner {
            vcsgraph::graph::GraphReadError::InconsistentGraphData => {
                GraphError::new_err("InconsistentGraphData")
            }
            vcsgraph::graph::GraphReadError::InvalidKey => {
                GraphError::new_err("ParentOutOfRange")
            }
            vcsgraph::graph::GraphReadError::KeyedInvalidKey(r) => {
                GraphError::new_err(("ParentOutOfRange", r))
            }
            vcsgraph::graph::GraphReadError::WorkingDirectoryUnsupported => {
                WdirUnsupported::new_err(())
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
    pyo3::import_exception!(mercurial.error, RevlogError);
}

pub fn revlog_error_from_msg(e: impl ToString) -> PyErr {
    mercurial_py_errors::RevlogError::new_err(e.to_string().into_bytes())
}

pub fn revlog_error_bare() -> PyErr {
    mercurial_py_errors::RevlogError::new_err((None::<String>,))
}

pub fn nodemap_error(err: NodeMapError) -> PyErr {
    match err {
        NodeMapError::MultipleResults => {
            mercurial_py_errors::RevlogError::new_err("")
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
