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
use hg::update::update_from_clean as core_update_from_clean;
use hg::update::update_from_null as core_update_from_null;
use hg::update::UpdateConfig;
use hg::warnings::HgWarningContext;
use hg::BaseRevision;
use hg::Node;
use hg::Revision;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use crate::exceptions::FallbackError;
use crate::repo::repo_from_path;
use crate::utils::handle_warnings;
use crate::utils::new_submodule;
use crate::utils::with_sigint_wrapper;
use crate::utils::HgPyErrExt;
use crate::utils::PyBytesDeref;

/// See [`core_update_from_null`].
#[pyfunction]
#[pyo3(
    signature = (repo_path, to, num_cpus, on_warnings, devel_abort_dirstate)
)]
pub fn update_from_null(
    repo_path: &Bound<'_, PyBytes>,
    to: BaseRevision,
    num_cpus: Option<usize>,
    on_warnings: PyObject,
    devel_abort_dirstate: bool,
) -> PyResult<usize> {
    tracing::debug!("Using update from null fastpath");
    let repo = repo_from_path(repo_path)?;
    let progress: &dyn Progress = &HgProgressBar::new("updating");

    let update_config = UpdateConfig {
        workers: num_cpus,
        remove_empty_dirs: false,
        devel_abort_dirstate,
        orig_backup_path: None,
        atomic_file: false,
    };

    let warning_context = HgWarningContext::new();
    let res = with_sigint_wrapper(repo_path.py(), || {
        core_update_from_null(
            &repo,
            to.into(),
            progress,
            &update_config,
            warning_context.sender(),
        )
        .map(|stats| stats.updated)
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

#[pyfunction]
#[allow(clippy::too_many_arguments)]
#[pyo3(signature = (
    repo_path,
    wc_manifest_bytes,
    target_node,
    target_rev,
    target_manifest_bytes,
    num_cpus,
    remove_empty_dirs,
    devel_abort_dirstate,
    orig_backup_path,
    atomic_file,
    on_warnings,
))]
pub fn update_from_clean(
    repo_path: &Bound<'_, PyBytes>,
    wc_manifest_bytes: Py<PyBytes>,
    target_node: &[u8],
    target_rev: BaseRevision,
    target_manifest_bytes: Py<PyBytes>,
    num_cpus: Option<usize>,
    remove_empty_dirs: bool,
    devel_abort_dirstate: bool,
    orig_backup_path: Option<&[u8]>,
    atomic_file: bool,
    on_warnings: PyObject,
) -> PyResult<(usize, usize, usize, usize)> {
    tracing::debug!("Using update from clean fastpath");
    let repo = repo_from_path(repo_path)?;
    let progress: &dyn Progress = &HgProgressBar::new("updating");
    let py = repo_path.py();
    let update_config = UpdateConfig {
        workers: num_cpus,
        remove_empty_dirs,
        devel_abort_dirstate,
        orig_backup_path: orig_backup_path.map(ToOwned::to_owned),
        atomic_file,
    };
    let warning_context = HgWarningContext::new();

    let res = with_sigint_wrapper(py, || {
        core_update_from_clean(
            &repo,
            Box::new(PyBytesDeref::new(py, wc_manifest_bytes)),
            Node::try_from(target_node).expect("invalid node"),
            // We assume that Python doesn't give the wrong revision
            Revision(target_rev),
            Box::new(PyBytesDeref::new(py, target_manifest_bytes)),
            progress,
            &update_config,
            warning_context.sender(),
        )
    });
    // Handle warnings even in case of an error
    handle_warnings(
        py,
        warning_context,
        repo.working_directory_path(),
        on_warnings,
    )?;

    let merge_stats = res?.into_pyerr(repo_path.py())?;

    Ok((
        merge_stats.updated,
        merge_stats.merged,
        merge_stats.removed,
        merge_stats.unresolved,
    ))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "update")?;
    m.add("FallbackError", py.get_type::<FallbackError>())?;
    m.add_function(wrap_pyfunction!(update_from_null, &m)?)?;
    m.add_function(wrap_pyfunction!(update_from_clean, &m)?)?;
    Ok(m)
}
