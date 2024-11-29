use pyo3::prelude::*;
use pyo3::types::PyDict;
/// Create the module, with `__package__` given from parent
///
/// According to PyO3 documentation, which links to
/// <https://github.com/PyO3/pyo3/issues/1517>, the same convoluted
/// write to sys.modules has to be made as with the `cpython` crate.
pub(crate) fn new_submodule<'py>(
    py: Python<'py>,
    package_name: &str,
    name: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let dotted_name = &format!("{}.{}", package_name, name);
    let m = PyModule::new(py, name)?;
    m.add("__package__", package_name)?;
    m.add("__doc__", "DAG operations - Rust implementation")?;

    let sys = PyModule::import(py, "sys")?;
    // according to the doc, we could make a static PyString out of
    // "modules" with the `intern!` macro, but this is used only at
    // registration so it may not be worth the effort.
    let sys_modules: Bound<'_, PyDict> = sys.getattr("modules")?.extract()?;
    sys_modules.set_item(dotted_name, &m)?;
    // Example C code (see pyexpat.c and import.c) will "give away the
    // reference", but we won't because it will be consumed once the
    // Rust PyObject is dropped.
    Ok(m)
}
