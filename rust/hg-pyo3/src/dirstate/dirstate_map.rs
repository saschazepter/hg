// dirstate_map.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for the `hg::dirstate::dirstate_map` file provided by the
//! `hg-core` package.

use pyo3::prelude::*;

use hg::dirstate::dirstate_map::DirstateIdentity as CoreDirstateIdentity;

#[pyclass]
pub struct DirstateIdentity {
    #[allow(dead_code)]
    inner: CoreDirstateIdentity,
}

#[pymethods]
impl DirstateIdentity {
    #[new]
    #[allow(clippy::too_many_arguments)]
    fn new(
        mode: u32,
        dev: u64,
        ino: u64,
        nlink: u64,
        uid: u32,
        gid: u32,
        size: u64,
        mtime: i64,
        mtime_nsec: i64,
        ctime: i64,
        ctime_nsec: i64,
    ) -> PyResult<Self> {
        Ok(Self {
            inner: CoreDirstateIdentity {
                mode,
                dev,
                ino,
                nlink,
                uid,
                gid,
                size,
                mtime,
                mtime_nsec,
                ctime,
                ctime_nsec,
            },
        })
    }
}
