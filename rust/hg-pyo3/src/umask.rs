use pyo3::pyfunction;
use pyo3::types::PyModule;
use pyo3::types::PyModuleMethods;
use pyo3::wrap_pyfunction;
use pyo3::Bound;
use pyo3::PyResult;
use pyo3::Python;

use crate::utils::new_submodule;

#[pyfunction]
pub fn set_umask(mask: u32) {
    hg::vfs::set_umask(mask);
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "umask")?;
    m.add_function(wrap_pyfunction!(set_umask, &m)?)?;

    Ok(m)
}
