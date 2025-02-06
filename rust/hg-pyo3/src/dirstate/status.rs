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
use pyo3::intern;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyList, PyTuple};

use hg::{
    dirstate::status::{
        BadMatch, DirstateStatus, StatusError, StatusOptions, StatusPath,
    },
    filepatterns::{
        parse_pattern_syntax_kind, IgnorePattern, PatternError,
        PatternFileWarning,
    },
    matchers::{
        AlwaysMatcher, DifferenceMatcher, FileMatcher, IncludeMatcher,
        IntersectionMatcher, Matcher, NeverMatcher, PatternMatcher,
        UnionMatcher,
    },
    utils::{
        files::{get_bytes_from_path, get_path_from_bytes},
        hg_path::HgPath,
    },
};

use super::dirstate_map::DirstateMap;
use crate::{
    exceptions::{to_string_value_error, FallbackError},
    path::{paths_py_list, paths_pyiter_collect, PyHgPathRef},
};

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
        // hg-cpython here calling the Python interpreter
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
) -> PyResult<Vec<IgnorePattern>> {
    matcher
        .getattr(intern!(py, "_kindpats"))?
        .try_iter()?
        .map(|k| {
            let k = k?;
            let py_syntax = k.get_item(0)?;
            let py_pattern = k.get_item(1)?;
            let py_source = k.get_item(2)?;

            Ok(IgnorePattern::new(
                parse_pattern_syntax_kind(
                    py_syntax.downcast::<PyBytes>()?.as_bytes(),
                )
                .map_err(|e| handle_fallback(StatusError::Pattern(e)))?,
                py_pattern.downcast::<PyBytes>()?.as_bytes(),
                get_path_from_bytes(
                    py_source.downcast::<PyBytes>()?.as_bytes(),
                ),
            ))
        })
        .collect()
}

fn extract_matcher(
    matcher: &Bound<'_, PyAny>,
) -> PyResult<Box<dyn Matcher + Sync>> {
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
            let ignore_patterns = collect_kindpats(py, matcher)?;
            Ok(Box::new(
                IncludeMatcher::new(ignore_patterns)
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
            log::trace!("Rust status fallback, `{}`", &as_string);
            FallbackError::new_err(as_string)
        }
        e => to_string_value_error(e),
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
) -> PyResult<Py<PyTuple>> {
    let root_dir = get_path_from_bytes(root_dir.as_bytes());

    let ignore_files: PyResult<Vec<_>> = ignore_files
        .try_iter()?
        .map(|res| {
            let ob = res?;
            let file = ob.downcast::<PyBytes>()?.as_bytes();
            Ok(get_path_from_bytes(file).to_owned())
        })
        .collect();
    let ignore_files = ignore_files?;
    // The caller may call `copymap.items()` separately
    let list_copies = false;

    let after_status = |res: Result<(DirstateStatus<'_>, _), StatusError>| {
        let (status_res, warnings) = res.map_err(handle_fallback)?;
        build_response(py, status_res, warnings)
    };

    let matcher = extract_matcher(matcher)?;
    DirstateMap::with_inner_write(dmap, |_dm_ref, mut inner| {
        inner.with_status(
            &*matcher,
            root_dir.to_path_buf(),
            ignore_files,
            StatusOptions {
                check_exec,
                list_clean,
                list_ignored,
                list_unknown,
                list_copies,
                collect_traversed_dirs,
            },
            after_status,
        )
    })
}

fn build_response(
    py: Python,
    status_res: DirstateStatus,
    warnings: Vec<PatternFileWarning>,
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
    let traversed = paths_py_list(py, status_res.traversed.iter())?;
    let py_warnings = PyList::empty(py);
    for warning in warnings.iter() {
        // We use duck-typing on the Python side for dispatch, good enough for
        // now.
        match warning {
            PatternFileWarning::InvalidSyntax(file, syn) => {
                py_warnings.append((
                    PyBytes::new(py, &get_bytes_from_path(file)),
                    PyBytes::new(py, syn),
                ))?;
            }
            PatternFileWarning::NoSuchFile(file) => py_warnings
                .append(PyBytes::new(py, &get_bytes_from_path(file)))?,
        }
    }

    Ok((
        unsure.into_pyobject(py)?,
        modified.into_pyobject(py)?,
        added.into_pyobject(py)?,
        removed.into_pyobject(py)?,
        deleted.into_pyobject(py)?,
        clean.into_pyobject(py)?,
        ignored.into_pyobject(py)?,
        unknown.into_pyobject(py)?,
        py_warnings.into_pyobject(py)?,
        bad.into_pyobject(py)?,
        traversed.into_pyobject(py)?,
        status_res.dirty.into_pyobject(py)?,
    )
        .into_pyobject(py)?
        .into())
}
