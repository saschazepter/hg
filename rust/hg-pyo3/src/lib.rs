use pyo3::prelude::*;

mod ancestors;
mod copy_tracing;
mod dagops;
mod dirstate;
mod discovery;
mod exceptions;
mod node;
mod path;
mod repo;
mod revision;
mod revlog;
mod store;
mod transaction;
mod update;
mod utils;

#[pymodule]
fn pyo3_rustext(py: Python<'_>, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__package__", "mercurial")?;
    m.add(
        "__doc__",
        "Mercurial core concepts - Rust implementation exposed via PyO3",
    )?;
    let dotted_name: String = m.getattr("__name__")?.extract()?;
    env_logger::init();

    m.add_submodule(&ancestors::init_module(py, &dotted_name)?)?;
    m.add_submodule(&copy_tracing::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dagops::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dirstate::init_module(py, &dotted_name)?)?;
    m.add_submodule(&discovery::init_module(py, &dotted_name)?)?;
    m.add_submodule(&revlog::init_module(py, &dotted_name)?)?;
    m.add_submodule(&update::init_module(py, &dotted_name)?)?;
    m.add("GraphError", py.get_type::<exceptions::GraphError>())?;
    Ok(())
}
