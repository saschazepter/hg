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
use hg::errors::HgError;
use hg::file_patterns::FilePattern;
use hg::file_patterns::PatternError;
use hg::file_patterns::parse_pattern_syntax_kind;
use hg::matchers::AlwaysMatcher;
use hg::matchers::DifferenceMatcher;
use hg::matchers::FileMatcher;
use hg::matchers::IncludeMatcher;
use hg::matchers::IntersectionMatcher;
use hg::matchers::Matcher;
use hg::matchers::NeverMatcher;
use hg::matchers::PatternMatcher;
use hg::matchers::UnionMatcher;
use hg::utils::files::get_path_from_bytes;
use hg::utils::hg_path::HgPath;
use hg::warnings::HgWarningContext;
use pyo3::intern;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyTuple;

use super::dirstate_map::DirstateMap;
use crate::exceptions::FallbackError;
use crate::exceptions::to_string_value_error;
use crate::path::PyHgPathRef;
use crate::path::paths_py_list;
use crate::path::paths_pyiter_collect;
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

fn collect_kindpats(
    py: Python,
    matcher: &Bound<'_, PyAny>,
) -> PyResult<Vec<FilePattern>> {
    matcher
        .getattr(intern!(py, "_kindpats"))?
        .try_iter()?
        .map(|k| {
            let k = k?;
            let py_syntax = k.get_item(0)?;
            let py_pattern = k.get_item(1)?;
            let py_source = k.get_item(2)?;

            Ok(FilePattern::new(
                parse_pattern_syntax_kind(
                    py_syntax.cast::<PyBytes>()?.as_bytes(),
                )
                .map_err(|e| handle_fallback(StatusError::Pattern(e)))?,
                py_pattern.cast::<PyBytes>()?.as_bytes(),
                get_path_from_bytes(py_source.cast::<PyBytes>()?.as_bytes()),
            ))
        })
        .collect()
}

fn extract_matcher(
    matcher: &Bound<'_, PyAny>,
) -> PyResult<Box<dyn Matcher + Send>> {
    let py = matcher.py();
    let tampered = matcher
        .call_method0(intern!(py, "was_tampered_with_nonrec"))?
        .extract::<bool>()?;
    if tampered {
        return Err(handle_fallback(StatusError::Pattern(
            PatternError::UnsupportedSyntax(
                "Pattern matcher was tampered with!".to_string(),
            ),
        )));
    };

    match matcher.get_type().name()?.to_str()? {
        "alwaysmatcher" => Ok(Box::new(AlwaysMatcher)),
        "nevermatcher" => Ok(Box::new(NeverMatcher)),
        "exactmatcher" => {
            let files = matcher.call_method0(intern!(py, "files"))?;
            let files: Vec<_> = paths_pyiter_collect(&files)?;
            Ok(Box::new(
                FileMatcher::new(files).map_err(to_string_value_error)?,
            ))
        }
        "includematcher" => {
            // Get the patterns from Python even though most of them are
            // redundant with those we will parse later on, as they include
            // those passed from the command line.
            let file_patterns = collect_kindpats(py, matcher)?;
            Ok(Box::new(
                IncludeMatcher::new(file_patterns)
                    .map_err(|e| handle_fallback(e.into()))?,
            ))
        }
        "unionmatcher" => {
            let matchers: PyResult<Vec<_>> = matcher
                .getattr("_matchers")?
                .try_iter()?
                .map(|py_matcher| extract_matcher(&py_matcher?))
                .collect();

            Ok(Box::new(UnionMatcher::new(matchers?)))
        }
        "intersectionmatcher" => {
            let m1 = extract_matcher(&matcher.getattr("_m1")?)?;
            let m2 = extract_matcher(&matcher.getattr("_m2")?)?;
            Ok(Box::new(IntersectionMatcher::new(m1, m2)))
        }
        "differencematcher" => {
            let m1 = extract_matcher(&matcher.getattr("_m1")?)?;
            let m2 = extract_matcher(&matcher.getattr("_m2")?)?;
            Ok(Box::new(DifferenceMatcher::new(m1, m2)))
        }
        "patternmatcher" => {
            let patterns = collect_kindpats(py, matcher)?;
            Ok(Box::new(
                PatternMatcher::new(patterns)
                    .map_err(|e| handle_fallback(e.into()))?,
            ))
        }

        m => Err(FallbackError::new_err(format!("Unsupported matcher {m}"))),
    }
}

fn handle_fallback(err: StatusError) -> PyErr {
    match err {
        StatusError::Pattern(e) => {
            let as_string = e.to_string();
            tracing::debug!("Rust status fallback, see trace-level logs");
            tracing::trace!("{}", as_string);
            FallbackError::new_err(as_string)
        }
        e => to_string_value_error(HgError::from(e)),
    }
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
        let status_res = res.map_err(handle_fallback)?;
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
