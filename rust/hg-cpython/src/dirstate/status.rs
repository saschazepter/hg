// status.rs
//
// Copyright 2019, Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::status` module provided by the
//! `hg-core` crate. From Python, this will be seen as
//! `rustext.dirstate.status`.

use crate::{dirstate::DirstateMap, exceptions::FallbackError};
use cpython::{
    exc::ValueError, ObjectProtocol, PyBool, PyBytes, PyErr, PyList, PyObject,
    PyResult, PyTuple, Python, PythonObject, ToPyObject,
};
use hg::dirstate::status::{
    BadMatch, DirstateStatus, StatusError, StatusOptions, StatusPath,
};
use hg::filepatterns::{
    parse_pattern_syntax_kind, IgnorePattern, PatternError, PatternFileWarning,
};
use hg::matchers::{
    DifferenceMatcher, IntersectionMatcher, Matcher, NeverMatcher,
    PatternMatcher, UnionMatcher,
};
use hg::{
    matchers::{AlwaysMatcher, FileMatcher, IncludeMatcher},
    utils::{
        files::{get_bytes_from_path, get_path_from_bytes},
        hg_path::{HgPath, HgPathBuf},
    },
};
use std::borrow::Borrow;

fn collect_status_path_list(py: Python, paths: &[StatusPath<'_>]) -> PyList {
    collect_pybytes_list(py, paths.iter().map(|item| &*item.path))
}

/// This will be useless once trait impls for collection are added to `PyBytes`
/// upstream.
fn collect_pybytes_list(
    py: Python,
    iter: impl Iterator<Item = impl AsRef<HgPath>>,
) -> PyList {
    let list = PyList::new(py, &[]);

    for path in iter {
        list.append(
            py,
            PyBytes::new(py, path.as_ref().as_bytes()).into_object(),
        )
    }

    list
}

fn collect_bad_matches(
    py: Python,
    collection: &[(impl AsRef<HgPath>, BadMatch)],
) -> PyResult<PyList> {
    let list = PyList::new(py, &[]);

    let os = py.import("os")?;
    let get_error_message = |code: i32| -> PyResult<_> {
        os.call(
            py,
            "strerror",
            PyTuple::new(py, &[code.to_py_object(py).into_object()]),
            None,
        )
    };

    for (path, bad_match) in collection.iter() {
        let message = match bad_match {
            BadMatch::OsError(code) => get_error_message(*code)?,
            BadMatch::BadType(bad_type) => {
                format!("unsupported file type (type is {})", bad_type)
                    .to_py_object(py)
                    .into_object()
            }
        };
        list.append(
            py,
            (PyBytes::new(py, path.as_ref().as_bytes()), message)
                .to_py_object(py)
                .into_object(),
        )
    }

    Ok(list)
}

fn handle_fallback(py: Python, err: StatusError) -> PyErr {
    match err {
        StatusError::Pattern(e) => {
            let as_string = e.to_string();
            log::trace!("Rust status fallback: `{}`", &as_string);

            PyErr::new::<FallbackError, _>(py, &as_string)
        }
        e => PyErr::new::<ValueError, _>(py, e.to_string()),
    }
}

pub fn status_wrapper(
    py: Python,
    dmap: DirstateMap,
    matcher: PyObject,
    root_dir: PyObject,
    ignore_files: PyList,
    check_exec: bool,
    list_clean: bool,
    list_ignored: bool,
    list_unknown: bool,
    collect_traversed_dirs: bool,
) -> PyResult<PyTuple> {
    let bytes = root_dir.extract::<PyBytes>(py)?;
    let root_dir = get_path_from_bytes(bytes.data(py));

    let dmap: DirstateMap = dmap.to_py_object(py);
    let mut dmap = dmap.get_inner_mut(py);

    let ignore_files: PyResult<Vec<_>> = ignore_files
        .iter(py)
        .map(|b| {
            let file = b.extract::<PyBytes>(py)?;
            Ok(get_path_from_bytes(file.data(py)).to_owned())
        })
        .collect();
    let ignore_files = ignore_files?;
    // The caller may call `copymap.items()` separately
    let list_copies = false;

    let after_status = |res: Result<(DirstateStatus<'_>, _), StatusError>| {
        let (status_res, warnings) =
            res.map_err(|e| handle_fallback(py, e))?;
        build_response(py, status_res, warnings)
    };

    let matcher = extract_matcher(py, matcher)?;
    dmap.with_status(
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
}

fn collect_kindpats(
    py: Python,
    matcher: PyObject,
) -> PyResult<Vec<IgnorePattern>> {
    matcher
        .getattr(py, "_kindpats")?
        .iter(py)?
        .map(|k| {
            let k = k?;
            let syntax = parse_pattern_syntax_kind(
                k.get_item(py, 0)?.extract::<PyBytes>(py)?.data(py),
            )
            .map_err(|e| handle_fallback(py, StatusError::Pattern(e)))?;
            let pattern = k.get_item(py, 1)?.extract::<PyBytes>(py)?;
            let pattern = pattern.data(py);
            let source = k.get_item(py, 2)?.extract::<PyBytes>(py)?;
            let source = get_path_from_bytes(source.data(py));
            let new = IgnorePattern::new(syntax, pattern, source);
            Ok(new)
        })
        .collect()
}

/// Transform a Python matcher into a Rust matcher.
fn extract_matcher(
    py: Python,
    matcher: PyObject,
) -> PyResult<Box<dyn Matcher + Sync>> {
    let tampered = matcher
        .call_method(py, "was_tampered_with_nonrec", PyTuple::empty(py), None)?
        .extract::<PyBool>(py)?
        .is_true();
    if tampered {
        return Err(handle_fallback(
            py,
            StatusError::Pattern(PatternError::UnsupportedSyntax(
                "Pattern matcher was tampered with!".to_string(),
            )),
        ));
    };
    match matcher.get_type(py).name(py).borrow() {
        "alwaysmatcher" => Ok(Box::new(AlwaysMatcher)),
        "nevermatcher" => Ok(Box::new(NeverMatcher)),
        "exactmatcher" => {
            let files = matcher.call_method(
                py,
                "files",
                PyTuple::new(py, &[]),
                None,
            )?;
            let files: PyList = files.cast_into(py)?;
            let files: PyResult<Vec<HgPathBuf>> = files
                .iter(py)
                .map(|f| {
                    Ok(HgPathBuf::from_bytes(
                        f.extract::<PyBytes>(py)?.data(py),
                    ))
                })
                .collect();

            let files = files?;
            let file_matcher = FileMatcher::new(files)
                .map_err(|e| PyErr::new::<ValueError, _>(py, e.to_string()))?;
            Ok(Box::new(file_matcher))
        }
        "includematcher" => {
            // Get the patterns from Python even though most of them are
            // redundant with those we will parse later on, as they include
            // those passed from the command line.
            let ignore_patterns = collect_kindpats(py, matcher)?;

            let matcher = IncludeMatcher::new(ignore_patterns)
                .map_err(|e| handle_fallback(py, e.into()))?;

            Ok(Box::new(matcher))
        }
        "unionmatcher" => {
            let matchers: PyResult<Vec<_>> = matcher
                .getattr(py, "_matchers")?
                .iter(py)?
                .map(|py_matcher| extract_matcher(py, py_matcher?))
                .collect();

            Ok(Box::new(UnionMatcher::new(matchers?)))
        }
        "intersectionmatcher" => {
            let m1 = extract_matcher(py, matcher.getattr(py, "_m1")?)?;
            let m2 = extract_matcher(py, matcher.getattr(py, "_m2")?)?;

            Ok(Box::new(IntersectionMatcher::new(m1, m2)))
        }
        "differencematcher" => {
            let m1 = extract_matcher(py, matcher.getattr(py, "_m1")?)?;
            let m2 = extract_matcher(py, matcher.getattr(py, "_m2")?)?;

            Ok(Box::new(DifferenceMatcher::new(m1, m2)))
        }
        "patternmatcher" => {
            let patterns = collect_kindpats(py, matcher)?;

            let matcher = PatternMatcher::new(patterns)
                .map_err(|e| handle_fallback(py, e.into()))?;

            Ok(Box::new(matcher))
        }
        e => Err(PyErr::new::<FallbackError, _>(
            py,
            format!("Unsupported matcher {}", e),
        )),
    }
}

fn build_response(
    py: Python,
    status_res: DirstateStatus,
    warnings: Vec<PatternFileWarning>,
) -> PyResult<PyTuple> {
    let modified = collect_status_path_list(py, &status_res.modified);
    let added = collect_status_path_list(py, &status_res.added);
    let removed = collect_status_path_list(py, &status_res.removed);
    let deleted = collect_status_path_list(py, &status_res.deleted);
    let clean = collect_status_path_list(py, &status_res.clean);
    let ignored = collect_status_path_list(py, &status_res.ignored);
    let unknown = collect_status_path_list(py, &status_res.unknown);
    let unsure = collect_status_path_list(py, &status_res.unsure);
    let bad = collect_bad_matches(py, &status_res.bad)?;
    let traversed = collect_pybytes_list(py, status_res.traversed.iter());
    let dirty = status_res.dirty.to_py_object(py);
    let py_warnings = PyList::new(py, &[]);
    for warning in warnings.iter() {
        // We use duck-typing on the Python side for dispatch, good enough for
        // now.
        match warning {
            PatternFileWarning::InvalidSyntax(file, syn) => {
                py_warnings.append(
                    py,
                    (
                        PyBytes::new(py, &get_bytes_from_path(file)),
                        PyBytes::new(py, syn),
                    )
                        .to_py_object(py)
                        .into_object(),
                );
            }
            PatternFileWarning::NoSuchFile(file) => py_warnings.append(
                py,
                PyBytes::new(py, &get_bytes_from_path(file)).into_object(),
            ),
        }
    }

    Ok(PyTuple::new(
        py,
        &[
            unsure.into_object(),
            modified.into_object(),
            added.into_object(),
            removed.into_object(),
            deleted.into_object(),
            clean.into_object(),
            ignored.into_object(),
            unknown.into_object(),
            py_warnings.into_object(),
            bad.into_object(),
            traversed.into_object(),
            dirty.into_object(),
        ][..],
    ))
}
