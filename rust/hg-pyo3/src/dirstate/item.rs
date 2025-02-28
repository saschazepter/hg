// dirstate/item.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Bindings for the `hg::dirstate::entry` module of the `hg-core` package.

use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use hg::dirstate::entry::{DirstateEntry, DirstateV2Data, TruncatedTimestamp};

use crate::exceptions::map_lock_error;

#[pyclass]
pub struct DirstateItem {
    entry: RwLock<DirstateEntry>,
}

/// Type alias to satisfy Clippy in `DirstateItem::new()`
type UncheckedTruncatedTimeStamp = Option<(u32, u32, bool)>;

#[pymethods]
impl DirstateItem {
    #[new]
    #[allow(clippy::too_many_arguments)]
    #[pyo3(signature = (wc_tracked=false,
                        p1_tracked=false,
                        p2_info=false,
                        has_meaningful_data=true,
                        has_meaningful_mtime=true,
                        parentfiledata=None,
                        fallback_exec=None,
                        fallback_symlink=None))]
    fn new(
        wc_tracked: bool,
        p1_tracked: bool,
        p2_info: bool,
        has_meaningful_data: bool,
        has_meaningful_mtime: bool,
        parentfiledata: Option<(u32, u32, UncheckedTruncatedTimeStamp)>,
        fallback_exec: Option<bool>,
        fallback_symlink: Option<bool>,
    ) -> PyResult<Self> {
        let mut mode_size_opt = None;
        let mut mtime_opt = None;
        if let Some((mode, size, mtime)) = parentfiledata {
            if has_meaningful_data {
                mode_size_opt = Some((mode, size))
            }
            if has_meaningful_mtime {
                if let Some(m) = mtime {
                    mtime_opt = Some(timestamp(m)?);
                }
            }
        }
        Ok(Self {
            entry: DirstateEntry::from_v2_data(DirstateV2Data {
                wc_tracked,
                p1_tracked,
                p2_info,
                mode_size: mode_size_opt,
                mtime: mtime_opt,
                fallback_exec,
                fallback_symlink,
            })
            .into(),
        })
    }

    #[getter]
    fn state(&self, py: Python) -> PyResult<Py<PyBytes>> {
        let state_byte = self.read()?.state();
        Ok(PyBytes::new(py, &[state_byte.into()]).unbind())
    }

    #[getter]
    fn mode(&self) -> PyResult<i32> {
        Ok(self.read()?.mode())
    }

    #[getter]
    fn size(&self) -> PyResult<i32> {
        Ok(self.read()?.size())
    }

    #[getter]
    fn mtime(&self) -> PyResult<i32> {
        Ok(self.read()?.mtime())
    }

    #[getter]
    fn has_fallback_exec(&self) -> PyResult<bool> {
        Ok(self.read()?.get_fallback_exec().is_some())
    }

    #[getter]
    fn fallback_exec(&self) -> PyResult<Option<bool>> {
        Ok(self.read()?.get_fallback_exec())
    }

    #[setter]
    fn set_fallback_exec(
        &self,
        value: Option<Bound<'_, PyAny>>,
    ) -> PyResult<()> {
        let mut writable = self.write()?;
        match value {
            None => {
                writable.set_fallback_exec(None);
            }
            Some(value) => {
                if value.is_none() {
                    // gracinet: this case probably cannot happen,
                    // because PyO3 setters have a fixed signature, that
                    // is not defaulting to kwargs, hence there is no
                    // difference between an explicit None and a default
                    // (kwarg) None. Still keeping it for safety, it could
                    // be cleaned up afterwards.
                    writable.set_fallback_exec(None);
                } else {
                    writable.set_fallback_exec(Some(value.is_truthy()?));
                }
            }
        }
        Ok(())
    }

    #[getter]
    fn has_fallback_symlink(&self) -> PyResult<bool> {
        Ok(self.read()?.get_fallback_symlink().is_some())
    }

    #[getter]
    fn fallback_symlink(&self) -> PyResult<Option<bool>> {
        Ok(self.read()?.get_fallback_symlink())
    }

    #[getter]
    fn tracked(&self) -> PyResult<bool> {
        Ok(self.read()?.tracked())
    }

    #[getter]
    fn p1_tracked(&self) -> PyResult<bool> {
        Ok(self.read()?.p1_tracked())
    }

    #[getter]
    fn added(&self) -> PyResult<bool> {
        Ok(self.read()?.added())
    }

    #[getter]
    fn modified(&self) -> PyResult<bool> {
        Ok(self.read()?.modified())
    }

    #[getter]
    fn p2_info(&self) -> PyResult<bool> {
        Ok(self.read()?.p2_info())
    }

    #[getter]
    fn removed(&self) -> PyResult<bool> {
        Ok(self.read()?.removed())
    }

    #[getter]
    fn maybe_clean(&self) -> PyResult<bool> {
        Ok(self.read()?.maybe_clean())
    }

    #[getter]
    fn any_tracked(&self) -> PyResult<bool> {
        Ok(self.read()?.any_tracked())
    }

    fn mtime_likely_equal_to(
        &self,
        other: (u32, u32, bool),
    ) -> PyResult<bool> {
        if let Some(mtime) = self.read()?.truncated_mtime() {
            Ok(mtime.likely_equal(timestamp(other)?))
        } else {
            Ok(false)
        }
    }

    fn drop_merge_data(&self) -> PyResult<()> {
        self.write()?.drop_merge_data();
        Ok(())
    }

    fn set_clean(
        &self,
        mode: u32,
        size: u32,
        mtime: (u32, u32, bool),
    ) -> PyResult<()> {
        self.write()?.set_clean(mode, size, timestamp(mtime)?);
        Ok(())
    }

    fn set_possibly_dirty(&self) -> PyResult<()> {
        self.write()?.set_possibly_dirty();
        Ok(())
    }

    fn set_tracked(&self) -> PyResult<()> {
        self.write()?.set_tracked();
        Ok(())
    }

    fn set_untracked(&self) -> PyResult<()> {
        self.write()?.set_untracked();
        Ok(())
    }
}

impl DirstateItem {
    pub fn new_as_py(py: Python, entry: DirstateEntry) -> PyResult<Py<Self>> {
        Ok(Self {
            entry: entry.into(),
        }
        .into_pyobject(py)?
        .unbind())
    }

    fn read(&self) -> PyResult<RwLockReadGuard<DirstateEntry>> {
        self.entry.read().map_err(map_lock_error)
    }

    fn write(&self) -> PyResult<RwLockWriteGuard<DirstateEntry>> {
        self.entry.write().map_err(map_lock_error)
    }
}

pub(crate) fn timestamp(
    (s, ns, second_ambiguous): (u32, u32, bool),
) -> PyResult<TruncatedTimestamp> {
    TruncatedTimestamp::from_already_truncated(s, ns, second_ambiguous)
        .map_err(|_| {
            PyValueError::new_err("expected mtime truncated to 31 bits")
        })
}
