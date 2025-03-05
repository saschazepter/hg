// update.rs
//
// Copyright 2025 Mercurial developers
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::update` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.update`
use pyo3::prelude::*;

use hg::progress::{HgProgressBar, Progress};
use hg::update::update_from_null as core_update_from_null;
use hg::BaseRevision;
use pyo3::types::PyBytes;

use crate::exceptions::FallbackError;
use crate::repo::repo_from_path;
use crate::utils::{new_submodule, with_sigint_wrapper, HgPyErrExt};

/// See [`core_update_from_null`].
#[pyfunction]
#[pyo3(signature = (repo_path, to, num_cpus))]
pub fn update_from_null(
    repo_path: &Bound<'_, PyBytes>,
    to: BaseRevision,
    num_cpus: Option<usize>,
) -> PyResult<usize> {
    log::trace!("Using update from null fastpath");
    let repo = repo_from_path(repo_path)?;
    let progress: &dyn Progress = &HgProgressBar::new("updating");

    with_sigint_wrapper(repo_path.py(), || {
        core_update_from_null(&repo, to.into(), progress, num_cpus)
    })?
    .into_pyerr(repo_path.py())
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "update")?;
    m.add("FallbackError", py.get_type::<FallbackError>())?;
    m.add_function(wrap_pyfunction!(update_from_null, &m)?)?;
    Ok(m)
}
