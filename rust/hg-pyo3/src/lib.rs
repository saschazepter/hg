use pyo3::prelude::*;

#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::fmt::format::FmtSpan;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::prelude::*;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::EnvFilter;

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
#[cfg(feature = "full-tracing")]
mod tracing;
mod transaction;
mod update;
mod utils;

#[cfg(not(feature = "full-tracing"))]
/// Enable an env-filtered logger to stderr
fn setup_tracing() {
    let registry = tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer())
        .with(EnvFilter::from_default_env());
    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_span_events(FmtSpan::CLOSE);
    registry.with(fmt_layer).init()
}

#[pymodule]
fn pyo3_rustext(py: Python<'_>, m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__package__", "mercurial")?;
    m.add(
        "__doc__",
        "Mercurial core concepts - Rust implementation exposed via PyO3",
    )?;
    let dotted_name: String = m.getattr("__name__")?.extract()?;

    m.add_submodule(&ancestors::init_module(py, &dotted_name)?)?;
    m.add_submodule(&copy_tracing::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dagops::init_module(py, &dotted_name)?)?;
    m.add_submodule(&dirstate::init_module(py, &dotted_name)?)?;
    m.add_submodule(&discovery::init_module(py, &dotted_name)?)?;
    m.add_submodule(&revlog::init_module(py, &dotted_name)?)?;
    m.add_submodule(&update::init_module(py, &dotted_name)?)?;
    #[cfg(feature = "full-tracing")]
    m.add("_chrome_tracing_guard", tracing::setup_tracing_guard())?;
    #[cfg(not(feature = "full-tracing"))]
    setup_tracing();
    m.add("GraphError", py.get_type::<exceptions::GraphError>())?;
    Ok(())
}
