use pyo3::exceptions::{PyRuntimeError, PyValueError};
use pyo3::import_exception;
use pyo3::{create_exception, PyErr};

use crate::revision::PyRevision;

create_exception!(pyo3_rustext, GraphError, PyValueError);
import_exception!(mercurial.error, WdirUnsupported);

impl GraphError {
    pub fn from_hg(inner: hg::GraphError) -> PyErr {
        match inner {
            hg::GraphError::ParentOutOfRange(r) => {
                GraphError::new_err(("ParentOutOfRange", PyRevision(r.0)))
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
