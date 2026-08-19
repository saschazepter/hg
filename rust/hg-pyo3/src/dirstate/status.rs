// status.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for the `hg::status` module provided by the
//! `hg-core` crate. From Python, this will be seen as the
//! `pyo3_rustext.dirstate.status` function.
use std::path::Path;

use hg::dirstate::status::BadMatch;
use hg::dirstate::status::DirstateStatus;
use hg::dirstate::status::StatusError;
use hg::dirstate::status::StatusOptions;
use hg::dirstate::status::StatusPath;
use hg::utils::files::get_path_from_bytes;
use hg::utils::hg_path::HgPath;
use hg::warnings::HgWarningContext;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyTuple;

use super::dirstate_map::DirstateMap;
use crate::matchers::extract_matcher;
use crate::path::PyHgPathRef;
use crate::path::paths_py_list;
use crate::utils::HgPyErrExt;
use crate::utils::hg_warnings_to_py_warnings;

fn status_path_py_list(
    py: Python,
    paths: &[StatusPath<'_>],
) -> PyResult<Py<PyList>> {
    paths_py_list(py, paths.iter().map(|item| &*item.path))
}

fn collect_bad_matches(
    py: Python,
    collection: &[(impl AsRef<HgPath>, BadMatch)],
) -> PyResult<Py<PyList>> {
    let get_error_message = |code: i32| -> String {
        // hg-pyo3 here calling the Python interpreter
        // using `os.strerror`. This seems to be equivalent and infallible
        std::io::Error::from_raw_os_error(code).to_string()
    };
    Ok(PyList::new(
        py,
        collection.iter().map(|(path, bad_match)| {
            let message = match bad_match {
                BadMatch::OsError(code) => get_error_message(*code),
                BadMatch::BadType(bad_type) => {
                    format!("unsupported file type (type is {})", bad_type)
                }
            };
            (PyHgPathRef(path.as_ref()), message)
        }),
    )?
    .unbind())
}

#[pyfunction]
#[allow(clippy::too_many_arguments)]
pub(super) fn status(
    py: Python,
    dmap: &Bound<'_, DirstateMap>,
    matcher: &Bound<'_, PyAny>,
    root_dir: &Bound<'_, PyBytes>,
    ignore_files: &Bound<'_, PyList>,
    check_exec: bool,
    list_clean: bool,
    list_ignored: bool,
    list_unknown: bool,
    collect_traversed_dirs: bool,
    empty_dirs_keep_files: bool,
) -> PyResult<Py<PyTuple>> {
    let root_dir = get_path_from_bytes(root_dir.as_bytes());

    let ignore_files: PyResult<Vec<_>> = ignore_files
        .try_iter()?
        .map(|res| {
            let ob = res?;
            let file = ob.cast::<PyBytes>()?.as_bytes();
            Ok(get_path_from_bytes(file).to_owned())
        })
        .collect();
    let ignore_files = ignore_files?;
    // The caller may call `copymap.items()` separately
    let list_copies = false;

    let after_status = |res: Result<DirstateStatus<'_>, StatusError>,
                        warnings| {
        let status_res = res.into_pyerr(py)?;
        build_response(py, status_res, warnings, root_dir)
    };

    let matcher = extract_matcher(matcher)?;

    DirstateMap::with_inner_write(dmap, |_dm_ref, mut inner| {
        inner.with_status(
            &matcher,
            root_dir.to_path_buf(),
            ignore_files,
            StatusOptions {
                check_exec,
                list_clean,
                list_ignored,
                list_unknown,
                list_copies,
                collect_traversed_dirs,
                empty_dirs_keep_files,
            },
            after_status,
        )
    })
}

fn build_response(
    py: Python,
    status_res: DirstateStatus,
    warnings: HgWarningContext,
    root_dir: &Path,
) -> PyResult<Py<PyTuple>> {
    let modified = status_path_py_list(py, &status_res.modified)?;
    let added = status_path_py_list(py, &status_res.added)?;
    let removed = status_path_py_list(py, &status_res.removed)?;
    let deleted = status_path_py_list(py, &status_res.deleted)?;
    let clean = status_path_py_list(py, &status_res.clean)?;
    let ignored = status_path_py_list(py, &status_res.ignored)?;
    let unknown = status_path_py_list(py, &status_res.unknown)?;
    let unsure = status_path_py_list(py, &status_res.unsure)?;
    let bad = collect_bad_matches(py, &status_res.bad)?;
    let empty_dirs = paths_py_list(py, status_res.empty_dirs.iter())?;
    let py_warnings = hg_warnings_to_py_warnings(py, warnings, root_dir)?;

    let response = (
        unsure,
        modified,
        added,
        removed,
        deleted,
        clean,
        ignored,
        unknown,
        py_warnings,
        bad,
        empty_dirs,
        status_res.dirty,
    );
    Ok(response.into_pyobject(py)?.into())
}
