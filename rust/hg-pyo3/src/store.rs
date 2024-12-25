// store.rs
//
// Copyright 2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use std::sync::atomic::{AtomicBool, Ordering};

use hg::{fncache::FnCache, utils::files::get_bytes_from_path};

pub struct PyFnCache {
    fncache: PyObject,
}

impl PyFnCache {
    pub fn new(fncache: PyObject) -> Self {
        Self { fncache }
    }
}

impl Clone for PyFnCache {
    fn clone(&self) -> Self {
        Python::with_gil(|py| Self {
            fncache: self.fncache.clone_ref(py),
        })
    }
}

/// Cache whether the fncache is loaded to avoid Python round-trip every time.
/// Once the fncache is loaded, it stays loaded unless we're in a very
/// long-running process, none of which we actually support for now.
static FN_CACHE_IS_LOADED: AtomicBool = AtomicBool::new(false);

// TODO perhaps a bit of magic with `Bound<'_, PyFnCache>` would spare us
// the GIL reacquisitions
impl FnCache for PyFnCache {
    fn is_loaded(&self) -> bool {
        if FN_CACHE_IS_LOADED.load(Ordering::Relaxed) {
            return true;
        }
        Python::with_gil(|py| {
            // TODO raise in case of error?
            let is_loaded = self
                .fncache
                .getattr(py, "is_loaded")
                .ok()
                .map(|o| {
                    o.extract::<bool>(py).expect(
                        "is_loaded returned something other than a bool",
                    )
                })
                .unwrap_or(false);
            if is_loaded {
                FN_CACHE_IS_LOADED.store(true, Ordering::Relaxed);
            }
            is_loaded
        })
    }
    fn add(&self, path: &std::path::Path) {
        Python::with_gil(|py| {
            // TODO raise in case of error?
            self.fncache
                .call_method(
                    py,
                    "add",
                    (PyBytes::new(py, &get_bytes_from_path(path)),),
                    None,
                )
                .ok();
        })
    }
}
