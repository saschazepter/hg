use hg::revlog::manifest;
use pyo3::pyfunction;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3::wrap_pyfunction;
use pyo3::Bound;
use pyo3::PyAny;
use pyo3::PyResult;
use pyo3::Python;

use crate::utils::new_submodule;
use crate::utils::take_buffer_with_slice;

#[pyfunction]
pub fn manifest_diff(
    m1: Bound<'_, PyAny>,
    m2: Bound<'_, PyAny>,
) -> PyResult<Vec<u8>> {
    // Safety: we keep `_buf` alive for the entire existence of the slices,
    // as they are an internal detail of `manifest::manifest_delta`
    let (_buf, m1) = unsafe { take_buffer_with_slice(&m1)? };
    // Safety: same as above
    let (_buf, m2) = unsafe { take_buffer_with_slice(&m2)? };
    Ok(manifest::manifest_delta(&m1, &m2))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "diff")?;
    m.add_function(wrap_pyfunction!(manifest_diff, &m)?)?;

    Ok(m)
}
