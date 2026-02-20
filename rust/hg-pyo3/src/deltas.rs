use std::ops::Deref;

use hg::Revision;
use hg::revlog::deltas::estimate_combined_deltas_size;
use hg::revlog::deltas::optimize_base;
use hg::utils::filter_map_results;
use pyo3::buffer::PyBuffer;
use pyo3::prelude::*;
use pyo3::types::PyIterator;
use pyo3::types::PyList;

use crate::utils::PyBufferDeref;
use crate::utils::new_submodule;

fn get_vec_of_non_empty_chunks(
    chunks: &Bound<'_, PyList>,
) -> PyResult<Vec<PyBufferDeref>> {
    filter_map_results(
        chunks.iter().map(|b| b.extract()),
        |chunk: PyBuffer<u8>| {
            if chunk.len_bytes() == 0 {
                Ok(None)
            } else {
                Ok(Some(PyBufferDeref::new(chunk)))
            }
        },
    )
    .collect()
}

fn get_iter_of_rev_chunk_pairs<'a>(
    deltas: &Bound<'a, PyIterator>,
) -> PyResult<impl Iterator<Item = (Revision, PyBufferDeref)> + use<'a>> {
    Ok(deltas.clone().map(|t| {
        let p = t.expect("iterating over rev+chunk pairs failed");
        let rev_py =
            p.get_item(0).expect("failed to read `rev` in rev+chunk pair");
        let chunk_py =
            p.get_item(1).expect("failed to read `chunk` in rev+chunk pair");
        (
            Revision(rev_py.extract().expect("failed to convert rev to i32")),
            PyBufferDeref::new(
                chunk_py
                    .extract()
                    .expect("failed to convert chunk to PyBuffer"),
            ),
        )
    }))
}

#[pyfunction]
#[pyo3(name = "estimate_combined_deltas_size")]
fn estimate_combined_deltas_size_python(
    deltas: &Bound<'_, PyList>,
) -> PyResult<i32> {
    let chunks = get_vec_of_non_empty_chunks(deltas)?;
    Ok(match &chunks[..] {
        [] => 0,
        [single] => single.deref().len(),
        _ => estimate_combined_deltas_size(
            chunks.iter().map(|d| d.deref()).collect(),
        ),
    }
    .try_into()
    .expect("estimated size doesn't fit a i32"))
}

#[pyfunction]
#[pyo3(name = "optimize_base")]
fn optimize_base_python(
    delta: &[u8],
    next_deltas: &Bound<'_, PyIterator>,
    max_size: usize,
) -> PyResult<Option<i32>> {
    let mut deltas = get_iter_of_rev_chunk_pairs(next_deltas)?
        .filter(|t| !t.1.deref().is_empty());
    Ok(optimize_base(delta, &mut deltas, max_size).map(|r| r.0))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "deltas")?;
    m.add_function(wrap_pyfunction!(
        estimate_combined_deltas_size_python,
        &m
    )?)?;
    m.add_function(wrap_pyfunction!(optimize_base_python, &m)?)?;
    Ok(m)
}
