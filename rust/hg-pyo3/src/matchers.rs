//! Bindings to the hg-core `matchers` module for Python consumption

use hg::file_patterns::FilePattern;
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
use pyo3::Bound;
use pyo3::Py;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::intern;
use pyo3::prelude::*;
use pyo3::pyclass;
use pyo3::pymethods;
use pyo3::types::PyBytes;
use pyo3::types::PyList;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;

use crate::exceptions::FallbackError;
use crate::path::paths_pyiter_collect;
use crate::utils::HgPyErrExt;
use crate::utils::new_submodule;

#[pyclass]
pub struct PyMatcher {
    inner: Box<dyn Matcher + Send>,
}

impl PyMatcher {
    pub fn new(inner: Box<dyn Matcher + Send>) -> Self {
        Self { inner }
    }
}

#[pymethods]
impl PyMatcher {
    fn __call__(&self, path: &[u8]) -> PyResult<bool> {
        Ok(self.inner.matches(HgPath::new(path)))
    }

    fn always(&self) -> bool {
        self.inner.matches_everything()
    }

    fn isexact(&self) -> bool {
        self.inner.is_exact()
    }

    fn prefix(&self) -> bool {
        // TODO might be a lie, but this is an optimization, not a guarantee
        false
    }

    fn files(&self, py: Python) -> PyResult<Py<PyList>> {
        let Some(files) = self.inner.file_set() else {
            return Ok(PyList::empty(py).unbind());
        };

        let iter = files.iter().map(|f| PyBytes::new(py, f.as_bytes()));
        Ok(PyList::new(py, iter)?.unbind())
    }
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
                .into_pyerr(py)?,
                py_pattern.cast::<PyBytes>()?.as_bytes(),
                get_path_from_bytes(py_source.cast::<PyBytes>()?.as_bytes()),
            ))
        })
        .collect()
}

pub(crate) fn extract_matcher(
    matcher: &Bound<'_, PyAny>,
) -> PyResult<Box<dyn Matcher + Send>> {
    let py = matcher.py();
    let tampered = matcher
        .call_method0(intern!(py, "was_tampered_with_nonrec"))?
        .extract::<bool>()?;
    if tampered {
        return Err(FallbackError::new_err("patternmatcher was tampered with"));
    };

    match matcher.get_type().name()?.to_str()? {
        "alwaysmatcher" => Ok(Box::new(AlwaysMatcher)),
        "nevermatcher" => Ok(Box::new(NeverMatcher)),
        "exactmatcher" => {
            let files = matcher.call_method0(intern!(py, "files"))?;
            let files: Vec<_> = paths_pyiter_collect(&files)?;
            Ok(Box::new(FileMatcher::new(files).into_pyerr(py)?))
        }
        "includematcher" => {
            // Get the patterns from Python even though most of them are
            // redundant with those we will parse later on, as they include
            // those passed from the command line.
            let file_patterns = collect_kindpats(py, matcher)?;
            Ok(Box::new(IncludeMatcher::new(file_patterns).into_pyerr(py)?))
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
            Ok(Box::new(PatternMatcher::new(patterns).into_pyerr(py)?))
        }

        m => Err(FallbackError::new_err(format!("Unsupported matcher {m}"))),
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "matchers")?;
    m.add_class::<PyMatcher>()?;
    Ok(m)
}
