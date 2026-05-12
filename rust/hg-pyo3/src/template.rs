use hg::template;
use pyo3::Bound;
use pyo3::IntoPyObject;
use pyo3::PyAny;
use pyo3::PyResult;
use pyo3::Python;
use pyo3::import_exception;
use pyo3::pyfunction;
use pyo3::types::PyBytes;
use pyo3::types::PyBytesMethods;
use pyo3::types::PyList;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3::types::PyTuple;
use pyo3::wrap_pyfunction;

use crate::utils::new_submodule;

import_exception!(mercurial.error, ParseError);

/// Convert a `Node` into the tuple shape that `templater.py` expects.
fn node_to_py<'py>(
    py: Python<'py>,
    node: template::Node,
) -> PyResult<Bound<'py, PyAny>> {
    match node {
        template::Node::Integer(num) => {
            bytes_pair(py, b"integer", num.to_string().as_bytes())
        }
        template::Node::Symbol(name) => {
            bytes_pair(py, b"symbol", name.as_bytes())
        }
        template::Node::Text(bytes) => bytes_pair(py, b"string", &bytes),
        template::Node::Template(chunks) => {
            let items = chunks
                .into_iter()
                .map(|c| node_to_py(py, c))
                .collect::<PyResult<Vec<_>>>()?;
            Ok(PyTuple::new(
                py,
                [
                    PyBytes::new(py, b"template").into_pyobject(py)?.into_any(),
                    PyList::new(py, items)?.into_any(),
                ],
            )?
            .into_any())
        }
    }
}

fn bytes_pair<'py>(
    py: Python<'py>,
    tag: &[u8],
    value: &[u8],
) -> PyResult<Bound<'py, PyAny>> {
    Ok(PyTuple::new(py, [PyBytes::new(py, tag), PyBytes::new(py, value)])?
        .into_any())
}

#[pyfunction]
fn parse<'py>(
    py: Python<'py>,
    tmpl: &Bound<'_, PyBytes>,
) -> PyResult<Bound<'py, PyAny>> {
    let bytes = tmpl.as_bytes();
    let s = std::str::from_utf8(bytes).map_err(|e| {
        ParseError::new_err((
            b"invalid utf-8 in template".to_vec(),
            e.valid_up_to(),
        ))
    })?;
    let node = template::parse_template(s).map_err(|err| {
        ParseError::new_err((err.message.into_bytes(), err.location))
    })?;
    node_to_py(py, node)
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "template")?;
    m.add_function(wrap_pyfunction!(parse, &m)?)?;
    Ok(m)
}
