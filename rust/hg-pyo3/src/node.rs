use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use std::convert::Infallible;

use hg::revlog::RevlogIndex;
use hg::{
    revlog::index::Index, revlog::node::NODE_BYTES_LENGTH, Node, NodePrefix,
    Revision,
};

#[derive(Debug, Copy, Clone, PartialEq, derive_more::From)]
pub struct PyNode(pub Node);

impl<'py> IntoPyObject<'py> for PyNode {
    type Target = PyBytes;
    type Output = Bound<'py, Self::Target>;
    type Error = Infallible;

    fn into_pyobject(
        self,
        py: Python<'py>,
    ) -> Result<Self::Output, Self::Error> {
        Ok(PyBytes::new(py, self.0.as_bytes()))
    }
}

/// Copy incoming Python binary Node ID into [`Node`]
///
/// # Python exceptions
/// Raises `ValueError` if length is not as expected
pub fn node_from_py_bytes(bytes: &Bound<'_, PyBytes>) -> PyResult<Node> {
    Node::try_from(bytes.as_bytes()).map_err(|_| {
        PyValueError::new_err(format!(
            "{}-byte hash required",
            NODE_BYTES_LENGTH
        ))
    })
}

/// Convert Python hexadecimal Node ID node or prefix given as `bytes` into
/// [`NodePrefix`].
///
/// # Python exceptions
/// Raises `ValueError` if the incoming `bytes` is invalid.
pub fn node_prefix_from_py_bytes(
    bytes: &Bound<'_, PyBytes>,
) -> PyResult<NodePrefix> {
    let as_bytes = bytes.as_bytes();
    NodePrefix::from_hex(as_bytes).map_err(|_| {
        PyValueError::new_err(format!(
            "Invalid node or prefix '{}'",
            String::from_utf8_lossy(as_bytes)
        ))
    })
}

/// Return the binary node from a checked revision
///
/// This is meant to be used on revisions already checked to exist,
/// typically obtained from a NodeTree lookup.
///
/// # Panics
/// Panics if the revision does not exist
pub fn py_node_for_rev<'py>(
    py: Python<'py>,
    idx: &Index,
    rev: Revision,
) -> Bound<'py, PyBytes> {
    PyBytes::new(py, idx.node(rev).expect("node should exist").as_bytes())
}
