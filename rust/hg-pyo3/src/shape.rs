//! Bindings to the hg-core `narrow::shape` module for Python consumption

use std::path::Path;

use hg::file_patterns::parse_one_pattern;
use hg::file_patterns::FilePattern;
use hg::file_patterns::PatternSyntax;
use hg::narrow::shape::Shape;
use hg::narrow::shape::ShardSet;
use hg::narrow::shape::ShardTreeNode;
use hg::utils::files::get_path_from_bytes;
use hg::utils::strings::SliceExt;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyModule;
use pyo3::types::PySet;
use pyo3::Bound;
use pyo3::PyResult;
use pyo3::Python;

use crate::matchers::PyMatcher;
use crate::repo::repo_from_path;
use crate::utils::new_submodule;
use crate::utils::HgPyErrExt;

/// A Rust-backed Shape object that corresponds to a shard marked as a shape
/// in the `.hg/store/server-shapes` config.
#[pyclass(frozen)]
pub struct PyShape {
    inner: Shape,
}

#[pymethods]
impl PyShape {
    /// The name of this shape as a UTF-8 string
    pub fn name(&self) -> String {
        self.inner.name().to_string()
    }

    /// The fingerprint of this shape as hexadecimal bytes
    pub fn fingerprint(&self) -> Vec<u8> {
        self.inner.store_fingerprint().to_hex_bytes()
    }

    /// A matcher for the files that this shape covers
    pub fn matcher(&self, root_path: &[u8]) -> PyMatcher {
        let root_path = get_path_from_bytes(root_path);
        PyMatcher::new(self.inner.matcher(root_path))
    }

    /// The patterns as expected by legacy narrow code, i.e. a tuple of lists
    /// of file patterns.
    pub fn patterns(&self, py: Python) -> (Vec<Py<PyBytes>>, Vec<Py<PyBytes>>) {
        let (includes, excludes) = self.inner.patterns();
        (
            includes
                .iter()
                .map(|path| PyBytes::new(py, path.as_bytes()).unbind())
                .collect(),
            excludes
                .iter()
                .map(|path| PyBytes::new(py, path.as_bytes()).unbind())
                .collect(),
        )
    }
}

/// A useful object to query the shapes for this repo's store
#[pyclass(frozen)]
pub struct PyShardSet {
    inner: ShardSet,
}

#[pymethods]
impl PyShardSet {
    /// Return the shape of name `name`, or `None` if it doesn't exist
    pub fn shape(&self, py: Python, name: &str) -> PyResult<Option<PyShape>> {
        self.inner
            .shape(name)
            .into_pyerr(py)
            .map(|shape| shape.map(|inner| PyShape { inner }))
    }

    /// Return a list of all known shapes
    pub fn all_shapes(&self, py: Python) -> PyResult<Py<PyList>> {
        let shapes_iter = self
            .inner
            .all_shapes()
            .into_pyerr(py)?
            .into_iter()
            .map(|shape| PyShape { inner: shape });
        Ok(PyList::new(py, shapes_iter)?.unbind())
    }
}

/// Return the shardset for this repository
#[pyfunction]
pub fn get_shardset(repo_path: &Bound<PyBytes>) -> PyResult<PyShardSet> {
    let repo = repo_from_path(repo_path)?;
    let shard_set =
        ShardSet::from_repo_config(&repo).into_pyerr(repo_path.py())?;
    Ok(PyShardSet { inner: shard_set })
}

/// Return the fingerprint for the given include and exclude patterns. Returns
/// `None` if we're unable to get a fingerprint.
#[pyfunction]
fn fingerprint_for_patterns(
    include_pats: &Bound<'_, PySet>,
    exclude_pats: &Bound<'_, PySet>,
) -> PyResult<Option<Vec<u8>>> {
    let transform = |pat: Bound<'_, PyAny>| {
        let pat = pat
            .extract::<&[u8]>()
            .expect("should be bytes")
            .strip_prefix(b"path:");
        if let Some(pat) = pat {
            Ok(parse_one_pattern(
                pat,
                Path::new(""),
                PatternSyntax::Path,
                false,
            ))
        } else {
            Err(())
        }
    };
    let includes: Result<Vec<FilePattern>, ()> =
        include_pats.iter().map(transform).collect();
    let excludes: Result<Vec<FilePattern>, ()> =
        exclude_pats.iter().map(transform).collect();
    let (Ok(includes), Ok(excludes)) = (includes, excludes) else {
        return Ok(None);
    };
    // Any error means we can't get a fingerprint for these patterns
    let maybe_node = ShardTreeNode::from_patterns(&includes, &excludes).ok();
    Ok(maybe_node.map(|node| node.fingerprint().to_hex_bytes()))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "shape")?;
    m.add_class::<PyShape>()?;
    m.add_class::<PyShardSet>()?;
    m.add_function(wrap_pyfunction!(get_shardset, &m)?)?;
    m.add_function(wrap_pyfunction!(fingerprint_for_patterns, &m)?)?;

    Ok(m)
}
