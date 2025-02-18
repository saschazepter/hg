use hg::{config::Config, repo::Repo, utils::files::get_path_from_bytes};
use pyo3::{
    types::{PyBytes, PyBytesMethods},
    Bound, PyResult,
};

use crate::utils::HgPyErrExt;

/// Get a repository from a given [`PyObject`] path, and bubble up any error
/// that comes up.
pub fn repo_from_path(repo_path: &Bound<'_, PyBytes>) -> PyResult<Repo> {
    // TODO make the Config a Python class and downcast it here, otherwise we
    // lose CLI args and runtime overrides done in Python.
    let config = Config::load_non_repo().into_pyerr(repo_path.py())?;
    let repo = Repo::find(
        &config,
        Some(get_path_from_bytes(repo_path.as_bytes()).to_owned()),
    )
    .into_pyerr(repo_path.py())?;
    Ok(repo)
}
