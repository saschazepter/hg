//! Bindings for the `hg::file_index` module provided by the `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.file_index`

use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::sync::RwLockReadGuard;
use std::sync::RwLockWriteGuard;

use hg::file_index::DebugTreeNode;
use hg::file_index::DebugTreeNodeIter;
use hg::file_index::FileIndex;
use hg::file_index::FileToken;
use hg::file_index::PathTokenIter;
use hg::file_index::VacuumMode;
use hg::revlog::path_encode::PathEncoding;
use hg::utils::files::get_bytes_from_path;
use hg::utils::files::get_path_from_bytes;
use hg::utils::hg_path::HgPath;
use hg::utils::u32_u;
use hg::vfs::VfsImpl;
use pyo3::exceptions::PyOSError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyList;
use pyo3::types::PyTuple;
use pyo3_sharedref::py_shared_iterator;
use pyo3_sharedref::PyShareable;

use crate::exceptions::map_try_lock_error;
use crate::exceptions::to_string_value_error;
use crate::transaction::PyTransaction;
use crate::utils::new_submodule;

/// Implementation of `mercurial.interfaces.IFileIndex`.
/// This is a drop-in replacement for `mercurial.store_utils.FileIndex`.
#[pyclass(name = "FileIndex", mapping, frozen)]
struct PyFileIndex {
    inner: PyShareable<FileIndex>,
    /// True if we've already called [`Self::_add_file_generator`], since it
    /// only needs to be done once per transaction.
    added_file_generator: AtomicBool,
}

#[pymethods]
impl PyFileIndex {
    #[new]
    #[allow(clippy::too_many_arguments)]
    fn new(
        py: Python<'_>,
        ui: &Bound<'_, PyAny>,
        opener: &Bound<'_, PyAny>,
        try_pending: bool,
        vacuum_mode: &Bound<'_, PyAny>,
        max_unused_ratio: f64,
        gc_retention_s: u32,
        garbage_timestamp: Option<u32>,
    ) -> PyResult<Self> {
        let base = opener.getattr("base")?;
        let base = get_path_from_bytes(base.extract::<&[u8]>()?).to_owned();
        let raw_store_vfs = VfsImpl::new(base, false, PathEncoding::None);
        let vacuum_mode = vacuum_mode.getattr("value")?;
        let vacuum_mode = VacuumMode::parse(vacuum_mode.extract::<&[u8]>()?)
            .expect("Python should give a valid vacuum mode");
        let config = hg::file_index::Config {
            vacuum_mode,
            max_unused_ratio,
            gc_retention_s,
            garbage_timestamp,
        };
        let testing = PyModule::import(py, "mercurial.testing")?;
        let wait_on_cfg = testing.getattr("wait_on_cfg")?;
        let devel_sync_point = || {
            let _ = wait_on_cfg.call1((ui, b"fileindex.pre-read-data-files"));
        };
        let file_index = FileIndex::open(
            raw_store_vfs,
            try_pending,
            config,
            devel_sync_point,
        )
        .map_err(to_string_value_error)?;
        Ok(Self {
            inner: file_index.into(),
            added_file_generator: AtomicBool::new(false),
        })
    }

    fn has_token(slf: &Bound<'_, Self>, token: u32) -> PyResult<bool> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(inner.has_token(FileToken(token)))
        })
    }

    fn has_path(slf: &Bound<'_, Self>, path: &[u8]) -> PyResult<bool> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            inner.has_path(HgPath::new(path)).map_err(file_index_error)
        })
    }

    fn get_path<'py>(
        slf: &Bound<'py, Self>,
        py: Python<'py>,
        token: u32,
    ) -> PyResult<Option<Bound<'py, PyBytes>>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(inner
                .get_path(FileToken(token))
                .map_err(file_index_error)?
                .map(|path| PyBytes::new(py, path.as_bytes())))
        })
    }

    fn get_token(slf: &Bound<'_, Self>, path: &[u8]) -> PyResult<Option<u32>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(inner
                .get_token(HgPath::new(path))
                .map_err(file_index_error)?
                .map(|token| token.0))
        })
    }

    fn __contains__(slf: &Bound<'_, Self>, path: &[u8]) -> PyResult<bool> {
        Self::has_path(slf, path)
    }

    fn __len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_inner_read(slf, |_self_ref, inner| Ok(inner.len()))
    }

    fn __iter__(slf: &Bound<'_, Self>) -> PyResult<PyPathIter> {
        PyPathIter::new(slf)
    }

    fn items(slf: &Bound<'_, Self>) -> PyResult<PyPathTokenIter> {
        PyPathTokenIter::new(slf)
    }

    fn add(
        slf: &Bound<'_, Self>,
        path: &[u8],
        tr: &Bound<'_, PyAny>,
    ) -> PyResult<u32> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            let (token, added) =
                inner.add(HgPath::new(path)).map_err(file_index_error)?;
            if added {
                Self::_add_file_generator(slf, tr)?;
            }
            Ok(token.0)
        })
    }

    fn remove(
        slf: &Bound<'_, Self>,
        path: &[u8],
        tr: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            inner.remove(HgPath::new(path)).map_err(file_index_error)?;
            Self::_add_file_generator(slf, tr)?;
            Ok(())
        })
    }

    fn vacuum(slf: &Bound<'_, Self>, tr: &Bound<'_, PyAny>) -> PyResult<()> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            inner.vacuum();
            Self::_add_file_generator(slf, tr)?;
            Ok(())
        })
    }

    #[pyo3(signature = (tr, force=false))]
    fn garbage_collect(
        slf: &Bound<'_, Self>,
        tr: &Bound<'_, PyAny>,
        force: bool,
    ) -> PyResult<()> {
        Self::with_inner_write(slf, |_self_ref, mut inner| {
            let changed = inner.garbage_collect(force);
            if changed {
                Self::_add_file_generator(slf, tr)?;
            }
            Ok(())
        })
    }

    fn data_files<'py>(
        slf: &Bound<'py, Self>,
        py: Python<'py>,
    ) -> PyResult<Bound<'py, PyList>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            PyList::new(py, inner.data_files().iter().map(get_bytes_from_path))
        })
    }

    fn debug_docket<'py>(
        slf: &Bound<'py, Self>,
        py: Python<'py>,
    ) -> PyResult<Bound<'py, PyDict>> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            let docket = inner.docket();
            let header = &docket.header;
            let dict = PyDict::new(py);
            dict.set_item("marker", header.marker)?;
            dict.set_item("list_file_size", header.list_file_size.get())?;
            dict.set_item(
                "reserved_revlog_size",
                header.reserved_revlog_size.get(),
            )?;
            dict.set_item("meta_file_size", header.meta_file_size.get())?;
            dict.set_item("tree_file_size", header.tree_file_size.get())?;
            dict.set_item("list_file_id", header.list_file_id.as_bytes())?;
            dict.set_item(
                "reserved_revlog_id",
                header.reserved_revlog_id.as_bytes(),
            )?;
            dict.set_item("meta_file_id", header.meta_file_id.as_bytes())?;
            dict.set_item("tree_file_id", header.tree_file_id.as_bytes())?;
            dict.set_item("tree_root_pointer", header.tree_root_pointer.get())?;
            dict.set_item("tree_unused_bytes", header.tree_unused_bytes.get())?;
            dict.set_item(
                "reserved_revlog_unused",
                header.reserved_revlog_unused.get(),
            )?;
            dict.set_item(
                "reserved_flags",
                u32::from_be_bytes(header.reserved_flags),
            )?;
            let garbage_entries = docket
                .garbage_entries
                .iter()
                .map(|entry| -> PyResult<Bound<'_, PyDict>> {
                    let dict = PyDict::new(py);
                    dict.set_item("ttl", entry.ttl)?;
                    dict.set_item("timestamp", entry.timestamp)?;
                    let path = entry.path.as_os_str().as_encoded_bytes();
                    dict.set_item("path", path)?;
                    Ok(dict)
                })
                .collect::<Result<Vec<_>, _>>()?;
            dict.set_item(
                "garbage_entries",
                PyList::new(py, garbage_entries)?,
            )?;
            Ok(dict)
        })
    }

    fn debug_tree_file_size(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_inner_read(slf, |_self_ref, inner| {
            Ok(u32_u(inner.docket().header.tree_file_size.get()))
        })
    }

    fn debug_iter_tree_nodes(
        slf: &Bound<'_, Self>,
    ) -> PyResult<PyDebugTreeNodeIter> {
        PyDebugTreeNodeIter::new(slf)
    }

    fn _add_file_generator(
        slf: &Bound<'_, Self>,
        tr: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        // Ordering does not matter since we have the GIL.
        if slf.borrow().added_file_generator.swap(true, Ordering::Relaxed) {
            return Ok(());
        }
        let kwargs = PyDict::new(slf.py());
        let genfunc = PyFileIndexWriteClosure {
            file_index: slf.clone().unbind(),
            tr: tr.clone().unbind(),
        };
        kwargs.set_item("genid", b"fileindex")?;
        kwargs.set_item("filenames", (b"fileindex",))?;
        kwargs.set_item("genfunc", genfunc)?;
        kwargs.set_item("location", b"store")?;
        kwargs.set_item("post_finalize", true)?;
        tr.call_method("addfilegenerator", (), Some(&kwargs))?;
        Ok(())
    }

    fn _write(
        slf: &Bound<'_, Self>,
        f: &Bound<'_, PyAny>,
        tr: Py<PyAny>,
    ) -> PyResult<()> {
        Self::with_inner_write(slf, |self_ref, mut inner| {
            // Ordering does not matter since we have the GIL.
            self_ref.added_file_generator.store(false, Ordering::Relaxed);
            let py_tr = &mut PyTransaction::new(tr);
            inner.write(py_tr).map_err(to_string_value_error)?;
            let docket_bytes = inner.docket().serialize();
            f.call_method1("write", (&docket_bytes,))?;
            Ok(())
        })
    }
}

impl PyFileIndex {
    /// Helper to get read-only access to [`Self::inner`].
    fn with_inner_read<'py, T, F>(slf: &Bound<'py, Self>, f: F) -> PyResult<T>
    where
        F: FnOnce(&PyRef<'py, Self>, RwLockReadGuard<FileIndex>) -> PyResult<T>,
    {
        let self_ref = slf.borrow();
        // Safety: We are the owner.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_read().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
    }

    /// Helper to get read-write access to [`Self::inner`].
    fn with_inner_write<'py, T, F>(slf: &Bound<'py, Self>, f: F) -> PyResult<T>
    where
        F: FnOnce(
            &PyRef<'py, Self>,
            RwLockWriteGuard<FileIndex>,
        ) -> PyResult<T>,
    {
        let self_ref = slf.borrow();
        // Safety: We are the owner.
        let shareable_ref = unsafe { self_ref.inner.borrow_with_owner(slf) };
        let guard = shareable_ref.try_write().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
    }
}

#[pyclass(name = "FileIndexWriteClosure", frozen)]
struct PyFileIndexWriteClosure {
    file_index: Py<PyFileIndex>,
    tr: Py<PyAny>,
}

#[pymethods]
impl PyFileIndexWriteClosure {
    fn __call__(&self, py: Python<'_>, f: &Bound<'_, PyAny>) -> PyResult<()> {
        self.file_index.call_method1(py, "_write", (f, &self.tr))?;
        Ok(())
    }
}

py_shared_iterator!(
    PyPathIter,
    PyBytes,
    PyFileIndex,
    inner,
    PathTokenIter<'static>,
    |file_index| file_index.iter(),
    convert_path_iter_item
);

fn convert_path_iter_item(
    py: Python,
    item: Result<(&HgPath, FileToken), hg::file_index::Error>,
) -> PyResult<Option<Py<PyBytes>>> {
    let (path, _token) = item.map_err(file_index_error)?;
    Ok(Some(PyBytes::new(py, path.as_bytes()).unbind()))
}

py_shared_iterator!(
    PyPathTokenIter,
    PyTuple,
    PyFileIndex,
    inner,
    PathTokenIter<'static>,
    |file_index| file_index.iter(),
    convert_path_token_iter_item
);

fn convert_path_token_iter_item(
    py: Python,
    item: Result<(&HgPath, FileToken), hg::file_index::Error>,
) -> PyResult<Option<Py<PyTuple>>> {
    let (path, token) = item.map_err(file_index_error)?;
    Ok(Some((path.as_bytes(), token.0).into_pyobject(py)?.unbind()))
}

py_shared_iterator!(
    PyDebugTreeNodeIter,
    PyTuple,
    PyFileIndex,
    inner,
    DebugTreeNodeIter<'static>,
    |file_index| file_index.debug_iter_tree_nodes(),
    convert_debug_tree_node_iter_item
);

fn convert_debug_tree_node_iter_item(
    py: Python,
    item: Result<DebugTreeNode, hg::file_index::Error>,
) -> PyResult<Option<Py<PyTuple>>> {
    let DebugTreeNode { pointer, token, label, children } =
        item.map_err(file_index_error)?;
    Ok(Some((pointer, token.0, label, children).into_pyobject(py)?.unbind()))
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "file_index")?;
    m.add("__doc__", "File index - Rust implementation exposed via PyO3")?;
    m.add_class::<PyFileIndex>()?;
    Ok(m)
}

fn file_index_error(err: hg::file_index::Error) -> PyErr {
    PyOSError::new_err(format!("FileIndex error: {:?}", err))
}
