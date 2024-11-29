use pyo3::prelude::*;

mod dagops;
mod util;

#[pymodule]
fn pyo3_rustext(py: Python<'_>, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add(
        "__doc__",
        "Mercurial core concepts - Rust implementation exposed via PyO3",
    )?;
    // the module's __name__ is pyo3_rustext, not mercurial.pyo3_rustext
    // (at least at this point).
    let name: String = m.getattr("__name__")?.extract()?;
    let dotted_name = format!("mercurial.{}", name);

    m.add_submodule(&dagops::init_module(py, &dotted_name)?)?;
    Ok(())
}
