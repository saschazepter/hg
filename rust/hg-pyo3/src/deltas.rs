use std::ops::Deref;

use hg::revlog::deltas::estimate_combined_deltas_size;
use hg::utils::filter_map_results;
use pyo3::buffer::PyBuffer;
use pyo3::prelude::*;
use pyo3::types::PyList;

use crate::utils::new_submodule;
use crate::utils::PyBufferDeref;

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

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "deltas")?;
    m.add_function(wrap_pyfunction!(
        estimate_combined_deltas_size_python,
        &m
    )?)?;
    Ok(m)
}
