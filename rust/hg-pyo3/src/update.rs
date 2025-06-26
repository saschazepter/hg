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
use hg::progress::HgProgressBar;
use hg::progress::Progress;
use hg::update::update_from_null as core_update_from_null;
use hg::warnings::HgWarningContext;
use hg::BaseRevision;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use crate::exceptions::FallbackError;
use crate::repo::repo_from_path;
use crate::utils::handle_warnings;
use crate::utils::new_submodule;
use crate::utils::with_sigint_wrapper;
use crate::utils::HgPyErrExt;

/// See [`core_update_from_null`].
#[pyfunction]
#[pyo3(
    signature = (repo_path, to, num_cpus, on_warnings)
)]
pub fn update_from_null(
    repo_path: &Bound<'_, PyBytes>,
    to: BaseRevision,
    num_cpus: Option<usize>,
    on_warnings: PyObject,
) -> PyResult<usize> {
    tracing::debug!("Using update from null fastpath");
    let repo = repo_from_path(repo_path)?;
    let progress: &dyn Progress = &HgProgressBar::new("updating");

    let warning_context = HgWarningContext::new();
    let res = with_sigint_wrapper(repo_path.py(), || {
        core_update_from_null(
            &repo,
            to.into(),
            progress,
            num_cpus,
            warning_context.sender(),
        )
    });
    // Handle warnings even in case of an error
    handle_warnings(
        repo_path.py(),
        warning_context,
        repo.working_directory_path(),
        on_warnings,
    )?;

    let updated = res?.into_pyerr(repo_path.py())?;

    Ok(updated)
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
