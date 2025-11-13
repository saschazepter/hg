use hg::config::Config;
use hg::repo::Repo;
use hg::utils::files::get_path_from_bytes;
use pyo3::types::PyBytes;
use pyo3::types::PyBytesMethods;
use pyo3::Bound;
use pyo3::PyResult;

use crate::utils::HgPyErrExt;

/// Get a repository from a given Python path, and bubble up any error
/// that comes up.
pub fn repo_from_path(repo_path: &Bound<'_, PyBytes>) -> PyResult<Repo> {
    // TODO make the Config a Python class and cast it here, otherwise we
    // lose CLI args and runtime overrides done in Python.
    let config = Config::load_non_repo().into_pyerr(repo_path.py())?;
    let repo = Repo::find(
        &config,
        Some(get_path_from_bytes(repo_path.as_bytes()).to_owned()),
    )
    .into_pyerr(repo_path.py())?;
    Ok(repo)
}
