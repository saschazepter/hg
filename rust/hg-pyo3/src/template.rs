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
                    anybytes(py, b"template")?,
                    PyList::new(py, items)?.into_any(),
                ],
            )?
            .into_any())
        }
        template::Node::FunctionCall { name, args } => {
            let name_node = bytes_pair(py, b"symbol", name.as_bytes())?;
            let args_node = args_to_py(py, args)?;
            Ok(PyTuple::new(
                py,
                [anybytes(py, b"func")?, name_node, args_node],
            )?
            .into_any())
        }
        template::Node::KeyValue { key, value } => {
            let key_node = bytes_pair(py, b"symbol", key.as_bytes())?;
            let value_node = node_to_py(py, *value)?;
            Ok(PyTuple::new(
                py,
                [anybytes(py, b"keyvalue")?, key_node, value_node],
            )?
            .into_any())
        }
        template::Node::Group(inner) => {
            let inner_node = node_to_py(py, *inner)?;
            Ok(PyTuple::new(py, [anybytes(py, b"group")?, inner_node])?
                .into_any())
        }
        template::Node::Unary(op, operand) => {
            let tag: &[u8] = match op {
                template::UnaryOp::Negate => b"negate",
            };
            let operand_node = node_to_py(py, *operand)?;
            Ok(PyTuple::new(py, [anybytes(py, tag)?, operand_node])?.into_any())
        }
        template::Node::Binary(op, lhs, rhs) => {
            let tag: &[u8] = match op {
                template::BinaryOp::Dot => b".",
                template::BinaryOp::Pipe => b"|",
                template::BinaryOp::List => b"%",
                template::BinaryOp::Add => b"+",
                template::BinaryOp::Sub => b"-",
                template::BinaryOp::Mul => b"*",
                template::BinaryOp::Div => b"/",
            };
            let lhs_node = node_to_py(py, *lhs)?;
            let rhs_node = node_to_py(py, *rhs)?;
            Ok(PyTuple::new(py, [anybytes(py, tag)?, lhs_node, rhs_node])?
                .into_any())
        }
    }
}

fn args_to_py<'py>(
    py: Python<'py>,
    args: Vec<template::Node>,
) -> PyResult<Bound<'py, PyAny>> {
    let mut iter = args.into_iter();
    let first = match iter.next() {
        None => return Ok(py.None().into_bound(py).into_any()),
        Some(n) => n,
    };
    let mut acc = node_to_py(py, first)?;
    for node in iter {
        let item = node_to_py(py, node)?;
        acc = PyTuple::new(py, [anybytes(py, b"list")?, acc, item])?.into_any();
    }
    Ok(acc)
}

fn anybytes<'py>(py: Python<'py>, s: &[u8]) -> PyResult<Bound<'py, PyAny>> {
    Ok(PyBytes::new(py, s).into_pyobject(py)?.into_any())
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
    let node = template::parse_template(tmpl.as_bytes()).map_err(|err| {
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
