//! Bindings for the `hg::operations::annotate` module provided by the `hg-core`
//! package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.annotate`

use std::collections::hash_map::Entry;
use std::sync::Mutex;

use hg::FastHashMap;
use hg::Revision;
use hg::errors::HgError;
use hg::operations::AnnotateOptions;
use hg::operations::AnnotateOutput;
use hg::operations::ChangesetAnnotatedFile;
use hg::repo::Repo;
use hg::revlog::RevisionOrWdir;
use hg::utils::hg_path::HgPath;
use hg::utils::strings::CleanWhitespace;
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;

use crate::repo::repo_from_path;
use crate::utils::HgPyErrExt;
use crate::utils::new_submodule;

/// Replacement for a Python changectx in the annotate command.
/// With an instance `ctx`, `ctx[path]` gives you an annotated filectx.
#[pyclass(name = "ChangeCtx", frozen, mapping)]
struct PyChangeCtx {
    /// Python repository, used for getting ctx objects.
    py_repo: Py<PyAny>,
    /// Rust repository, used for the the actual annotation algorithm.
    repo: Mutex<Repo>,
    /// The changelog revision being annotated.
    revision: RevisionOrWdir,
    /// Options for [`hg::operations::annotate`].
    options: AnnotateOptions,
}

#[pymethods]
impl PyChangeCtx {
    /// Create a ctx for annotating at the given rev (None for wdir).
    #[new]
    #[pyo3(signature = (repo, rev, text, follow, diffopts))]
    #[allow(clippy::too_many_arguments)]
    fn new(
        py: Python<'_>,
        repo: Py<PyAny>,
        rev: Option<i32>,
        text: bool,
        follow: bool,
        diffopts: &Bound<'_, PyAny>,
    ) -> PyResult<Self> {
        let repo_path = repo.getattr(py, "root")?;
        let repo_path = repo_path.cast_bound(py)?;
        Ok(Self {
            py_repo: repo,
            // TODO: Make `new_repo_from_path` retain all configs from Python.
            // For now this loses them, so for example --config storage.* args
            // will be ignored when `hg::operations::annotate` reads the repo.
            repo: Mutex::new(repo_from_path(repo_path)?),
            revision: match rev {
                Some(rev) => Revision(rev).into(),
                None => RevisionOrWdir::wdir(),
            },
            options: AnnotateOptions {
                treat_binary_as_text: text,
                follow_copies: follow,
                whitespace: get_whitespace_options(diffopts)?,
            },
        })
    }

    /// Returns a [`PyFileCtx`] for the given path.
    fn __getitem__(&self, py: Python<'_>, path: &[u8]) -> PyResult<PyFileCtx> {
        let repo = self.repo.lock().expect("propagate mutex panic");
        let path = HgPath::new(path);
        let output =
            hg::operations::annotate(&repo, path, self.revision, self.options)
                .into_pyerr(py)?;
        let output = match output {
            AnnotateOutput::Text(output) => FoundAnnotateOutput::Text(output),
            AnnotateOutput::Binary => FoundAnnotateOutput::Binary,
            AnnotateOutput::NotFound => {
                return handle_not_found(&repo, self.revision, path)
                    .into_pyerr(py);
            }
        };
        let py_repo = self.py_repo.clone_ref(py);
        Ok(PyFileCtx { py_repo, options: self.options, output })
    }
}

/// Converts `mercurial.mdiff.diffopts` into `Option<CleanWhitespace>`.
fn get_whitespace_options(
    diffopts: &Bound<'_, PyAny>,
) -> PyResult<Option<CleanWhitespace>> {
    Ok(if diffopts.getattr("ignorews")?.is_truthy()? {
        Some(CleanWhitespace::All)
    } else if diffopts.getattr("ignorewsamount")?.is_truthy()? {
        Some(CleanWhitespace::Collapse)
    } else if diffopts.getattr("ignorewseol")?.is_truthy()? {
        Some(CleanWhitespace::AtEol)
    } else {
        None
    })
}

/// Like [`AnnotateOutput`] but without the `NotFound` case.
enum FoundAnnotateOutput {
    /// The result of annotating the file.
    Text(ChangesetAnnotatedFile),
    /// The file could not be annotated because it is binary.
    Binary,
}

/// Similar to `handle_not_found` in rust/rhg/src/commands/annotate.rs.
fn handle_not_found<T>(
    repo: &Repo,
    rev: RevisionOrWdir,
    path: &HgPath,
) -> Result<T, HgError> {
    Err(HgError::abort_simple(match rev.exclude_wdir() {
        Some(rev) => {
            let short = repo.changelog()?.node_from_rev(rev).short();
            format!("{path}: no such file in rev {short:x}",)
        }
        None => {
            format!("{path}: No such file or directory")
        }
    }))
}

/// Replacement for a Python filectx in the annotate command.
#[pyclass(name = "FileCtx", frozen)]
struct PyFileCtx {
    /// Python repository, used for getting ctx objects.
    py_repo: Py<PyAny>,
    /// Options that were used to compute [`Self::output`].
    options: AnnotateOptions,
    /// Result of annotating the file. We compute it up front, otherwise
    /// `isbinary` and `annotate` would have to duplicate the work of loading
    /// the file at the revision and checking if it's binary.
    output: FoundAnnotateOutput,
}

#[pymethods]
impl PyFileCtx {
    /// Returns true if the file is binary.
    fn isbinary(&self) -> bool {
        matches!(self.output, FoundAnnotateOutput::Binary)
    }

    /// Returns the precomputed annotation as a list of [`PyAnnotatedLine`].
    /// `follow` and `diffopts` must match what was passed to [`PyChangeCtx`].
    /// `skiprevs` must be `None` or an empty revset.
    /// The file must not be binary -- check [`Self::isbinary`] first.
    fn annotate<'py>(
        &self,
        py: Python<'py>,
        follow: bool,
        skiprevs: &Bound<'py, PyAny>,
        diffopts: &Bound<'py, PyAny>,
    ) -> PyResult<Vec<PyAnnotatedLine>> {
        if follow != self.options.follow_copies {
            return Err(PyValueError::new_err(
                "`follow` does not match value given to PyChangeCtx",
            ));
        }
        if get_whitespace_options(diffopts)? != self.options.whitespace {
            return Err(PyValueError::new_err(
                "`diffopts` does not match value given to PyChangeCtx",
            ));
        }
        if skiprevs.is_truthy()? {
            return Err(PyValueError::new_err(
                "rust annotate does not support skiprevs",
            ));
        }
        let ChangesetAnnotatedFile { lines, annotations } = match &self.output {
            FoundAnnotateOutput::Text(output) => output,
            FoundAnnotateOutput::Binary => {
                return Err(PyValueError::new_err("file is binary"));
            }
        };
        let py_repo = self.py_repo.bind(py);
        let mut fctx_map = FastHashMap::<RevisionOrWdir, Py<PyAny>>::default();
        let context_module = PyModule::import(py, "mercurial.context")?;
        let filectx_class = context_module.getattr("filectx")?;
        annotations
            .iter()
            .zip(lines)
            .map(|(annotation, line)| {
                Ok(PyAnnotatedLine {
                    fctx: match fctx_map.entry(annotation.revision) {
                        Entry::Occupied(entry) => entry.into_mut(),
                        Entry::Vacant(entry) => entry.insert(create_filectx(
                            &filectx_class,
                            py_repo,
                            &annotation.path,
                            annotation.revision,
                        )?),
                    }
                    .clone_ref(py),
                    lineno: annotation.line_number,
                    text: PyBytes::new(py, line).unbind(),
                })
            })
            .collect()
    }
}

/// Creates a filectx for the given path and changelog revision.
fn create_filectx(
    filectx_class: &Bound<'_, PyAny>,
    py_repo: &Bound<'_, PyAny>,
    path: &HgPath,
    changelog_revision: RevisionOrWdir,
) -> PyResult<Py<PyAny>> {
    // A filectx must have a path, and either a changeid or fileid.
    // * It's important we set changeid (via changectx below), otherwise it will
    //   lazily compute it by slow linkrev adjustment in Python.
    // * We don't set fileid because `hg::operations::annotate` doesn't return
    //   it, and it should not get accessed for any --template values anyway.
    //   (If it does get accessed, it will look it up lazily in the manifest.)
    // * We don't do `repo[rev][path]`, because that looks up the fileid in the
    //   manifest eagerly, and as just explained, we don't need it.
    let path = path.as_bytes();
    let rev = changelog_revision.exclude_wdir();
    let rev = rev.map(|rev| rev.0);
    let changectx = py_repo.get_item(rev)?;
    let kwargs = PyDict::new(filectx_class.py());
    kwargs.set_item("repo", py_repo)?;
    kwargs.set_item("path", path)?;
    kwargs.set_item("changectx", changectx)?;
    Ok(filectx_class.call((), Some(&kwargs))?.unbind())
}

/// Replacement for `mercurial.utils.dag_util.annotateline`.
#[pyclass(name = "AnnotatedLine", frozen)]
struct PyAnnotatedLine {
    /// Python filectx object for this line. We need this because -T/--template
    /// allows you to access arbitrary properties. The filectx is created with
    /// `_changectx` populated so it will not attempt to do linkrev adjustment.
    #[pyo3(get)]
    fctx: Py<PyAny>,
    /// The one-based line number in the original file.
    #[pyo3(get)]
    lineno: u32,
    /// The contents of the line, including the original line ending.
    #[pyo3(get)]
    text: Py<PyBytes>,
}

#[pymethods]
impl PyAnnotatedLine {
    /// `skip` is always false since Rust annotate does not support skiprevs.
    #[getter]
    fn skip(&self) -> bool {
        false
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "annotate")?;
    m.add("__doc__", "Annotate - Rust implementation exposed via PyO3")?;
    m.add_class::<PyChangeCtx>()?;
    m.add_class::<PyFileCtx>()?;
    m.add_class::<PyAnnotatedLine>()?;
    Ok(m)
}
