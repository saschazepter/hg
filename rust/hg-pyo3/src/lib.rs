use pyo3::prelude::*;

#[pymodule]
fn pyo3_rustext(_py: Python<'_>, _m: &Bound<'_, PyModule>) -> PyResult<()> {
    Ok(())
}
