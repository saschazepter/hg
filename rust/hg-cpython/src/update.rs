// debug.rs
//
// Copyright 2024 Mercurial developers
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Module for updating a repository.
use cpython::{PyDict, PyModule, PyObject, PyResult, Python};
use hg::{
    progress::{HgProgressBar, Progress},
    update::update_from_null,
    BaseRevision,
};

use crate::{
    exceptions::FallbackError,
    utils::{hgerror_to_pyerr, repo_from_path, with_sigint_wrapper},
};

pub fn update_from_null_fast_path(
    py: Python,
    repo_path: PyObject,
    to: BaseRevision,
    num_cpus: Option<usize>,
) -> PyResult<usize> {
    log::trace!("Using update from null fastpath");
    let repo = repo_from_path(py, repo_path)?;
    let progress: &dyn Progress = &HgProgressBar::new("updating");

    let res = with_sigint_wrapper(py, || {
        update_from_null(&repo, to.into(), progress, num_cpus)
    })?;

    hgerror_to_pyerr(py, res)
}

pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.update", package);
    let m = PyModule::new(py, dotted_name)?;

    m.add(py, "__package__", package)?;
    m.add(py, "__doc__", "Rust module for updating a repository")?;
    m.add(py, "FallbackError", py.get_type::<FallbackError>())?;
    m.add(
        py,
        "update_from_null",
        py_fn!(
            py,
            update_from_null_fast_path(
                repo_path: PyObject,
                to: BaseRevision,
                num_cpus: Option<usize>
            )
        ),
    )?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;

    Ok(m)
}
