// copy_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for `hg::dirstate::dirs_multiset` file provided by the
//! `hg-core` package.
use pyo3::exceptions::PyTypeError;
use pyo3::prelude::*;
use pyo3::types::PyDict;
use pyo3_sharedref::PyShareable;

use hg::{dirstate::dirs_multiset::DirsMultiset, utils::hg_path::HgPathBuf};

use crate::exceptions::to_string_value_error;

#[pyclass(mapping)]
#[allow(dead_code)]
pub struct Dirs {
    pub(super) inner: PyShareable<DirsMultiset>,
}

#[pymethods]
impl Dirs {
    #[new]
    fn new(map: &Bound<'_, PyAny>) -> PyResult<Self> {
        if map.downcast::<PyDict>().is_ok() {
            return Err(PyTypeError::new_err(
                "pathutil.dirs() with a dict should only be used by the \
                 Python dirstatemap and should not be used \
                 when Rust is enabled",
            ));
        }
        let map: Result<Vec<_>, PyErr> = map
            .try_iter()?
            .map(|o| Ok(HgPathBuf::from_bytes(o?.extract()?)))
            .collect();
        Ok(Self {
            inner: DirsMultiset::from_manifest(&map?)
                .map_err(to_string_value_error)?
                .into(),
        })
    }
}
