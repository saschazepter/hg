// dirstate.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::dirstate` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.dirstate`
use crate::{exceptions, utils::new_submodule};
use pyo3::prelude::*;
mod item;
use item::DirstateItem;
mod dirstate_map;
use dirstate_map::DirstateIdentity;

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "dirstate")?;
    m.add("__doc__", "Dirstate - Rust implementation exposed via PyO3")?;
    m.add("FallbackError", py.get_type::<exceptions::FallbackError>())?;
    m.add_class::<DirstateIdentity>()?;
    m.add_class::<DirstateItem>()?;
    Ok(m)
}
