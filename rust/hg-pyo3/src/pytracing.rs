#[cfg(feature = "full-tracing")]
use full_tracing::setup_tracing_guard;
#[cfg(feature = "full-tracing")]
use full_tracing::PyTracing;
use pyo3::prelude::*;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::fmt::format::FmtSpan;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::prelude::*;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::EnvFilter;

use crate::utils::new_submodule;

#[cfg(not(feature = "full-tracing"))]
/// Enable an env-filtered logger to stderr
fn setup_tracing() {
    let registry =
        tracing_subscriber::registry().with(EnvFilter::from_default_env());
    let fmt_layer = tracing_subscriber::fmt::layer()
        .with_writer(std::io::stderr)
        .with_span_events(FmtSpan::CLOSE);
    registry.with(fmt_layer).init()
}

#[cfg(feature = "full-tracing")]
mod full_tracing {
    use std::sync::Mutex;
    use std::sync::OnceLock;

    use dashmap::DashMap;
    use pyo3::prelude::*;
    use pyo3::types::PyTuple;
    use tracing::field::Field;
    use tracing::field::Visit;
    use tracing::span::Attributes;
    use tracing::span::Id;
    use tracing::Subscriber;
    use tracing_chrome::ChromeLayerBuilder;
    use tracing_chrome::EventOrSpan;
    use tracing_chrome::FlushGuard;
    use tracing_subscriber::layer::Context;
    use tracing_subscriber::layer::SubscriberExt as _;
    use tracing_subscriber::registry::LookupSpan;
    use tracing_subscriber::util::SubscriberInitExt as _;
    use tracing_subscriber::EnvFilter;
    use tracing_subscriber::Layer;

    /// A span target name to mark those from Python
    pub const PYTHON_TARGET_NAME: &str = "from_python";

    /// A mapping of span ids to user-facing trace names.
    /// See [`PyTracingLayer`] for more info.
    static ID_TO_NAMES: OnceLock<DashMap<u64, String>> = OnceLock::new();

    /// A Python front-end singleton to hook into the Rust tracing system,
    /// so that all traces are collected in a single place.
    #[pyclass]
    pub struct PyTracing;

    #[pymethods]
    impl PyTracing {
        /// Returns a context manager that will correspond to a span `name`
        /// with level `debug`
        pub fn span(&self, name: &str) -> PyTracingSpan {
            let span = tracing::debug_span!(
                target: PYTHON_TARGET_NAME,
                "", // The name is useless in this context anyway
                py_actual_name = name
            );
            PyTracingSpan::new(TracingSpanState::Created(span))
        }
    }

    /// A simple context manager that corresponds to a tracing span created
    /// from a Python context.
    #[pyclass(unsendable)]
    pub struct PyTracingSpan {
        inner: Option<TracingSpanState>,
    }

    impl PyTracingSpan {
        pub fn new(inner: TracingSpanState) -> Self {
            Self { inner: Some(inner) }
        }
    }

    #[pymethods]
    impl PyTracingSpan {
        fn __enter__(&mut self) -> PyResult<()> {
            if let Some(TracingSpanState::Created(s)) =
                std::mem::take(&mut self.inner)
            {
                let entered = TracingSpanState::Entered(s.entered());
                self.inner = Some(entered);
            }
            Ok(())
        }

        #[pyo3(signature = (*_args))]
        fn __exit__(&mut self, _args: &Bound<'_, PyTuple>) {
            if let Some(TracingSpanState::Entered(s)) =
                std::mem::take(&mut self.inner)
            {
                s.exit();
            }
        }
    }

    /// See [`ChromeTracingGuard`]
    /// Enable an env-filtered chrome-trace logger to a file.
    /// Defaults to writing to `./trace-{unix epoch in micros}.json`, but can
    /// be overridden via the `HG_TRACE_PATH` environment variable.
    pub fn setup_tracing_guard() -> ChromeTracingGuard {
        // Expect that if any events are recorded, we probably are going to
        // record a few. 16 is pretty arbitrary, but seems like a good
        // balance between not re-sizing for most cases and not
        // over-provisioning.
        ID_TO_NAMES.get_or_init(|| DashMap::with_capacity(16));
        let mut chrome_layer_builder =
            ChromeLayerBuilder::new().name_fn(Box::new(|event_or_span| {
                match event_or_span {
                    EventOrSpan::Event(ev) => ev.metadata().name().into(),
                    EventOrSpan::Span(span_ref) => {
                        if span_ref.metadata().target() != PYTHON_TARGET_NAME {
                            // Not a Python span, it has the correct name
                            span_ref.name().into()
                        } else {
                            let id = span_ref.id();
                            ID_TO_NAMES
                                .get()
                                .expect("ID_TO_NAMES should exist")
                                .get(&id.into_u64())
                                .map(|r| r.value().to_string())
                                .unwrap_or_else(|| String::from("unknown"))
                        }
                    }
                }
            }));

        // /!\ Keep in sync with rhg
        if let Ok(path) = std::env::var("HG_TRACE_PATH") {
            chrome_layer_builder = chrome_layer_builder.file(path);
        }
        let (chrome_layer, chrome_layer_guard) = chrome_layer_builder.build();
        let registry = tracing_subscriber::registry()
            .with(PyTracingLayer)
            .with(EnvFilter::from_default_env());
        let registry = registry.with(chrome_layer);
        registry.init();
        // Send this event as soon as possible to get the reference of how much
        // time has happened since we've started tracing until the first actual
        // tracing point.
        tracing::info!(name: "tracing setup", "pyo3 chrome tracing setup done");
        ChromeTracingGuard::new(chrome_layer_guard)
    }

    /// A [`Layer`] implementation that intercepts each new [`Span`] and
    /// remembers dynamic information for those created from Python.
    ///
    /// [`tracing`] events and span have a static name (and location, etc.)
    /// which allows them to be very low overhead. We are however tracing from
    /// Python, which (of course) has no way of statically communicating
    /// its names when compiling the Rust code. Thus, we keep track of all
    /// spans and their dynamic names to map each span id to its name upon
    /// writing to the trace.
    pub struct PyTracingLayer;

    impl<S> Layer<S> for PyTracingLayer
    where
        S: Subscriber,
        S: for<'lookup> LookupSpan<'lookup>,
    {
        fn on_new_span(
            &self,
            attrs: &Attributes<'_>,
            id: &Id,
            _ctx: Context<'_, S>,
        ) {
            let mut visitor = PyTracingVisitor::new(id.into_u64());
            attrs.values().record(&mut visitor);
        }
    }

    /// A simple [`Visit`] implementation that inserts only Python-created
    /// events in [`ID_TO_NAMES`].
    struct PyTracingVisitor {
        id: u64,
    }

    impl PyTracingVisitor {
        pub fn new(id: u64) -> Self {
            Self { id }
        }
    }

    impl Visit for PyTracingVisitor {
        fn record_debug(
            &mut self,
            _field: &Field,
            _value: &dyn std::fmt::Debug,
        ) {
            // Do nothing
        }
        fn record_str(&mut self, field: &Field, value: &str) {
            if field.name() == "py_actual_name" {
                // This will only be called from the main thread because we
                // filter out non-Python events
                ID_TO_NAMES
                    .get()
                    .expect("ID_TO_NAMES should exist")
                    .insert(self.id, value.to_string());
            }
        }
    }

    /// Keeps track of the current state of the span.
    /// There is no state for "exited" because that simply means
    /// it's been dropped.
    pub enum TracingSpanState {
        /// The span has only been create, but not yet entered
        Created(tracing::Span),
        /// The span has been entered
        Entered(tracing::span::EnteredSpan),
    }

    /// A Python object whose entire purpose is to keep the [`FlushGuard`] for
    /// tracing purposes, flushing to the trace file when dropped by
    /// the Python process finishing.
    #[pyclass]
    pub struct ChromeTracingGuard {
        guard: Mutex<FlushGuard>,
    }

    impl ChromeTracingGuard {
        fn new(guard: FlushGuard) -> Self {
            Self { guard: Mutex::new(guard) }
        }
    }

    impl Drop for ChromeTracingGuard {
        fn drop(&mut self) {
            self.guard
                .try_lock()
                .map(|guard| {
                    guard.flush();
                })
                .ok();
        }
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "tracing")?;
    #[cfg(feature = "full-tracing")]
    m.add("tracer", PyTracing)?;
    #[cfg(feature = "full-tracing")]
    m.add("_chrome_tracing_guard", setup_tracing_guard())?;
    #[cfg(not(feature = "full-tracing"))]
    setup_tracing();
    Ok(m)
}
