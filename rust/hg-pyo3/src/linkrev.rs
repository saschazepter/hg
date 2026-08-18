//! Bindings for the hg-core `linkrev` module
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.linkrev`

use pyo3::Bound;
use pyo3::Py;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyModule;

use crate::exceptions::FallbackError;
use crate::matchers::extract_matcher;
use crate::repo::repo_from_path;
use crate::utils::HgPyErrExt;
use crate::utils::new_submodule;

/// Returns a map of filepath to filenode to link rev for files that `matcher`
/// matches.
#[pyfunction]
fn compute_file_link_revs(
    py: Python,
    repo_path: &Bound<'_, PyBytes>,
    matcher: &Bound<'_, PyAny>,
) -> PyResult<Py<PyDict>> {
    let matcher = extract_matcher(matcher)?;
    let repo = repo_from_path(repo_path).map_err(|err| {
        FallbackError::new_err(format!("cannot open repository: {err}"))
    })?;
    let changelog = repo.changelog().into_pyerr(py)?;
    let manifestlog = repo.manifestlog().into_pyerr(py)?;
    let link_revs =
        hg::linkrev::compute_file_link_revs(&changelog, &manifestlog, &matcher)
            .into_pyerr(py)?;

    let result = PyDict::new(py);
    for (path, nodes) in link_revs.iter() {
        let revisions = PyDict::new(py);
        for (node, revision) in nodes {
            revisions
                .set_item(PyBytes::new(py, node.as_bytes()), revision.0)?;
        }
        result.set_item(PyBytes::new(py, path.as_bytes()), revisions)?;
    }
    Ok(result.unbind())
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "linkrev")?;
    m.add("FallbackError", py.get_type::<FallbackError>())?;
    m.add_function(wrap_pyfunction!(compute_file_link_revs, &m)?)?;
    Ok(m)
}
