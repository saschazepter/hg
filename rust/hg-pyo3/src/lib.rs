use pyo3::prelude::*;

#[pymodule]
fn pyo3_rustext(_py: Python<'_>, _m: &PyModule) -> PyResult<()> {
    Ok(())
}
