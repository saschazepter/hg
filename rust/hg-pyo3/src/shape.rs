//! Bindings to the hg-core `narrow::shape` module for Python consumption

use std::path::Path;

use hg::file_patterns::FilePattern;
use hg::file_patterns::PatternSyntax;
use hg::file_patterns::parse_one_pattern;
use hg::narrow::shape::SHAPES_FILE;
use hg::narrow::shape::Shape;
use hg::narrow::shape::ShardTreeNode;
use hg::narrow::shape::StoreShards;
use hg::utils::hg_path::HgPathBuf;
use hg::utils::strings::SliceExt;
use pyo3::Bound;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyModule;
use pyo3::types::PySet;

use crate::matchers::PyMatcher;
use crate::repo::repo_from_path;
use crate::utils::HgPyErrExt;
use crate::utils::new_submodule;

/// A Rust-backed Shape object that corresponds to a shard marked as a shape
/// in the `.hg/store/server-shapes` config.
#[pyclass(frozen, name = "Shape")]
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
    pub fn matcher(&self) -> PyMatcher {
        PyMatcher::new(Box::new(self.inner.matcher()))
    }

    /// The patterns as expected by legacy narrow code, i.e. a tuple of lists
    /// of file patterns.
    pub fn patterns(&self, py: Python) -> PyNarrowPatterns {
        let (includes, excludes) = self.inner.patterns();
        patterns_to_python(py, includes, excludes)
    }

    /// Serialize this shape for use in the wireprotocol
    pub fn serialized(&self, py: Python) -> PyResult<Py<PyBytes>> {
        PyBytes::new_with_writer(py, 0, |writer| {
            Ok(self.inner.serialize(writer)?)
        })
        .map(|b| b.unbind())
    }
}

fn patterns_to_python(
    py: Python,
    includes: Vec<HgPathBuf>,
    excludes: Vec<HgPathBuf>,
) -> PyNarrowPatterns {
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

type PyNarrowPatterns = (Vec<Py<PyBytes>>, Vec<Py<PyBytes>>);

/// A useful object to query the shapes for this repo's store
#[pyclass(frozen, name = "StoreShards")]
pub struct PyStoreShards {
    inner: StoreShards,
}

#[pymethods]
impl PyStoreShards {
    /// Return the shape of name `name`, or `None` if it doesn't exist
    pub fn shape(&self, py: Python, name: &str) -> PyResult<Option<PyShape>> {
        self.inner
            .shape(name)
            .into_pyerr(py)
            .map(|shape| shape.map(|inner| PyShape { inner }))
    }

    /// Return a [`PyList`] whose items are, for each shard in the store:
    ///   - Its standalone (hex) fingerprint, meaning without its dependencies
    ///   - Its matcher
    ///   - A boolean, that is `true` if this is the top-level shard, meaning
    ///     that it concerns Mercurial special files, i.e. the `.hg-files` shard
    pub fn sharded_bundle_info(&self, py: Python) -> PyResult<Py<PyList>> {
        let sharded = self.inner.sharded_bundle_info();
        let sharded_iter = sharded.into_iter().map(|standalone_shard| {
            (
                standalone_shard.fingerprint().to_hex_bytes(),
                PyMatcher::new(Box::new(standalone_shard.matcher())),
                standalone_shard.top_level,
            )
        });
        Ok(PyList::new(py, sharded_iter)?.unbind())
    }

    /// Return a [`PyList`] of all hexadecimal shard fingerprints for this
    /// shape, or `None` if it does not exist.
    ///
    /// See [`StoreShards::shard_fingerprints_for_shape`].
    pub fn shard_fingerprints_for_shape(
        &self,
        py: Python,
        name: &str,
    ) -> PyResult<Option<Py<PyList>>> {
        let groups = self.inner.shard_fingerprints_for_shape(name);
        let Some(groups) = groups.into_pyerr(py)? else {
            return Ok(None);
        };
        let sets: Result<Vec<_>, _> = groups
            .into_iter()
            .map(|group| {
                PySet::new(
                    py,
                    group
                        .into_iter()
                        .map(|fingerprint| fingerprint.to_hex_bytes()),
                )
            })
            .collect();
        Ok(Some(PyList::new(py, sets?)?.unbind()))
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

/// Return an object useful for querying shapes and shards for this repository
#[pyfunction]
pub fn get_store_shards(repo_path: &Bound<PyBytes>) -> PyResult<PyStoreShards> {
    let repo = repo_from_path(repo_path)?;
    let inner =
        StoreShards::from_repo_config(&repo).into_pyerr(repo_path.py())?;
    Ok(PyStoreShards { inner })
}

/// Same as `get_store_shards` but directly from bytes instead of from file.
/// Used to validate a requested update to `server-shapes`.
#[pyfunction]
pub fn get_store_shards_from_bytes(
    data: &Bound<PyBytes>,
) -> PyResult<PyStoreShards> {
    let inner =
        StoreShards::from_bytes(data.as_bytes()).into_pyerr(data.py())?;
    Ok(PyStoreShards { inner })
}

#[pyfunction]
fn deserialize(py: Python, serialized: &[u8]) -> PyResult<PyNarrowPatterns> {
    let (includes, excludes) =
        ShardTreeNode::deserialize(serialized).into_pyerr(py)?;
    Ok(patterns_to_python(py, includes, excludes))
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
    m.add("SHAPES_FILE", PyBytes::new(py, SHAPES_FILE.as_bytes()))?;
    m.add_class::<PyShape>()?;
    m.add_class::<PyStoreShards>()?;
    m.add_function(wrap_pyfunction!(get_store_shards, &m)?)?;
    m.add_function(wrap_pyfunction!(get_store_shards_from_bytes, &m)?)?;
    m.add_function(wrap_pyfunction!(fingerprint_for_patterns, &m)?)?;
    m.add_function(wrap_pyfunction!(deserialize, &m)?)?;

    Ok(m)
}
