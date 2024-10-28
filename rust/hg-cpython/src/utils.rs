use cpython::exc::ValueError;
use cpython::{
    ObjectProtocol, PyBytes, PyDict, PyErr, PyObject, PyResult, PyTuple,
    Python, ToPyObject,
};
use hg::config::Config;
use hg::errors::HgError;
use hg::repo::{Repo, RepoError};
use hg::revlog::Node;
use hg::utils::files::get_path_from_bytes;

use crate::exceptions::FallbackError;

#[allow(unused)]
pub fn print_python_trace(py: Python) -> PyResult<PyObject> {
    eprintln!("===============================");
    eprintln!("Printing Python stack from Rust");
    eprintln!("===============================");
    let traceback = py.import("traceback")?;
    let sys = py.import("sys")?;
    let kwargs = PyDict::new(py);
    kwargs.set_item(py, "file", sys.get(py, "stderr")?)?;
    traceback.call(py, "print_stack", PyTuple::new(py, &[]), Some(&kwargs))
}

pub fn hgerror_to_pyerr<T>(
    py: Python,
    error: Result<T, HgError>,
) -> PyResult<T> {
    error.map_err(|e| match e {
        HgError::IoError { .. } => {
            PyErr::new::<cpython::exc::IOError, _>(py, e.to_string())
        }
        HgError::UnsupportedFeature(e) => {
            let as_string = e.to_string();
            log::trace!("Update from null fallback: {}", as_string);
            PyErr::new::<FallbackError, _>(py, &as_string)
        }
        HgError::RaceDetected(_) => {
            unreachable!("must not surface to the user")
        }
        HgError::Path(path_error) => {
            let msg = PyBytes::new(py, path_error.to_string().as_bytes());
            let cls = py
                .import("mercurial.error")
                .and_then(|m| m.get(py, "InputError"))
                .unwrap();
            PyErr::from_instance(
                py,
                cls.call(py, (msg,), None).ok().into_py_object(py),
            )
        }
        e => PyErr::new::<cpython::exc::RuntimeError, _>(py, e.to_string()),
    })
}

pub fn repo_error_to_pyerr<T>(
    py: Python,
    error: Result<T, RepoError>,
) -> PyResult<T> {
    hgerror_to_pyerr(py, error.map_err(HgError::from))
}

/// Get a repository from a given [`PyObject`] path, and bubble up any error
/// that comes up.
pub fn repo_from_path(py: Python, repo_path: PyObject) -> Result<Repo, PyErr> {
    let config =
        hgerror_to_pyerr(py, Config::load_non_repo().map_err(HgError::from))?;
    let py_bytes = &repo_path.extract::<PyBytes>(py)?;
    let repo_path = py_bytes.data(py);
    let repo = repo_error_to_pyerr(
        py,
        Repo::find(&config, Some(get_path_from_bytes(repo_path).to_owned())),
    )?;
    Ok(repo)
}

// Necessary evil for the time being, could maybe be moved to
// a TryFrom in Node itself
const NODE_BYTES_LENGTH: usize = 20;
type NodeData = [u8; NODE_BYTES_LENGTH];

/// Copy incoming Python bytes given as `PyObject` into `Node`,
/// doing the necessary checks
pub fn node_from_py_object<'a>(
    py: Python,
    bytes: &'a PyObject,
) -> PyResult<Node> {
    let as_py_bytes: &'a PyBytes = bytes.extract(py)?;
    node_from_py_bytes(py, as_py_bytes)
}

/// Clone incoming Python bytes given as `PyBytes` as a `Node`,
/// doing the necessary checks.
pub fn node_from_py_bytes(py: Python, bytes: &PyBytes) -> PyResult<Node> {
    <NodeData>::try_from(bytes.data(py))
        .map_err(|_| {
            PyErr::new::<ValueError, _>(
                py,
                format!("{}-byte hash required", NODE_BYTES_LENGTH),
            )
        })
        .map(Into::into)
}
