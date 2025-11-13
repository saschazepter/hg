use pyo3::prelude::*;

mod ancestors;
mod copy_tracing;
mod dagops;
mod deltas;
mod diff;
mod dirstate;
mod discovery;
mod exceptions;
mod file_index;
mod matchers;
mod node;
mod path;
mod pytracing;
mod repo;
mod revision;
mod revlog;
mod shape;
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

    m.add_submodule(&ancestors::init_module(py, &dotted_name)?)?;
    m.add_submodule(&diff::init_module(py, &dotted_name)?)?;
    m.add_submodule(&copy_tracing::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dagops::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dirstate::init_module(py, &dotted_name)?)?;
    m.add_submodule(&discovery::init_module(py, &dotted_name)?)?;
    m.add_submodule(&file_index::init_module(py, &dotted_name)?)?;
    m.add_submodule(&revlog::init_module(py, &dotted_name)?)?;
    m.add_submodule(&update::init_module(py, &dotted_name)?)?;
    m.add_submodule(&pytracing::init_module(py, &dotted_name)?)?;
    m.add_submodule(&deltas::init_module(py, &dotted_name)?)?;
    m.add_submodule(&matchers::init_module(py, &dotted_name)?)?;
    m.add_submodule(&shape::init_module(py, &dotted_name)?)?;
    m.add("GraphError", py.get_type::<exceptions::GraphError>())?;
    Ok(())
}
