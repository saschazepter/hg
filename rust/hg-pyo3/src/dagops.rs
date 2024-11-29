// dagops.rs
//
// Copyright 2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::dagops` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3-rustext.dagop`
use pyo3::prelude::*;

use crate::util::new_submodule;

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "dagop")?;
    Ok(m)
}
