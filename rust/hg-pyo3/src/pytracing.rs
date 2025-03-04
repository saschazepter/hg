use pyo3::prelude::*;
use std::sync::Mutex;
use tracing_chrome::{ChromeLayerBuilder, FlushGuard};
use tracing_subscriber::{prelude::*, EnvFilter};

/// See [`ChromeTracingGuard`]
/// Enable an env-filtered chrome-trace logger to a file.
/// Defaults to writing to `./trace-{unix epoch in micros}.json`, but can
/// be overridden via the `HG_TRACE_PATH` environment variable.
pub fn setup_tracing_guard() -> ChromeTracingGuard {
    let mut chrome_layer_builder = ChromeLayerBuilder::new();
    // /!\ Keep in sync with rhg
    if let Ok(path) = std::env::var("HG_TRACE_PATH") {
        chrome_layer_builder = chrome_layer_builder.file(path);
    }
    let (chrome_layer, chrome_layer_guard) = chrome_layer_builder.build();
    let registry =
        tracing_subscriber::registry().with(EnvFilter::from_default_env());
    let registry = registry.with(chrome_layer);
    registry.init();
    ChromeTracingGuard::new(chrome_layer_guard)
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
        Self {
            guard: Mutex::new(guard),
        }
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
