// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//           2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
#![allow(non_snake_case)]
use hg::revlog::index::IndexHeader;
use hg::revlog::nodemap::Block;
use hg::utils::files::get_bytes_from_path;
use pyo3::buffer::PyBuffer;
use pyo3::conversion::IntoPyObject;
use pyo3::exceptions::{PyIndexError, PyTypeError, PyValueError};
use pyo3::types::{
    PyBool, PyBytes, PyBytesMethods, PyDict, PyList, PySet, PyTuple,
};
use pyo3::{prelude::*, IntoPyObjectExt};
use pyo3_sharedref::{PyShareable, SharedByPyObject};

use std::collections::{HashMap, HashSet};
use std::os::fd::AsRawFd;
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    RwLock, RwLockReadGuard, RwLockWriteGuard,
};

use hg::{
    errors::HgError,
    revlog::{
        index::{
            Index, Phase, RevisionDataParams, SnapshotsCache, INDEX_ENTRY_SIZE,
        },
        inner_revlog::InnerRevlog as CoreInnerRevlog,
        nodemap::{NodeMap, NodeMapError, NodeTree as CoreNodeTree},
        options::RevlogOpenOptions,
        RevlogError, RevlogIndex, RevlogType,
    },
    utils::files::get_path_from_bytes,
    vfs::FnCacheVfs,
    BaseRevision, Revision, UncheckedRevision, NULL_REVISION,
};

use crate::utils::PyBytesDeref;
use crate::{
    exceptions::{
        graph_error, map_lock_error, map_try_lock_error, nodemap_error,
        rev_not_in_index, revlog_error_bare, revlog_error_from_msg,
    },
    node::{node_from_py_bytes, node_prefix_from_py_bytes, py_node_for_rev},
    revision::{
        check_revision, rev_pyiter_collect, rev_pyiter_collect_or_else,
        revs_py_list, revs_py_set, PyRevision,
    },
    store::PyFnCache,
    transaction::PyTransaction,
    utils::{new_submodule, take_buffer_with_slice, with_pybytes_buffer},
};

mod config;
use config::*;
mod index;
pub use index::PySharedIndex;
use index::{
    py_tuple_to_revision_data_params, revision_data_params_to_py_tuple,
};

#[pyclass]
struct ReadingContextManager {
    inner_revlog: Py<InnerRevlog>,
}

#[pymethods]
impl ReadingContextManager {
    fn __enter__(slf: PyRef<'_, Self>) -> PyResult<()> {
        let inner_bound = slf.inner_revlog.bind(slf.py());
        let shareable = &inner_bound.borrow().irl;
        // Safety: the owner is correct and we won't use `share()` anyway
        let core_irl =
            unsafe { shareable.borrow_with_owner(inner_bound) }.read();
        core_irl
            .enter_reading_context()
            .map_err(revlog_error_from_msg)
            .inspect_err(|_e| {
                // `__exit__` is not called from Python if `__enter__` fails
                core_irl.exit_reading_context();
            })
    }

    #[pyo3(signature = (*_args))]
    fn __exit__(slf: PyRef<'_, Self>, _args: &Bound<'_, PyTuple>) {
        let inner_bound = slf.inner_revlog.bind(slf.py());
        let shareable = &inner_bound.borrow().irl;
        // Safety: the owner is correct and we won't use `share()` anyway
        let core_irl_ref = unsafe { shareable.borrow_with_owner(inner_bound) };
        core_irl_ref.read().exit_reading_context();
    }
}

#[pyclass]
struct WritingContextManager {
    inner_revlog: Py<InnerRevlog>,
    transaction: RwLock<PyTransaction>,
    data_end: Option<usize>,
}

#[pymethods]
impl WritingContextManager {
    fn __enter__(slf: PyRefMut<'_, Self>) -> PyResult<()> {
        let inner_bound = slf.inner_revlog.bind(slf.py());
        let shareable = &inner_bound.borrow_mut().irl;
        // Safety: the owner is correct and we won't use `share()` anyway
        let mut core_irl =
            unsafe { shareable.borrow_with_owner(inner_bound) }.write();
        core_irl
            .enter_writing_context(
                slf.data_end,
                &mut *slf
                    .transaction
                    .try_write()
                    .expect("transaction should be protected by the GIL"),
            )
            .map_err(revlog_error_from_msg)
            .inspect_err(|_e| {
                // `__exit__` is not called from Python if `__enter__` fails
                core_irl.exit_writing_context();
            })
    }

    #[pyo3(signature = (*_args))]
    fn __exit__(slf: PyRef<'_, Self>, _args: &Bound<'_, PyTuple>) {
        let inner_bound = slf.inner_revlog.bind(slf.py());
        let shareable = &inner_bound.borrow().irl;
        // Safety: the owner is correct and we won't use `share()` anyway
        let core_irl_ref = unsafe { shareable.borrow_with_owner(inner_bound) };
        core_irl_ref.write().exit_writing_context();
    }
}

struct PySnapshotsCache<'a, 'py: 'a>(&'a Bound<'py, PyDict>);

impl<'a, 'py> PySnapshotsCache<'a, 'py> {
    fn insert_for_with_py_result(
        &self,
        rev: BaseRevision,
        value: BaseRevision,
    ) -> PyResult<()> {
        match self.0.get_item(rev)? {
            Some(obj) => obj.downcast::<PySet>()?.add(value),
            None => {
                let set = PySet::new(self.0.py(), vec![value])?;
                self.0.set_item(rev, set)
            }
        }
    }
}

impl<'a, 'py> SnapshotsCache for PySnapshotsCache<'a, 'py> {
    fn insert_for(
        &mut self,
        rev: BaseRevision,
        value: BaseRevision,
    ) -> Result<(), RevlogError> {
        self.insert_for_with_py_result(rev, value).map_err(|_| {
            RevlogError::Other(HgError::unsupported(
                "Error in Python caches handling",
            ))
        })
    }
}

// Only used from Python *tests*
#[doc(hidden)]
#[pyclass]
pub struct PyFileHandle {
    inner_file: std::os::fd::RawFd,
}

#[pymethods]
impl PyFileHandle {
    #[new]
    fn new(handle: std::os::fd::RawFd) -> Self {
        Self { inner_file: handle }
    }

    fn tell(&self, py: Python<'_>) -> PyResult<PyObject> {
        let locals = PyDict::new(py);
        locals.set_item("os", py.import("os")?)?;
        locals.set_item("fd", self.inner_file)?;
        let f = py.eval(c"os.fdopen(fd)", None, Some(&locals))?;

        // Prevent Python from closing the file after garbage collecting.
        // This is fine since Rust is still holding on to the actual File.
        // (and also because it's only used in tests).
        std::mem::forget(f.clone());

        locals.set_item("f", f)?;
        let res = py.eval(c"f.tell()", None, Some(&locals))?;
        Ok(res.unbind())
    }
}

#[pyclass]
#[allow(dead_code)]
pub(crate) struct InnerRevlog {
    pub(crate) irl: PyShareable<CoreInnerRevlog>,
    nt: RwLock<Option<CoreNodeTree>>,
    docket: Option<PyObject>,
    // Holds a reference to the mmap'ed persistent nodemap data
    nodemap_mmap: Option<PyBuffer<u8>>,
    // Holds a reference to the mmap'ed persistent index data
    index_mmap: Option<PyBuffer<u8>>,
    revision_cache: Option<PyObject>,
    head_revs_py_list: Option<Py<PyList>>,
    head_node_ids_py_list: Option<Py<PyList>>,
    use_persistent_nodemap: bool,
    nodemap_queries: AtomicUsize,
}

#[pymethods]
impl InnerRevlog {
    #[new]
    // The Python side has authority on this signature.
    #[allow(clippy::too_many_arguments)]
    fn new(
        vfs_base: &Bound<'_, PyBytes>,
        fncache: &Bound<'_, PyAny>,
        vfs_is_readonly: bool,
        index_data: &Bound<'_, PyAny>,
        index_file: &Bound<'_, PyBytes>,
        data_file: &Bound<'_, PyBytes>,
        sidedata_file: &Bound<'_, PyAny>,
        inline: bool,
        data_config: &Bound<'_, PyAny>,
        delta_config: &Bound<'_, PyAny>,
        feature_config: &Bound<'_, PyAny>,
        chunk_cache: &Bound<'_, PyAny>,
        default_compression_header: &Bound<'_, PyAny>,
        revlog_type: usize,
        use_persistent_nodemap: bool,
    ) -> PyResult<Self> {
        // Let clippy accept the unused arguments. This is a bit better than
        // a blank `allow` directive
        let _ = sidedata_file;
        let _ = chunk_cache;
        let _ = default_compression_header;

        let index_file = get_path_from_bytes(index_file.as_bytes()).to_owned();
        let data_file = get_path_from_bytes(data_file.as_bytes()).to_owned();
        let revlog_type = RevlogType::try_from(revlog_type)
            .map_err(revlog_error_from_msg)?;
        let data_config = extract_data_config(data_config, revlog_type)?;
        let delta_config = extract_delta_config(delta_config, revlog_type)?;
        let feature_config =
            extract_feature_config(feature_config, revlog_type)?;
        let options = RevlogOpenOptions::new(
            inline,
            data_config,
            delta_config,
            feature_config,
        );

        // Safety: we keep the buffer around inside the returned instance as
        // `index_mmap`
        let (buf, bytes) = unsafe { take_buffer_with_slice(index_data)? };
        let index = Index::new(bytes, options.index_header())
            .map_err(revlog_error_from_msg)?;

        let base = get_path_from_bytes(vfs_base.as_bytes()).to_owned();
        let core = CoreInnerRevlog::new(
            Box::new(FnCacheVfs::new(
                base,
                vfs_is_readonly,
                Box::new(PyFnCache::new(fncache.clone().unbind())),
            )),
            index,
            index_file,
            data_file,
            data_config,
            delta_config,
            feature_config,
        );
        Ok(Self {
            irl: core.into(),
            nt: None.into(),
            docket: None,
            nodemap_mmap: None,
            index_mmap: buf.into(),
            head_revs_py_list: None,
            head_node_ids_py_list: None,
            revision_cache: None,
            use_persistent_nodemap,
            nodemap_queries: AtomicUsize::new(0),
        })
    }

    #[getter]
    fn canonical_index_file(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            let path = irl.canonical_index_file();
            Ok(PyBytes::new(py, &get_bytes_from_path(path)).into())
        })
    }

    #[getter]
    fn is_delaying(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_core_read(slf, |_self_ref, irl| Ok(irl.is_delaying()))
    }

    #[getter]
    fn inline(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_core_read(slf, |_self_ref, irl| Ok(irl.is_inline()))
    }

    #[setter]
    fn set_inline(slf: &Bound<'_, Self>, inline: bool) -> PyResult<()> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            irl.inline = inline;
            Ok(())
        })
    }

    #[getter]
    fn is_writing(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_core_read(slf, |_self_ref, irl| Ok(irl.is_writing()))
    }

    #[getter]
    fn is_open(slf: &Bound<'_, Self>) -> PyResult<bool> {
        Self::with_core_read(slf, |_self_ref, irl| Ok(irl.is_open()))
    }

    #[getter]
    fn _revisioncache(&self, py: Python<'_>) -> PyResult<PyObject> {
        match &self.revision_cache {
            None => Ok(py.None()),
            Some(cache) => Ok(cache.clone_ref(py)),
        }
    }

    #[setter]
    fn set__revisioncache(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        value: Option<PyObject>,
    ) -> PyResult<()> {
        let mut self_ref = slf.borrow_mut();
        self_ref.revision_cache = value.as_ref().map(|v| v.clone_ref(py));

        match value {
            None => {
                // This means the property has been deleted, *not* that the
                // property has been set to `None`. Whatever happens is up
                // to the implementation. Here we just set it to `None`.
                self_ref.revision_cache.take();
            }
            Some(tuple) => {
                if tuple.is_none(py) {
                    self_ref.revision_cache.take();
                    return Ok(());
                }
                drop(self_ref);
                let tuple: &Bound<'_, PyTuple> = tuple.downcast_bound(py)?;
                let node = tuple.get_item(0)?;
                let node = node_from_py_bytes(node.downcast()?)?;
                let rev: BaseRevision = tuple.get_item(1)?.extract()?;
                // Ok because Python only sets this if the revision has been
                // checked
                let rev = Revision(rev);
                let data = tuple.get_item(2)?;
                let bytes = data.downcast_into::<PyBytes>()?.unbind();
                Self::with_core_read(slf, |_self_ref, irl| {
                    let mut last_revision_cache = irl
                        .last_revision_cache
                        .lock()
                        .expect("lock should not be held");
                    *last_revision_cache = Some((
                        node,
                        rev,
                        Box::new(PyBytesDeref::new(py, bytes)),
                    ));
                    Ok(())
                })?;
            }
        }
        Ok(())
    }

    #[getter]
    fn index_file(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            let path = get_bytes_from_path(&irl.index_file);
            Ok(PyBytes::new(py, &path).unbind())
        })
    }

    #[setter]
    fn set_index_file(
        slf: &Bound<'_, Self>,
        path: &Bound<'_, PyBytes>,
    ) -> PyResult<()> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            let path = get_path_from_bytes(path.as_bytes());
            path.clone_into(&mut irl.index_file);
            Ok(())
        })
    }

    // This is only used in Python *tests*
    #[getter]
    #[doc(hidden)]
    fn _writinghandles(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<PyObject> {
        Self::with_core_read(slf, |_self_ref, irl| {
            let handles = irl.python_writing_handles();
            match handles.as_ref() {
                None => Ok(py.None()),
                Some(handles) => {
                    let index_handle = PyFileHandle::new(
                        handles.index_handle.file.as_raw_fd(),
                    );
                    let data_handle = handles
                        .data_handle
                        .as_ref()
                        .map(|h| PyFileHandle::new(h.file.as_raw_fd()));
                    Ok(PyTuple::new(
                        py,
                        &[
                            index_handle.into_py_any(py)?,
                            data_handle.into_py_any(py)?,
                            py.None(), // Sidedata handle
                        ],
                    )?
                    .unbind()
                    .into())
                }
            }
        })
    }

    fn clear_cache(slf: &Bound<'_, Self>) -> PyResult<PyObject> {
        assert!(!Self::is_delaying(slf)?);
        let mut self_ref = slf.borrow_mut();
        self_ref.revision_cache.take();
        self_ref.nodemap_queries.store(0, Ordering::Relaxed);
        drop(self_ref);

        Self::with_core_write(slf, |_self_ref, mut irl| {
            irl.clear_cache();
            Ok(slf.py().None())
        })
    }

    fn issnapshot(slf: &Bound<'_, Self>, rev: PyRevision) -> PyResult<bool> {
        Self::_index_issnapshot(slf, rev)
    }

    #[pyo3(signature = (rev, stoprev=None))]
    fn _deltachain(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        rev: PyRevision,
        stoprev: Option<PyRevision>,
    ) -> PyResult<Py<PyTuple>> {
        Self::_index_deltachain(slf, py, rev, stoprev)
    }

    fn compress(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        data: &Bound<'_, PyAny>,
    ) -> PyResult<Py<PyTuple>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            // Safety: we only hold on to the data for as long as `_buf`
            // is alive
            let (_buf, data) = unsafe { take_buffer_with_slice(data)? };
            let compressed =
                irl.compress(&data).map_err(revlog_error_from_msg)?;
            let compressed = compressed.as_deref();
            let header = if compressed.is_some() {
                PyBytes::new(py, &b""[..])
            } else {
                PyBytes::new(py, &b"u"[..])
            };
            Ok(PyTuple::new(
                py,
                &[header, PyBytes::new(py, compressed.unwrap_or(&data))],
            )?
            .unbind())
        })
    }

    #[pyo3(signature = (tr, header, new_index_file_path=None))]
    fn split_inline(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        tr: PyObject,
        header: i32,
        new_index_file_path: Option<&Bound<'_, PyBytes>>,
    ) -> PyResult<Py<PyBytes>> {
        // Also unused in Python, TODO clean this up.
        let _ = tr;

        Self::with_core_write(slf, |_self_ref, mut irl| {
            let new_index_file_path = new_index_file_path
                .map(|path| get_path_from_bytes(path.as_bytes()).to_owned());
            let header = IndexHeader::parse(&header.to_be_bytes())
                .expect("invalid header bytes");
            let old_path = irl
                .split_inline(header, new_index_file_path)
                .map_err(revlog_error_from_msg)?;
            Ok(PyBytes::new(py, &get_bytes_from_path(old_path)).unbind())
        })
    }

    fn get_segment_for_revs(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        startrev: PyRevision,
        endrev: PyRevision,
    ) -> PyResult<Py<PyTuple>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            // Here both revisions only come from revlog code, so we assume
            // them to be valid.
            // Panics will alert the offending programmer if not.
            let (offset, data) = irl
                .get_segment_for_revs(Revision(startrev.0), Revision(endrev.0))
                .map_err(revlog_error_from_msg)?;
            let data = PyBytes::new(py, &data);
            Ok(PyTuple::new(
                py,
                &[offset.into_py_any(py)?, data.into_py_any(py)?],
            )?
            .unbind())
        })
    }

    fn raw_text(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        _node: PyObject,
        rev: PyRevision,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            let mut py_bytes = PyBytes::new(py, &[]).unbind();
            irl.raw_text(Revision(rev.0), |size, f| {
                py_bytes = with_pybytes_buffer(py, size, f)?;
                Ok(())
            })
            .map_err(revlog_error_from_msg)?;
            Ok(py_bytes)
        })
    }

    #[allow(clippy::too_many_arguments)]
    #[pyo3(signature = (
        transaction,
        entry,
        data,
        _link,
        offset,
        _sidedata,
        _sidedata_offset,
        index_end,
        data_end,
        _sidedata_end
    ))]
    fn write_entry(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        transaction: PyObject,
        entry: &Bound<'_, PyBytes>,
        data: &Bound<'_, PyTuple>,
        // TODO remove and also from Python
        _link: PyObject,
        offset: usize,
        // Other underscore args are for revlog-v2, which is unimplemented
        _sidedata: PyObject,
        _sidedata_offset: u64,
        index_end: Option<u64>,
        data_end: Option<u64>,
        _sidedata_end: Option<u64>,
    ) -> PyResult<Py<PyTuple>> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            let transaction = PyTransaction::new(transaction);
            let header = data.get_borrowed_item(0)?;
            let header = header.downcast::<PyBytes>()?;
            let data = data.get_borrowed_item(1)?;
            let data = data.downcast::<PyBytes>()?;
            let (idx_pos, data_pos) = irl
                .write_entry(
                    transaction,
                    entry.as_bytes(),
                    (header.as_bytes(), data.as_bytes()),
                    offset,
                    index_end,
                    data_end,
                )
                .map_err(revlog_error_from_msg)?;
            let tuple = PyTuple::new(
                py,
                [idx_pos.into_py_any(py)?, data_pos.into_py_any(py)?],
            )?;
            Ok(tuple.unbind())
        })
    }

    fn delay(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Option<Py<PyBytes>>> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            let path = irl.delay().map_err(revlog_error_from_msg)?;
            Ok(path
                .map(|p| PyBytes::new(py, &get_bytes_from_path(p)).unbind()))
        })
    }

    fn write_pending(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyTuple>> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            let (path, any_pending) =
                irl.write_pending().map_err(revlog_error_from_msg)?;
            let maybe_path = match path {
                Some(path) => PyBytes::new(py, &get_bytes_from_path(path))
                    .unbind()
                    .into_any(),
                None => py.None(),
            };
            Ok(
                PyTuple::new(py, [maybe_path, any_pending.into_py_any(py)?])?
                    .unbind(),
            )
        })
    }

    fn finalize_pending(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_core_write(slf, |_self_ref, mut irl| {
            let path =
                irl.finalize_pending().map_err(revlog_error_from_msg)?;
            Ok(PyBytes::new(py, &get_bytes_from_path(path)).unbind())
        })
    }

    fn _chunk(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        rev: PyRevision,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_core_read(slf, |_self_ref, irl| {
            let chunk = irl
                .chunk_for_rev(Revision(rev.0))
                .map_err(revlog_error_from_msg)?;
            Ok(PyBytes::new(py, &chunk).unbind())
        })
    }

    fn reading(slf: &Bound<'_, Self>) -> PyResult<ReadingContextManager> {
        Ok(ReadingContextManager {
            inner_revlog: slf.clone().unbind(),
        })
    }

    #[pyo3(signature = (transaction, data_end=None, sidedata_end=None))]
    fn writing(
        slf: &Bound<'_, Self>,
        transaction: PyObject,
        data_end: Option<usize>,
        sidedata_end: Option<usize>,
    ) -> PyResult<WritingContextManager> {
        // Only useful in revlog v2
        let _ = sidedata_end;
        Ok(WritingContextManager {
            inner_revlog: slf.clone().unbind(),
            transaction: RwLock::new(PyTransaction::new(transaction)),
            data_end,
        })
    }

    //
    // -- forwarded index methods --
    //

    fn _index_get_rev(
        slf: &Bound<'_, Self>,
        node: &Bound<'_, PyBytes>,
    ) -> PyResult<Option<PyRevision>> {
        let node = node_from_py_bytes(node)?;

        // Do not rewrite this with `Self::with_index_nt_read`: it makes
        // inconditionally a volatile nodetree, and that is not the intent
        // here: the code below specifically avoids that.
        Self::with_core_read(slf, |self_ref, irl| {
            let idx = &irl.index;

            let prev_queries =
                self_ref.nodemap_queries.fetch_add(1, Ordering::Relaxed);
            // Filelogs have no persistent nodemaps and are often small,
            // use a brute force lookup from the end
            // backwards. If there is a very large filelog
            // (automation file that changes every
            // commit etc.), it also seems to work quite well for
            // all measured purposes so far.
            if !self_ref.use_persistent_nodemap && prev_queries <= 3 {
                return Ok(idx
                    .rev_from_node_no_persistent_nodemap(node.into())
                    .ok()
                    .map(Into::into));
            }

            let opt =
                self_ref.get_nodetree(idx)?.read().map_err(map_lock_error)?;
            let nt = opt.as_ref().expect("nodetree should be set");

            let rust_rev =
                nt.find_bin(idx, node.into()).map_err(nodemap_error)?;
            Ok(rust_rev.map(Into::into))
        })
    }

    /// same as `_index_get_rev()` but raises a bare `error.RevlogError` if
    /// node is not found.
    ///
    /// No need to repeat `node` in the exception, `mercurial/revlog.py`
    /// will catch and rewrap with it
    fn _index_rev(
        slf: &Bound<'_, Self>,
        node: &Bound<'_, PyBytes>,
    ) -> PyResult<PyRevision> {
        Self::_index_get_rev(slf, node)?.ok_or_else(revlog_error_bare)
    }

    /// return True if the node exist in the index
    fn _index_has_node(
        slf: &Bound<'_, Self>,
        node: &Bound<'_, PyBytes>,
    ) -> PyResult<bool> {
        Self::_index_get_rev(slf, node).map(|opt| opt.is_some())
    }

    /// find length of shortest hex nodeid of a binary ID
    fn _index_shortest(
        slf: &Bound<'_, Self>,
        node: &Bound<'_, PyBytes>,
    ) -> PyResult<usize> {
        Self::with_index_nt_read(slf, |idx, nt| {
            match nt.unique_prefix_len_node(idx, &node_from_py_bytes(node)?) {
                Ok(Some(l)) => Ok(l),
                Ok(None) => Err(revlog_error_bare()),
                Err(e) => Err(nodemap_error(e)),
            }
        })
    }

    fn _index_partialmatch<'py>(
        slf: &Bound<'py, Self>,
        node: &Bound<'py, PyBytes>,
    ) -> PyResult<Option<Bound<'py, PyBytes>>> {
        Self::with_index_nt_read(slf, |idx, nt| {
            Ok(nt
                .find_bin(idx, node_prefix_from_py_bytes(node)?)
                .map_err(nodemap_error)?
                .map(|rev| py_node_for_rev(slf.py(), idx, rev)))
        })
    }

    /// append an index entry
    fn _index_append(
        slf: &Bound<'_, Self>,
        tup: &Bound<'_, PyTuple>,
    ) -> PyResult<()> {
        // no need to check length: in PyO3 tup.get_item() does return
        // proper errors
        let node_bytes = tup.get_item(7)?.extract()?;
        let node = node_from_py_bytes(&node_bytes)?;

        Self::with_index_nt_write(slf, |idx, nt| {
            let rev = idx.len() as BaseRevision;
            // This is ok since we will immediately add the revision to the
            // index
            let rev = Revision(rev);
            idx.append(py_tuple_to_revision_data_params(tup)?)
                .map_err(revlog_error_from_msg)?;

            nt.insert(idx, &node, rev).map_err(nodemap_error)?;
            Ok(())
        })
    }

    /// Removes one or several entries from the index.
    ///
    /// Historically, on the Mercurial revlog index, `__delitem__` has always
    /// been both for `del idx[r1]` and `del idx[r1:r2]`. In both cases,
    /// all entries starting from `r1` are removed anyway.
    fn _index___delitem__(
        slf: &Bound<'_, Self>,
        arg: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let start = if let Ok(rev) = arg.extract() {
            UncheckedRevision(rev)
        } else {
            // here we could downcast to `PySlice` and use `indices()`, *but*
            // the rust-cpython based version could not do that, and
            // `indices()` does some resolving that makes it not equivalent,
            // e.g., `idx[-1::]` has `start=0`. As we are currently in
            // transition, we keep it the old way (hoping it was consistent
            // with the C index).
            let start = arg.getattr("start")?;
            UncheckedRevision(start.extract()?)
        };

        Self::with_index_nt_write(slf, |idx, nt| {
            // In the case of a slice, the check is possibly already done by
            // `slice.indices`, which is itself an FFI wrapper for CPython's
            // `PySlice_GetIndicesEx`
            // (Python integration tests will tell us)
            let start = idx.check_revision(start).ok_or_else(|| {
                nodemap_error(NodeMapError::RevisionNotInIndex(start))
            })?;
            idx.remove(start).map_err(revlog_error_from_msg)?;
            nt.invalidate_all();
            Self::fill_nodemap(idx, nt)?;
            Ok(())
        })
    }

    /// return the gca set of the given revs
    #[pyo3(signature = (*revs))]
    fn _index_ancestors(
        slf: &Bound<'_, Self>,
        revs: &Bound<'_, PyTuple>,
    ) -> PyResult<PyObject> {
        Self::with_index_read(slf, |idx| {
            let revs: Vec<_> = rev_pyiter_collect(revs, idx)?;
            Ok(PyList::new(
                slf.py(),
                idx.ancestors(&revs)
                    .map_err(graph_error)?
                    .into_iter()
                    .map(PyRevision::from),
            )?
            .into_any()
            .unbind())
        })
    }

    /// return the heads of the common ancestors of the given revs
    #[pyo3(signature = (*revs))]
    fn _index_commonancestorsheads(
        slf: &Bound<'_, Self>,
        revs: &Bound<'_, PyTuple>,
    ) -> PyResult<Py<PyList>> {
        Self::with_index_read(slf, |idx| {
            let revs: Vec<_> = rev_pyiter_collect(revs, idx)?;
            revs_py_list(
                slf.py(),
                idx.common_ancestor_heads(&revs).map_err(graph_error)?,
            )
        })
    }

    /// Clear the index caches and inner py_class data.
    /// It is Python's responsibility to call `update_nodemap_data` again.
    fn _index_clearcaches(slf: &Bound<'_, Self>) -> PyResult<()> {
        Self::with_index_write(slf, |idx| {
            idx.clear_caches();
            Ok(())
        })?;

        let mut self_ref = slf.borrow_mut();
        self_ref.nt.write().map_err(map_lock_error)?.take();
        self_ref.docket.take();
        self_ref.nodemap_mmap.take();
        self_ref.head_revs_py_list.take();
        self_ref.head_node_ids_py_list.take();
        Ok(())
    }

    /// return the raw binary string representing a revision
    fn _index_entry_binary(
        slf: &Bound<'_, Self>,
        rev: PyRevision,
    ) -> PyResult<Py<PyBytes>> {
        let rev: UncheckedRevision = rev.into();
        Self::with_index_read(slf, |idx| {
            idx.check_revision(rev)
                .and_then(|r| idx.entry_binary(r))
                .map(|rust_bytes| PyBytes::new(slf.py(), rust_bytes).unbind())
                .ok_or_else(|| rev_not_in_index(rev))
        })
    }

    /// return a binary packed version of the header
    fn _index_pack_header(
        slf: &Bound<'_, Self>,
        header: i32,
    ) -> PyResult<Py<PyBytes>> {
        let packed =
            Self::with_index_read(slf, |idx| Ok(idx.pack_header(header)))?;
        Ok(PyBytes::new(slf.py(), &packed).unbind())
    }

    /// compute phases
    fn _index_computephasesmapsets(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        roots: &Bound<'_, PyDict>,
    ) -> PyResult<Py<PyTuple>> {
        let (len, phase_maps) = Self::with_index_read(slf, |idx| {
            let extracted_roots: PyResult<HashMap<Phase, Vec<Revision>>> =
                roots
                    .iter()
                    .map(|(phase, revs)| {
                        let phase = Phase::try_from(phase.extract::<usize>()?)
                            .map_err(|_| revlog_error_bare())?;
                        let revs: Vec<Revision> =
                            rev_pyiter_collect(&revs, idx)?;
                        Ok((phase, revs))
                    })
                    .collect();
            idx.compute_phases_map_sets(extracted_roots?)
                .map_err(graph_error)
        })?;
        // Ugly hack, but temporary (!)
        const IDX_TO_PHASE_NUM: [usize; 4] = [1, 2, 32, 96];
        let py_phase_maps = PyDict::new(py);
        for (i, roots) in phase_maps.into_iter().enumerate() {
            py_phase_maps.set_item(
                IDX_TO_PHASE_NUM[i],
                revs_py_set(py, roots)?.into_any(),
            )?;
        }
        Ok((len, py_phase_maps).into_pyobject(py)?.unbind())
    }

    /// reachableroots
    #[pyo3(signature = (*args))]
    fn _index_reachableroots2(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        args: &Bound<'_, PyTuple>,
    ) -> PyResult<Py<PyList>> {
        // TODO what was the point of having a signature with variable args?
        let min_root = UncheckedRevision(args.get_item(0)?.extract()?);
        let heads = args.get_item(1)?;
        let roots = args.get_item(2)?;
        let include_path: bool = args.get_item(3)?.extract()?;

        let as_set = Self::with_index_read(slf, |idx| {
            let heads = rev_pyiter_collect_or_else(&heads, idx, |_rev| {
                PyIndexError::new_err("head out of range")
            })?;
            let roots: Result<_, _> = roots
                .try_iter()?
                .map(|r| {
                    r.and_then(|o| match o.extract::<PyRevision>() {
                        Ok(r) => Ok(UncheckedRevision(r.0)),
                        Err(e) => Err(e),
                    })
                })
                .collect();
            idx.reachable_roots(min_root, heads, roots?, include_path)
                .map_err(graph_error)
        })?;

        revs_py_list(py, as_set)
    }

    #[pyo3(signature = (*args))]
    fn _index_headrevs(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        args: &Bound<'_, PyTuple>,
    ) -> PyResult<Py<PyList>> {
        let (filtered_revs, stop_rev) = match args.len() {
            0 => Ok((None, None)),
            1 => Ok((Some(args.get_item(0)?), None)),
            2 => Ok((Some(args.get_item(0)?), Some(args.get_item(1)?))),
            _ => Err(PyTypeError::new_err("too many arguments")),
        }?;
        let stop_rev = stop_rev
            .map(|o| o.extract::<Option<i32>>())
            .transpose()?
            .flatten();
        let filtered_revs = filtered_revs.filter(|o| !o.is_none());

        let (from_core, stop_rev) = Self::with_index_read(slf, |idx| {
            let stop_rev = stop_rev
                // should this not just be the normal checking?
                .filter(|rev| 0 <= *rev && *rev < idx.len() as BaseRevision)
                .map(Revision);

            let from_core = if let Some(filtered_revs) = filtered_revs {
                let filtered_revs = rev_pyiter_collect(&filtered_revs, idx)?;
                idx.head_revs_advanced(
                    &filtered_revs,
                    stop_rev,
                    stop_rev.is_none(),
                )
            } else if stop_rev.is_some() {
                idx.head_revs_advanced(&HashSet::new(), stop_rev, false)
            } else {
                idx.head_revs_shortcut()
            }
            .map_err(graph_error)?;
            Ok((from_core, stop_rev))
        })?;

        if stop_rev.is_some() {
            // we don't cache result for now
            let new_heads =
                from_core.expect("this case should not be cached yet");

            revs_py_list(py, new_heads)
        } else {
            if let Some(new_heads) = from_core {
                Self::cache_new_heads_py_list(slf, new_heads)?;
            }

            Ok(slf
                .borrow()
                .head_revs_py_list
                .as_ref()
                .expect("head revs should be cached")
                .clone_ref(py))
        }
    }

    /// get head nodeids
    fn _index_head_node_ids(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyList>> {
        let (head_revs, head_nodes) = Self::with_index_read(slf, |idx| {
            // We don't use the shortcut here, as it's actually slower to loop
            // through the cached `PyList` than to re-do the whole
            // conversion for large lists, which are the performance
            // sensitive ones anyway.
            let head_revs = idx.head_revs().map_err(graph_error)?;
            let head_nodes = PyList::new(
                py,
                head_revs.iter().map(|r| {
                    PyBytes::new(
                        py,
                        idx.node(*r)
                            .expect("rev should have been in the index")
                            .as_bytes(),
                    )
                    .unbind()
                }),
            )?
            .unbind();
            Ok((head_revs, head_nodes))
        })?;

        Self::cache_new_heads_py_list(slf, head_revs)?;
        // TODO discussion with Alphare: in hg-cpython,
        // `cache_new_heads_node_ids_py_list` reconverts `head_nodes`,
        // to store it in the cache attr that is **not actually used**.
        // Should we drop the idea of this cache definition or actually
        // use it? Perhaps in a later move for perf assessment?
        Ok(head_nodes)
    }

    /// get diff in head revisions
    fn _index_headrevsdiff(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        begin: PyRevision,
        end: PyRevision,
    ) -> PyResult<Py<PyTuple>> {
        let begin: BaseRevision = begin.0 - 1;
        let end: BaseRevision = end.0 - 1;
        let (removed, added) = Self::with_index_read(slf, |idx| {
            idx.head_revs_diff(
                check_revision(idx, begin)?,
                check_revision(idx, end)?,
            )
            .map_err(graph_error)
        })?;
        let py_removed = revs_py_list(py, removed)?;
        let py_added = revs_py_list(py, added)?;
        Ok((py_removed, py_added).into_pyobject(py)?.unbind())
    }

    /// True if the object is a snapshot
    fn _index_issnapshot(
        slf: &Bound<'_, Self>,
        rev: PyRevision,
    ) -> PyResult<bool> {
        let rev: UncheckedRevision = rev.into();
        let rev = Self::with_index_read(slf, |idx| {
            idx.check_revision(rev).ok_or_else(|| rev_not_in_index(rev))
        })?;
        Self::with_core_read(slf, |_self_ref, irl| {
            irl.is_snapshot(rev)
                .map_err(|e| PyValueError::new_err(e.to_string()))
        })
    }

    /// Gather snapshot data in a cache dict
    fn _index_findsnapshots(
        slf: &Bound<'_, Self>,
        cache: &Bound<'_, PyDict>,
        start_rev: PyRevision,
        end_rev: PyRevision,
    ) -> PyResult<()> {
        let mut cache = PySnapshotsCache(cache);
        Self::with_index_read(slf, |idx| {
            idx.find_snapshots(start_rev.into(), end_rev.into(), &mut cache)
                .map_err(|_| revlog_error_bare())
        })?;
        Ok(())
    }

    /// determine revisions with deltas to reconstruct fulltext
    #[pyo3(signature = (rev, stop_rev))]
    fn _index_deltachain(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        rev: PyRevision,
        stop_rev: Option<PyRevision>,
    ) -> PyResult<Py<PyTuple>> {
        let rev: UncheckedRevision = rev.into();
        let stop_rev: Option<UncheckedRevision> = stop_rev.map(Into::into);

        let (chain, stopped) = Self::with_index_read(slf, |idx| {
            let rev = idx.check_revision(rev).ok_or_else(|| {
                nodemap_error(NodeMapError::RevisionNotInIndex(rev))
            })?;
            let stop_rev = stop_rev
                .map(|r| {
                    idx.check_revision(r).ok_or_else(|| {
                        nodemap_error(NodeMapError::RevisionNotInIndex(
                            rev.into(),
                        ))
                    })
                })
                .transpose()?;
            idx.delta_chain(rev, stop_rev)
                .map_err(|e| PyValueError::new_err(e.to_string()))
        })?;

        let py_chain = revs_py_list(py, chain)?.into_any();
        let py_stopped =
            PyBool::new(py, stopped).to_owned().unbind().into_any();
        Ok((py_chain, py_stopped).into_pyobject(py)?.unbind())
    }

    /// slice planned chunk read to reach a density threshold
    fn _index_slicechunktodensity(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        revs: &Bound<'_, PyAny>,
        target_density: f64,
        min_gap_size: usize,
    ) -> PyResult<PyObject> {
        let as_nested_vec =
            Self::with_index_read(slf, |idx| {
                let revs: Vec<_> = rev_pyiter_collect(revs, idx)?;
                Ok(idx.slice_chunk_to_density(
                    &revs,
                    target_density,
                    min_gap_size,
                ))
            })?;
        let res_len = as_nested_vec.len();

        // cannot build the outer sequence from iterator, because
        // `rev_py_list()` returns `Result<T>` instead of `T`.
        let mut res = Vec::with_capacity(res_len);
        for chunk in as_nested_vec {
            res.push(revs_py_list(py, chunk)?.into_any());
        }
        // This is just to do the same as C, not sure why it does this
        Ok(if res_len == 1 {
            PyTuple::new(py, res)?.unbind().into_any()
        } else {
            PyList::new(py, res)?.unbind().into_any()
        })
    }

    fn _index___len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_index_read(slf, |idx| Ok(idx.len()))
    }

    fn _index___getitem__(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        key: &Bound<'_, PyAny>,
    ) -> PyResult<PyObject> {
        Self::with_index_read(slf, |idx| {
            match key.extract::<BaseRevision>() {
                Ok(key_as_int) => {
                    let entry_params = if key_as_int == NULL_REVISION.0 {
                        RevisionDataParams::default()
                    } else {
                        let rev = UncheckedRevision(key_as_int);
                        match idx.entry_as_params(rev) {
                            Some(e) => e,
                            None => {
                                return Err(PyIndexError::new_err(
                                    "revlog index out of range",
                                ));
                            }
                        }
                    };
                    Ok(revision_data_params_to_py_tuple(py, entry_params)?
                        .into_any()
                        .unbind())
                }
                // Case when key is a binary Node ID (lame: we're re-unlocking)
                _ => Self::_index_get_rev(slf, key.downcast::<PyBytes>()?)?
                    .map_or_else(
                        || Ok(py.None()),
                        |py_rev| Ok(py_rev.into_pyobject(py)?.unbind().into()),
                    ),
            }
        })
    }

    /// Returns the full nodemap bytes to be written as-is to disk
    fn _index_nodemap_data_all(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<Py<PyBytes>> {
        Self::with_index_nt_write(slf, |idx, nt| {
            let old_nt = std::mem::take(nt);
            let (readonly, bytes) = old_nt.into_readonly_and_added_bytes();

            // If there's anything readonly, we need to build the data again
            // from scratch
            let bytes = if readonly.len() > 0 {
                let mut nt =
                    CoreNodeTree::load_bytes(Box::<Vec<_>>::default(), 0);
                Self::fill_nodemap(idx, &mut nt)?;

                let (readonly, bytes) = nt.into_readonly_and_added_bytes();
                assert_eq!(readonly.len(), 0);

                bytes
            } else {
                bytes
            };

            let bytes = PyBytes::new(py, &bytes);
            Ok(bytes.unbind())
        })
    }

    /// Returns the last saved docket along with the size of any changed data
    /// (in number of blocks), and said data as bytes.
    fn _index_nodemap_data_incremental(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
    ) -> PyResult<PyObject> {
        let mut self_ref = slf.borrow_mut();
        let docket = &mut self_ref.docket;
        let docket = match docket.as_ref() {
            Some(d) => d.clone_ref(py),
            None => return Ok(py.None()),
        };
        drop(self_ref);

        Self::with_core_write(slf, |self_ref, irl| {
            let mut nt = self_ref
                .get_nodetree(&irl.index)?
                .write()
                .map_err(map_lock_error)?;
            let nt = nt.take().expect("nodetree should be set");
            let masked_blocks = nt.masked_readonly_blocks();
            let (_, data) = nt.into_readonly_and_added_bytes();
            let changed = masked_blocks * std::mem::size_of::<Block>();

            Ok(PyTuple::new(
                py,
                [
                    docket,
                    changed.into_py_any(py)?,
                    PyBytes::new(py, &data).into_py_any(py)?,
                ],
            )?
            .unbind()
            .into_any())
        })
    }

    /// Update the nodemap from the new (mmaped) data.
    /// The docket is kept as a reference for later incremental calls.
    fn _index_update_nodemap_data(
        slf: &Bound<'_, Self>,
        py: Python<'_>,
        docket: &Bound<'_, PyAny>,
        nm_data: &Bound<'_, PyAny>,
    ) -> PyResult<PyObject> {
        // Safety: we keep the buffer around inside the class as `nodemap_mmap`
        let (buf, bytes) = unsafe { take_buffer_with_slice(nm_data)? };
        let len = buf.item_count();
        let data_tip =
            docket.getattr("tip_rev")?.extract::<BaseRevision>()?.into();

        let mut nt = CoreNodeTree::load_bytes(bytes, len);

        Self::with_index_read(slf, |idx| {
            let data_tip = idx.check_revision(data_tip).ok_or_else(|| {
                nodemap_error(NodeMapError::RevisionNotInIndex(data_tip))
            })?;
            let current_tip = idx.len();

            for r in (data_tip.0 + 1)..current_tip as BaseRevision {
                let rev = Revision(r);
                // in this case node() won't ever return None
                nt.insert(idx, idx.node(rev).expect("node should exist"), rev)
                    .map_err(nodemap_error)?;
            }

            Ok(py.None())
        })?;

        let mut self_ref = slf.borrow_mut();
        self_ref.docket.replace(docket.clone().unbind());
        self_ref.nodemap_mmap = Some(buf);
        self_ref.nt.write().map_err(map_lock_error)?.replace(nt);

        Ok(py.None())
    }

    #[getter]
    fn _index_entry_size(&self) -> usize {
        INDEX_ENTRY_SIZE
    }

    #[getter]
    fn _index_rust_ext_compat(&self) -> i32 {
        1
    }

    #[getter]
    fn _index_is_rust(&self) -> bool {
        true
    }
}

impl InnerRevlog {
    /// Take the lock on `slf.irl` for reading and call a closure.
    ///
    /// This serves the purpose to keep the needed intermediate [`PyRef`]
    /// that must be obtained to access the data from the [`Bound`] reference
    /// and of which the locked [`CoreInnerRevlog`] depends.
    /// This also provides releasing of the [`PyRef`] as soon as the closure
    /// is done, which is crucial if the caller needs to obtain a [`PyRefMut`]
    /// later on.
    ///
    /// In the closure, we hand back the intermediate [`PyRef`] that
    /// has been generated so that the closure can access more attributes.
    fn with_core_read<'py, T>(
        slf: &Bound<'py, Self>,
        f: impl FnOnce(
            &PyRef<'py, Self>,
            RwLockReadGuard<CoreInnerRevlog>,
        ) -> PyResult<T>,
    ) -> PyResult<T> {
        let self_ref = slf.borrow();
        // Safety: the owner is the right one. We will anyway
        // not actually `share` it. Perhaps pyo3-sharedref should provide
        // something less scary for this kind of usage.
        let shareable_ref = unsafe { self_ref.irl.borrow_with_owner(slf) };
        let guard = shareable_ref.try_read().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
    }

    /// Take the lock on `slf.irl` for writing and call a closure.
    ///
    /// See [`Self::with_core_read`] for more explanations.
    fn with_core_write<'py, T>(
        slf: &Bound<'py, Self>,
        f: impl FnOnce(
            &PyRef<'py, Self>,
            RwLockWriteGuard<CoreInnerRevlog>,
        ) -> PyResult<T>,
    ) -> PyResult<T> {
        let self_ref = slf.borrow();
        // Safety: the owner is the right one. We will anyway
        // not actually `share` it. Perhaps pyo3-sharedref should provide
        // something less scary for this kind of usage.
        let shareable_ref = unsafe { self_ref.irl.borrow_with_owner(slf) };
        let guard = shareable_ref.try_write().map_err(map_try_lock_error)?;
        f(&self_ref, guard)
    }

    fn with_index_read<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(&Index) -> PyResult<T>,
    ) -> PyResult<T> {
        Self::with_core_read(slf, |_, guard| f(&guard.index))
    }

    fn with_index_write<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(&mut Index) -> PyResult<T>,
    ) -> PyResult<T> {
        Self::with_core_write(slf, |_, mut guard| f(&mut guard.index))
    }

    /// Lock `slf` for reading and execute a closure on its [`Index`] and
    /// [`NodeTree`]
    ///
    /// The [`NodeTree`] is initialized an filled before hand if needed.
    fn with_index_nt_read<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(&Index, &CoreNodeTree) -> PyResult<T>,
    ) -> PyResult<T> {
        Self::with_core_read(slf, |self_ref, guard| {
            let idx = &guard.index;
            let nt =
                self_ref.get_nodetree(idx)?.read().map_err(map_lock_error)?;
            let nt = nt.as_ref().expect("nodetree should be set");
            f(idx, nt)
        })
    }

    fn with_index_nt_write<T>(
        slf: &Bound<'_, Self>,
        f: impl FnOnce(&mut Index, &mut CoreNodeTree) -> PyResult<T>,
    ) -> PyResult<T> {
        Self::with_core_write(slf, |self_ref, mut guard| {
            let idx = &mut guard.index;
            let mut nt = self_ref
                .get_nodetree(idx)?
                .write()
                .map_err(map_lock_error)?;
            let nt = nt.as_mut().expect("nodetree should be set");
            f(idx, nt)
        })
    }

    /// Fill a [`CoreNodeTree`] by doing a full iteration on the given
    /// [`Index`]
    ///
    /// # Python exceptions
    /// Raises `ValueError` if `nt` has existing data that is inconsistent
    /// with `idx`.
    fn fill_nodemap(idx: &Index, nt: &mut CoreNodeTree) -> PyResult<()> {
        for r in 0..idx.len() {
            let rev = Revision(r as BaseRevision);
            // in this case node() won't ever return None
            nt.insert(idx, idx.node(rev).expect("node should exist"), rev)
                .map_err(nodemap_error)?
        }
        Ok(())
    }

    /// Return a working NodeTree of this InnerRevlog
    ///
    /// In case the NodeTree has not been initialized yet (in particular
    /// not from persistent data at instantiation), it is created and
    /// filled right away from the index.
    ///
    /// Technically, the returned NodeTree is still behind the lock of
    /// the `nt` field, hence still wrapped in an [`Option`]. Callers
    /// will need to take the lock and unwrap with `expect()`.
    ///
    /// # Python exceptions
    /// The case mentioned in [`Self::fill_nodemap()`] cannot happen, as the
    /// NodeTree is empty when it is called.
    fn get_nodetree(
        &self,
        idx: &Index,
    ) -> PyResult<&RwLock<Option<CoreNodeTree>>> {
        if self.nt.read().map_err(map_lock_error)?.is_none() {
            let readonly = Box::<Vec<_>>::default();
            let mut nt = CoreNodeTree::load_bytes(readonly, 0);
            Self::fill_nodemap(idx, &mut nt)?;
            self.nt.write().map_err(map_lock_error)?.replace(nt);
        }
        Ok(&self.nt)
    }

    fn cache_new_heads_py_list(
        slf: &Bound<'_, Self>,
        new_heads: Vec<Revision>,
    ) -> PyResult<Py<PyList>> {
        let py = slf.py();
        let new_heads_py_list = revs_py_list(py, new_heads)?;
        slf.borrow_mut().head_revs_py_list =
            Some(new_heads_py_list.clone_ref(py));
        // TODO is returning really useful?
        Ok(new_heads_py_list)
    }
}

#[pyclass]
struct NodeTree {
    nt: RwLock<CoreNodeTree>,
    index: SharedByPyObject<PySharedIndex>,
}

#[pymethods]
impl NodeTree {
    #[new]
    // The share/mapping should be set apart to become the PyO3 homolog of
    // `py_rust_index_to_graph`
    fn new(index_proxy: &Bound<'_, PyAny>) -> PyResult<Self> {
        let py_irl = index_proxy.getattr("inner")?;
        let py_irl_ref = py_irl.downcast::<InnerRevlog>()?.borrow();
        let shareable_irl = &py_irl_ref.irl;

        // Safety: the owner is the actual one and we do not leak any
        // internal reference.
        let index = unsafe {
            shareable_irl.share_map(&py_irl, |irl| (&irl.index).into())
        };
        let nt = CoreNodeTree::default(); // in-RAM, fully mutable

        Ok(Self {
            nt: nt.into(),
            index,
        })
    }

    /// Tell whether the NodeTree is still valid
    ///
    /// In case of mutation of the index, the given results are not
    /// guaranteed to be correct, and in fact, the methods borrowing
    /// the inner index would fail because of `PySharedRef` poisoning
    /// (generation-based guard), same as iterating on a `dict` that has
    /// been meanwhile mutated.
    fn is_invalidated(&self, py: Python<'_>) -> PyResult<bool> {
        // Safety: we don't leak any reference derived from self.index, as
        // we only check errors
        let result = unsafe { self.index.try_borrow(py) };
        // two cases for result to be an error:
        // - the index has previously been mutably borrowed
        // - there is currently a mutable borrow
        // in both cases this amounts for previous results related to
        // the index to still be valid.
        Ok(result.is_err())
    }

    fn insert(&self, py: Python<'_>, rev: PyRevision) -> PyResult<()> {
        // Safety: we don't leak any reference derived from self.index,
        // as `nt.insert` does not store direct references
        let idx = &*unsafe { self.index.try_borrow(py)? };

        let rev = check_revision(idx, rev)?;
        if rev == NULL_REVISION {
            return Err(rev_not_in_index(rev.into()));
        }

        let entry = idx.inner().get_entry(rev).expect("entry should exist");
        let mut nt = self.nt.write().map_err(map_lock_error)?;
        nt.insert(idx, entry.hash(), rev).map_err(nodemap_error)
    }

    fn shortest(
        &self,
        py: Python<'_>,
        node: &Bound<'_, PyBytes>,
    ) -> PyResult<usize> {
        let nt = self.nt.read().map_err(map_lock_error)?;
        // Safety: we don't leak any reference derived from self.index
        // as returned type is Copy
        let idx = &*unsafe { self.index.try_borrow(py)? };
        nt.unique_prefix_len_node(idx, &node_from_py_bytes(node)?)
            .map_err(nodemap_error)?
            .ok_or_else(revlog_error_bare)
    }

    /// Lookup by node hex prefix in the NodeTree, returning revision number.
    ///
    /// This is not part of the classical NodeTree API, but is good enough
    /// for unit testing, as in `test-rust-revlog.py`.
    fn prefix_rev_lookup(
        &self,
        py: Python<'_>,
        node_prefix: &Bound<'_, PyBytes>,
    ) -> PyResult<Option<PyRevision>> {
        let prefix = node_prefix_from_py_bytes(node_prefix)?;
        let nt = self.nt.read().map_err(map_lock_error)?;
        // Safety: we don't leak any reference derived from self.index
        // as returned type is Copy
        let idx = &*unsafe { self.index.try_borrow(py)? };
        Ok(nt
            .find_bin(idx, prefix)
            .map_err(nodemap_error)?
            .map(|r| r.into()))
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "revlog")?;
    m.add_class::<InnerRevlog>()?;
    m.add_class::<NodeTree>()?;
    m.add_class::<ReadingContextManager>()?;
    Ok(m)
}
