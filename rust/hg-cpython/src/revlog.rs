// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
#![allow(non_snake_case)]

use crate::{
    conversion::{rev_pyiter_collect, rev_pyiter_collect_or_else},
    pybytes_deref::{PyBufferDeref, PyBytesDeref},
    utils::{node_from_py_bytes, node_from_py_object},
    PyRevision,
};
use cpython::{
    buffer::{Element, PyBuffer},
    exc::{IndexError, ValueError},
    ObjectProtocol, PyBool, PyBytes, PyClone, PyDict, PyErr, PyInt, PyList,
    PyModule, PyObject, PyResult, PySet, PySharedRef, PyTuple, PyType, Python,
    PythonObject, ToPyObject, UnsafePyLeaked,
};
use hg::{
    errors::HgError,
    fncache::FnCache,
    revlog::{
        compression::CompressionConfig,
        index::{
            Index, IndexHeader, Phase, RevisionDataParams, SnapshotsCache,
            INDEX_ENTRY_SIZE,
        },
        inner_revlog::{InnerRevlog as CoreInnerRevlog, RevisionBuffer},
        nodemap::{Block, NodeMap, NodeMapError, NodeTree as CoreNodeTree},
        options::{
            RevlogDataConfig, RevlogDeltaConfig, RevlogFeatureConfig,
            RevlogOpenOptions,
        },
        Graph, NodePrefix, RevlogError, RevlogIndex, RevlogType,
    },
    transaction::Transaction,
    utils::files::{get_bytes_from_path, get_path_from_bytes},
    vfs::FnCacheVfs,
    BaseRevision, Node, Revision, UncheckedRevision, NULL_REVISION,
};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, HashSet},
    sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    sync::OnceLock,
};
use vcsgraph::graph::Graph as VCSGraph;

pub struct PySharedIndex {
    /// The underlying hg-core index
    pub inner: &'static Index,
}

/// Return a Struct implementing the Graph trait
pub(crate) fn py_rust_index_to_graph(
    py: Python,
    index_proxy: PyObject,
) -> PyResult<UnsafePyLeaked<PySharedIndex>> {
    let inner_revlog = index_proxy.getattr(py, "inner")?;
    let inner_revlog = inner_revlog.extract::<InnerRevlog>(py)?;
    let leaked = inner_revlog.inner(py).leak_immutable();
    // Safety: we don't leak the "faked" reference out of the `UnsafePyLeaked`
    Ok(unsafe { leaked.map(py, |idx| PySharedIndex { inner: &idx.index }) })
}

impl Clone for PySharedIndex {
    fn clone(&self) -> Self {
        Self { inner: self.inner }
    }
}

impl Graph for PySharedIndex {
    #[inline(always)]
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], hg::GraphError> {
        self.inner.parents(rev)
    }
}

impl VCSGraph for PySharedIndex {
    #[inline(always)]
    fn parents(
        &self,
        rev: BaseRevision,
    ) -> Result<vcsgraph::graph::Parents, vcsgraph::graph::GraphReadError>
    {
        // FIXME This trait should be reworked to decide between Revision
        // and UncheckedRevision, get better errors names, etc.
        match Graph::parents(self, Revision(rev)) {
            Ok(parents) => {
                Ok(vcsgraph::graph::Parents([parents[0].0, parents[1].0]))
            }
            Err(hg::GraphError::ParentOutOfRange(rev)) => {
                Err(vcsgraph::graph::GraphReadError::KeyedInvalidKey(rev.0))
            }
            Err(hg::GraphError::ParentOutOfOrder(_)) => {
                Err(vcsgraph::graph::GraphReadError::InconsistentGraphData)
            }
        }
    }
}

impl RevlogIndex for PySharedIndex {
    fn len(&self) -> usize {
        self.inner.len()
    }
    fn node(&self, rev: Revision) -> Option<&Node> {
        self.inner.node(rev)
    }
}

/// Take a (potentially) mmap'ed buffer, and return the underlying Python
/// buffer along with the Rust slice into said buffer. We need to keep the
/// Python buffer around, otherwise we'd get a dangling pointer once the buffer
/// is freed from Python's side.
///
/// # Safety
///
/// The caller must make sure that the buffer is kept around for at least as
/// long as the slice.
#[deny(unsafe_op_in_unsafe_fn)]
unsafe fn mmap_keeparound(
    py: Python,
    data: PyObject,
) -> PyResult<(
    PyBuffer,
    Box<dyn std::ops::Deref<Target = [u8]> + Send + Sync + 'static>,
)> {
    let buf = PyBuffer::get(py, &data)?;
    let len = buf.item_count();

    // Build a slice from the mmap'ed buffer data
    let cbuf = buf.buf_ptr();
    let bytes = if std::mem::size_of::<u8>() == buf.item_size()
        && buf.is_c_contiguous()
        && u8::is_compatible_format(buf.format())
    {
        unsafe { std::slice::from_raw_parts(cbuf as *const u8, len) }
    } else {
        return Err(PyErr::new::<ValueError, _>(
            py,
            "buffer has an invalid memory representation".to_string(),
        ));
    };

    Ok((buf, Box::new(bytes)))
}

fn py_tuple_to_revision_data_params(
    py: Python,
    tuple: PyTuple,
) -> PyResult<RevisionDataParams> {
    if tuple.len(py) < 8 {
        // this is better than the panic promised by tup.get_item()
        return Err(PyErr::new::<IndexError, _>(
            py,
            "tuple index out of range",
        ));
    }
    let offset_or_flags: u64 = tuple.get_item(py, 0).extract(py)?;
    let node_id = tuple
        .get_item(py, 7)
        .extract::<PyBytes>(py)?
        .data(py)
        .try_into()
        .expect("nodeid should be set");
    let flags = (offset_or_flags & 0xFFFF) as u16;
    let data_offset = offset_or_flags >> 16;
    Ok(RevisionDataParams {
        flags,
        data_offset,
        data_compressed_length: tuple.get_item(py, 1).extract(py)?,
        data_uncompressed_length: tuple.get_item(py, 2).extract(py)?,
        data_delta_base: tuple.get_item(py, 3).extract(py)?,
        link_rev: tuple.get_item(py, 4).extract(py)?,
        parent_rev_1: tuple.get_item(py, 5).extract(py)?,
        parent_rev_2: tuple.get_item(py, 6).extract(py)?,
        node_id,
        ..Default::default()
    })
}
fn revision_data_params_to_py_tuple(
    py: Python,
    params: RevisionDataParams,
) -> PyTuple {
    PyTuple::new(
        py,
        &[
            params.data_offset.into_py_object(py).into_object(),
            params
                .data_compressed_length
                .into_py_object(py)
                .into_object(),
            params
                .data_uncompressed_length
                .into_py_object(py)
                .into_object(),
            params.data_delta_base.into_py_object(py).into_object(),
            params.link_rev.into_py_object(py).into_object(),
            params.parent_rev_1.into_py_object(py).into_object(),
            params.parent_rev_2.into_py_object(py).into_object(),
            PyBytes::new(py, &params.node_id)
                .into_py_object(py)
                .into_object(),
            params._sidedata_offset.into_py_object(py).into_object(),
            params
                ._sidedata_compressed_length
                .into_py_object(py)
                .into_object(),
            params
                .data_compression_mode
                .into_py_object(py)
                .into_object(),
            params
                ._sidedata_compression_mode
                .into_py_object(py)
                .into_object(),
            params._rank.into_py_object(py).into_object(),
        ],
    )
}

struct PySnapshotsCache<'p> {
    py: Python<'p>,
    dict: PyDict,
}

impl<'p> SnapshotsCache for PySnapshotsCache<'p> {
    fn insert_for(
        &mut self,
        rev: BaseRevision,
        value: BaseRevision,
    ) -> Result<(), RevlogError> {
        let pyvalue = value.into_py_object(self.py).into_object();
        match self.dict.get_item(self.py, rev) {
            Some(obj) => obj
                .extract::<PySet>(self.py)
                .and_then(|set| set.add(self.py, pyvalue)),
            None => PySet::new(self.py, vec![pyvalue])
                .and_then(|set| self.dict.set_item(self.py, rev, set)),
        }
        .map_err(|_| {
            RevlogError::Other(HgError::unsupported(
                "Error in Python caches handling",
            ))
        })
    }
}

// There are no static generics in Rust (because their implementation is hard,
// I'm guessing it's due to different compilation stages, etc.).
// So manually generate all three caches and use them in `with_filelog_cache`.
static DELTA_CONFIG_CACHE: OnceLock<(PyObject, RevlogDeltaConfig)> =
    OnceLock::new();
static DATA_CONFIG_CACHE: OnceLock<(PyObject, RevlogDataConfig)> =
    OnceLock::new();
static FEATURE_CONFIG_CACHE: OnceLock<(PyObject, RevlogFeatureConfig)> =
    OnceLock::new();

/// Cache the first conversion from Python -> Rust config for all filelogs to
/// save on conversion time when called in a loop.
fn with_filelog_cache<T: Copy>(
    py: Python,
    py_config: &PyObject,
    revlog_type: RevlogType,
    cache: &OnceLock<(PyObject, T)>,
    callback: impl Fn() -> PyResult<T>,
) -> PyResult<T> {
    let mut was_cached = false;
    if revlog_type == RevlogType::Filelog {
        if let Some((cached_py_config, rust_config)) = cache.get() {
            was_cached = true;
            // All filelogs in a given repository *most likely* have the
            // exact same config, but it's not impossible that some extensions
            // do some magic with configs or that this code will be used
            // for longer-running processes. So compare the source `PyObject`
            // in case the source changed, at the cost of some overhead.
            // We can't use `py_config.eq(cached_py_config)` because all config
            // objects are different in Python and `a is b` is false.
            if py_config.compare(py, cached_py_config)?.is_eq() {
                return Ok(*rust_config);
            }
        }
    }
    let config = callback()?;
    // Do not call the lock unnecessarily if it's already been set.
    if !was_cached && revlog_type == RevlogType::Filelog {
        cache.set((py_config.clone_ref(py), config)).ok();
    }
    Ok(config)
}

fn extract_delta_config(
    py: Python,
    py_config: PyObject,
    revlog_type: RevlogType,
) -> PyResult<RevlogDeltaConfig> {
    let get_delta_config = || {
        let max_deltachain_span = py_config
            .getattr(py, "max_deltachain_span")?
            .extract::<i64>(py)?;

        let revlog_delta_config = RevlogDeltaConfig {
            general_delta: py_config
                .getattr(py, "general_delta")?
                .extract(py)?,
            sparse_revlog: py_config
                .getattr(py, "sparse_revlog")?
                .extract(py)?,
            max_chain_len: py_config
                .getattr(py, "max_chain_len")?
                .extract(py)?,
            max_deltachain_span: if max_deltachain_span < 0 {
                None
            } else {
                Some(max_deltachain_span as u64)
            },
            upper_bound_comp: py_config
                .getattr(py, "upper_bound_comp")?
                .extract(py)?,
            delta_both_parents: py_config
                .getattr(py, "delta_both_parents")?
                .extract(py)?,
            candidate_group_chunk_size: py_config
                .getattr(py, "candidate_group_chunk_size")?
                .extract(py)?,
            debug_delta: py_config.getattr(py, "debug_delta")?.extract(py)?,
            lazy_delta: py_config.getattr(py, "lazy_delta")?.extract(py)?,
            lazy_delta_base: py_config
                .getattr(py, "lazy_delta_base")?
                .extract(py)?,
        };
        Ok(revlog_delta_config)
    };
    with_filelog_cache(
        py,
        &py_config,
        revlog_type,
        &DELTA_CONFIG_CACHE,
        get_delta_config,
    )
}

fn extract_data_config(
    py: Python,
    py_config: PyObject,
    revlog_type: RevlogType,
) -> PyResult<RevlogDataConfig> {
    let get_data_config = || {
        Ok(RevlogDataConfig {
            try_pending: py_config.getattr(py, "try_pending")?.extract(py)?,
            try_split: py_config.getattr(py, "try_split")?.extract(py)?,
            check_ambig: py_config.getattr(py, "check_ambig")?.extract(py)?,
            mmap_large_index: py_config
                .getattr(py, "mmap_large_index")?
                .extract(py)?,
            mmap_index_threshold: py_config
                .getattr(py, "mmap_index_threshold")?
                .extract(py)?,
            chunk_cache_size: py_config
                .getattr(py, "chunk_cache_size")?
                .extract(py)?,
            uncompressed_cache_factor: py_config
                .getattr(py, "uncompressed_cache_factor")?
                .extract(py)?,
            uncompressed_cache_count: py_config
                .getattr(py, "uncompressed_cache_count")?
                .extract(py)?,
            with_sparse_read: py_config
                .getattr(py, "with_sparse_read")?
                .extract(py)?,
            sr_density_threshold: py_config
                .getattr(py, "sr_density_threshold")?
                .extract(py)?,
            sr_min_gap_size: py_config
                .getattr(py, "sr_min_gap_size")?
                .extract(py)?,
            general_delta: py_config
                .getattr(py, "generaldelta")?
                .extract(py)?,
        })
    };

    with_filelog_cache(
        py,
        &py_config,
        revlog_type,
        &DATA_CONFIG_CACHE,
        get_data_config,
    )
}

fn extract_feature_config(
    py: Python,
    py_config: PyObject,
    revlog_type: RevlogType,
) -> PyResult<RevlogFeatureConfig> {
    let get_feature_config = || {
        let engine_bytes = &py_config
            .getattr(py, "compression_engine")?
            .extract::<PyBytes>(py)?;
        let compression_engine = engine_bytes.data(py);
        let compression_engine = match compression_engine {
            b"zlib" => {
                let compression_options = &py_config
                    .getattr(py, "compression_engine_options")?
                    .extract::<PyDict>(py)?;
                let zlib_level = compression_options
                    .get_item(py, PyBytes::new(py, &b"zlib.level"[..]));
                let level = if let Some(level) = zlib_level {
                    if level.is_none(py) {
                        None
                    } else {
                        Some(level.extract(py)?)
                    }
                } else {
                    None
                };
                let mut engine = CompressionConfig::default();
                if let Some(level) = level {
                    engine
                        .set_level(level)
                        .expect("invalid compression level from Python");
                }
                engine
            }
            b"zstd" => {
                let compression_options = &py_config
                    .getattr(py, "compression_engine_options")?
                    .extract::<PyDict>(py)?;
                let zstd_level = compression_options
                    .get_item(py, PyBytes::new(py, &b"zstd.level"[..]));
                let level = if let Some(level) = zstd_level {
                    if level.is_none(py) {
                        None
                    } else {
                        Some(level.extract(py)?)
                    }
                } else {
                    let level = compression_options
                        .get_item(py, PyBytes::new(py, &b"level"[..]));
                    if let Some(level) = level {
                        if level.is_none(py) {
                            None
                        } else {
                            Some(level.extract(py)?)
                        }
                    } else {
                        None
                    }
                };
                CompressionConfig::zstd(level)
                    .expect("invalid compression level from Python")
            }
            b"none" => CompressionConfig::None,
            e => {
                return Err(PyErr::new::<ValueError, _>(
                    py,
                    format!(
                        "invalid compression engine {}",
                        String::from_utf8_lossy(e)
                    ),
                ))
            }
        };
        let revlog_feature_config = RevlogFeatureConfig {
            compression_engine,
            censorable: py_config.getattr(py, "censorable")?.extract(py)?,
            has_side_data: py_config
                .getattr(py, "has_side_data")?
                .extract(py)?,
            compute_rank: py_config
                .getattr(py, "compute_rank")?
                .extract(py)?,
            canonical_parent_order: py_config
                .getattr(py, "canonical_parent_order")?
                .extract(py)?,
            enable_ellipsis: py_config
                .getattr(py, "enable_ellipsis")?
                .extract(py)?,
        };
        Ok(revlog_feature_config)
    };
    with_filelog_cache(
        py,
        &py_config,
        revlog_type,
        &FEATURE_CONFIG_CACHE,
        get_feature_config,
    )
}

fn revlog_error_from_msg(py: Python, e: impl ToString) -> PyErr {
    let msg = e.to_string();

    match py
        .import("mercurial.error")
        .and_then(|m| m.get(py, "RevlogError"))
    {
        Err(e) => e,
        Ok(cls) => {
            let msg = PyBytes::new(py, msg.as_bytes());
            PyErr::from_instance(
                py,
                cls.call(py, (msg,), None).ok().into_py_object(py),
            )
        }
    }
}

py_class!(pub class ReadingContextManager |py| {
    data inner_revlog: RefCell<InnerRevlog>;

    def __enter__(&self) -> PyResult<PyObject> {
        let res = self.inner_revlog(py)
            .borrow()
            .inner(py)
            .borrow()
            .enter_reading_context()
            .map_err(|e| revlog_error_from_msg(py, e));
        if let Err(e) = res {
            // `__exit__` is not called from Python if `__enter__` fails
            self.inner_revlog(py)
                .borrow()
                .inner(py)
                .borrow()
                .exit_reading_context();
            return Err(e)
        }
        Ok(py.None())
    }

    def __exit__(
        &self,
        ty: Option<PyType>,
        value: PyObject,
        traceback: PyObject
    ) -> PyResult<PyObject> {
        // unused arguments, keep clippy from complaining without adding
        // a general rule
        let _ = ty;
        let _ = value;
        let _ = traceback;

        self.inner_revlog(py)
            .borrow()
            .inner(py)
            .borrow()
            .exit_reading_context();
        Ok(py.None())
    }
});

// Only used from Python *tests*
py_class!(pub class PyFileHandle |py| {
    data inner_file: RefCell<std::os::fd::RawFd>;

    def tell(&self) -> PyResult<PyObject> {
        let locals = PyDict::new(py);
        locals.set_item(py, "os", py.import("os")?)?;
        locals.set_item(py, "fd", *self.inner_file(py).borrow())?;
        let f = py.eval("os.fdopen(fd)", None, Some(&locals))?;

        // Prevent Python from closing the file after garbage collecting.
        // This is fine since Rust is still holding on to the actual File.
        // (and also because it's only used in tests).
        std::mem::forget(f.clone_ref(py));

        locals.set_item(py, "f", f)?;
        let res = py.eval("f.tell()", None, Some(&locals))?;
        Ok(res)
    }
});

/// Wrapper around a Python transaction object, to keep `hg-core` oblivious
/// of the fact it's being called from Python.
pub struct PyTransaction {
    inner: PyObject,
}

impl PyTransaction {
    pub fn new(inner: PyObject) -> Self {
        Self { inner }
    }
}

impl Clone for PyTransaction {
    fn clone(&self) -> Self {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        Self {
            inner: self.inner.clone_ref(py),
        }
    }
}

impl Transaction for PyTransaction {
    fn add(&mut self, file: impl AsRef<std::path::Path>, offset: usize) {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        let file = PyBytes::new(py, &get_bytes_from_path(file.as_ref()));
        self.inner
            .call_method(py, "add", (file, offset), None)
            .expect("transaction add failed");
    }
}

py_class!(pub class WritingContextManager |py| {
    data inner_revlog: RefCell<InnerRevlog>;
    data transaction: RefCell<PyTransaction>;
    data data_end: Cell<Option<usize>>;

    def __enter__(&self) -> PyResult<PyObject> {
        let res = self.inner_revlog(py)
            .borrow_mut()
            .inner(py)
            .borrow_mut()
            .enter_writing_context(
                self.data_end(py).get(),
                &mut *self.transaction(py).borrow_mut()
            ).map_err(|e| revlog_error_from_msg(py, e));
        if let Err(e) = res {
            // `__exit__` is not called from Python if `__enter__` fails
            self.inner_revlog(py)
                .borrow_mut()
                .inner(py)
                .borrow_mut()
                .exit_writing_context();
            return Err(e)
        }
        Ok(py.None())
    }

    def __exit__(
        &self,
        ty: Option<PyType>,
        value: PyObject,
        traceback: PyObject
    ) -> PyResult<PyObject> {
        // unused arguments, keep clippy from complaining without adding
        // a general rule
        let _ = ty;
        let _ = value;
        let _ = traceback;

        self.inner_revlog(py)
            .borrow_mut()
            .inner(py)
            .borrow_mut()
            .exit_writing_context();
        Ok(py.None())
    }
});

struct PyFnCache {
    fncache: PyObject,
}
impl PyFnCache {
    fn new(fncache: PyObject) -> Self {
        Self { fncache }
    }
}

impl Clone for PyFnCache {
    fn clone(&self) -> Self {
        let gil = Python::acquire_gil();
        let py = gil.python();
        Self {
            fncache: self.fncache.clone_ref(py),
        }
    }
}

/// Cache whether the fncache is loaded to avoid Python round-trip every time.
/// Once the fncache is loaded, it stays loaded unless we're in a very
/// long-running process, none of which we actually support for now.
static FN_CACHE_IS_LOADED: AtomicBool = AtomicBool::new(false);

impl FnCache for PyFnCache {
    fn is_loaded(&self) -> bool {
        if FN_CACHE_IS_LOADED.load(Ordering::Relaxed) {
            return true;
        }
        let gil = Python::acquire_gil();
        let py = gil.python();
        // TODO raise in case of error?
        let is_loaded = self
            .fncache
            .getattr(py, "is_loaded")
            .ok()
            .map(|o| {
                o.extract::<bool>(py)
                    .expect("is_loaded returned something other than a bool")
            })
            .unwrap_or(false);
        if is_loaded {
            FN_CACHE_IS_LOADED.store(true, Ordering::Relaxed);
        }
        is_loaded
    }
    fn add(&self, path: &std::path::Path) {
        let gil = Python::acquire_gil();
        let py = gil.python();
        // TODO raise in case of error?
        self.fncache
            .call_method(
                py,
                "add",
                (PyBytes::new(py, &get_bytes_from_path(path)),),
                None,
            )
            .ok();
    }
}

py_class!(pub class InnerRevlog |py| {
    @shared data inner: CoreInnerRevlog;
    data nt: RefCell<Option<CoreNodeTree>>;
    data docket: RefCell<Option<PyObject>>;
    // Holds a reference to the mmap'ed persistent nodemap data
    data nodemap_mmap: RefCell<Option<PyBuffer>>;
    // Holds a reference to the mmap'ed persistent index data
    data index_mmap: RefCell<PyBuffer>;
    data head_revs_py_list: RefCell<Option<PyList>>;
    data head_node_ids_py_list: RefCell<Option<PyList>>;
    data revision_cache: RefCell<Option<PyObject>>;
    data use_persistent_nodemap: bool;
    data nodemap_queries: AtomicUsize;

    def __new__(
        _cls,
        vfs_base: PyObject,
        fncache: PyObject,
        vfs_is_readonly: bool,
        index_data: PyObject,
        index_file: PyObject,
        data_file: PyObject,
        sidedata_file: PyObject,
        inline: bool,
        data_config: PyObject,
        delta_config: PyObject,
        feature_config: PyObject,
        chunk_cache: PyObject,
        default_compression_header: PyObject,
        revlog_type: usize,
        use_persistent_nodemap: bool,
    ) -> PyResult<Self> {
        Self::inner_new(
            py,
            vfs_base,
            fncache,
            vfs_is_readonly,
            index_data,
            index_file,
            data_file,
            sidedata_file,
            inline,
            data_config,
            delta_config,
            feature_config,
            chunk_cache,
            default_compression_header,
            revlog_type,
            use_persistent_nodemap
        )
    }

    def clear_cache(&self) -> PyResult<PyObject> {
        assert!(!self.is_delaying(py)?);
        self.revision_cache(py).borrow_mut().take();
        self.inner(py).borrow_mut().clear_cache();
        self.nodemap_queries(py).store(0, Ordering::Relaxed);
        Ok(py.None())
    }

    @property def canonical_index_file(&self) -> PyResult<PyBytes> {
        let path = self.inner(py).borrow().canonical_index_file();
        Ok(PyBytes::new(py, &get_bytes_from_path(path)))
    }

    @property def is_delaying(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().is_delaying())
    }

    @property def _revisioncache(&self) -> PyResult<PyObject> {
        let cache = &*self.revision_cache(py).borrow();
        match cache {
            None => Ok(py.None()),
            Some(cache) => {
                Ok(cache.clone_ref(py))
            }
        }

    }

    @property def _writinghandles(&self) -> PyResult<PyObject> {
        use std::os::fd::AsRawFd;

        let inner = self.inner(py).borrow();
        let handles = inner.python_writing_handles();

        match handles.as_ref() {
            None => Ok(py.None()),
            Some(handles) => {
                let d_handle = if let Some(d_handle) = &handles.data_handle {
                    let handle = RefCell::new(d_handle.file.as_raw_fd());
                    Some(PyFileHandle::create_instance(py, handle)?)
                } else {
                    None
                };
                let handle =
                    RefCell::new(handles.index_handle.file.as_raw_fd());
                Ok(
                    (
                        PyFileHandle::create_instance(py, handle)?,
                        d_handle,
                        py.None(),  // Sidedata handle

                    ).to_py_object(py).into_object()
                )
            }
        }

    }

    @_revisioncache.setter def set_revision_cache(
        &self,
        value: Option<PyObject>
    ) -> PyResult<()> {
        *self.revision_cache(py).borrow_mut() = value.clone_ref(py);
        match value {
            None => {
                // This means the property has been deleted, *not* that the
                // property has been set to `None`. Whatever happens is up
                // to the implementation. Here we just set it to `None`.
                self
                    .inner(py)
                    .borrow()
                    .last_revision_cache
                    .lock()
                    .expect("lock should not be held")
                    .take();
            },
            Some(tuple) => {
                if tuple.is_none(py) {
                    self
                        .inner(py)
                        .borrow()
                        .last_revision_cache
                        .lock()
                        .expect("lock should not be held")
                        .take();
                    return Ok(())
                }
                let node = tuple.get_item(py, 0)?.extract::<PyBytes>(py)?;
                let node = node_from_py_bytes(py, &node)?;
                let rev = tuple.get_item(py, 1)?.extract::<BaseRevision>(py)?;
                // Ok because Python only sets this if the revision has been
                // checked
                let rev = Revision(rev);
                let data = tuple.get_item(py, 2)?.extract::<PyBytes>(py)?;
                let inner = self.inner(py).borrow();
                let mut last_revision_cache = inner
                    .last_revision_cache
                    .lock()
                    .expect("lock should not be held");
                *last_revision_cache =
                    Some((node, rev, Box::new(PyBytesDeref::new(py, data))));
            }
        }
        Ok(())
    }

    @property def inline(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().is_inline())
    }

    @inline.setter def set_inline(
        &self,
        value: Option<PyObject>
    ) -> PyResult<()> {
        if let Some(v) = value {
            self.inner(py).borrow_mut().inline = v.extract(py)?;
        };
        Ok(())
    }

    @property def index_file(&self) -> PyResult<PyBytes> {
        Ok(
            PyBytes::new(
                py,
                &get_bytes_from_path(&self.inner(py).borrow().index_file)
            )
        )
    }

    @index_file.setter def set_index_file(
        &self,
        value: Option<PyObject>
    ) -> PyResult<()> {
        let path = get_path_from_bytes(
            value
                .expect("don't delete the index path")
                .extract::<PyBytes>(py)?
                .data(py)
        ).to_owned();
        self.inner(py).borrow_mut().index_file = path;
        Ok(())
    }

    @property def is_writing(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().is_writing())
    }

    @property def is_open(&self) -> PyResult<bool> {
        Ok(self.inner(py).borrow().is_open())
    }

    def issnapshot(&self, rev: PyRevision) -> PyResult<bool> {
        self.inner_issnapshot(py, UncheckedRevision(rev.0))
    }

    def _deltachain(&self, *args, **kw) -> PyResult<PyObject> {
        let args = PyTuple::new(
            py,
            &[
                args.get_item(py, 0),
                kw.and_then(|d| d.get_item(py, "stoprev")).to_py_object(py),
            ]
        );
        self._index_deltachain(py, &args, kw)
    }

    def compress(&self, data: PyObject) -> PyResult<PyTuple> {
        let inner = self.inner(py).borrow();
        let py_buffer = PyBuffer::get(py, &data)?;
        let deref = PyBufferDeref::new(py, py_buffer)?;
        let compressed = inner.compress(&deref)
        .map_err(|e| revlog_error_from_msg(py, e))?;
        let compressed = compressed.as_deref();
        let header = if compressed.is_some() {
            PyBytes::new(py, &b""[..])
        } else {
            PyBytes::new(py, &b"u"[..])
        };
        Ok(
            (
                header,
                PyBytes::new(py, compressed.unwrap_or(&deref))
            ).to_py_object(py)
        )
    }

    def reading(&self) -> PyResult<ReadingContextManager> {
        ReadingContextManager::create_instance(
            py,
            RefCell::new(self.clone_ref(py)),
        )
    }

    def writing(
        &self,
        transaction: PyObject,
        data_end: Option<usize>,
        sidedata_end: Option<usize>,
    ) -> PyResult<WritingContextManager> {
        // Silence unused argument (only relevant for changelog v2)
        let _ = sidedata_end;
        WritingContextManager::create_instance(
            py,
            RefCell::new(self.clone_ref(py)),
            RefCell::new(PyTransaction::new(transaction)),
            Cell::new(data_end)
        )
    }

    def split_inline(
        &self,
        _tr: PyObject,
        header: i32,
        new_index_file_path: Option<PyObject>
    ) -> PyResult<PyBytes> {
        let mut inner = self.inner(py).borrow_mut();
        let new_index_file_path = match new_index_file_path {
            Some(path) => {
                let path = path.extract::<PyBytes>(py)?;
                Some(get_path_from_bytes(path.data(py)).to_owned())
            },
            None => None,
        };
        let header = IndexHeader::parse(&header.to_be_bytes());
        let header = header.expect("invalid header bytes");
        let path = inner
            .split_inline(header, new_index_file_path)
            .map_err(|e| revlog_error_from_msg(py, e))?;
        Ok(PyBytes::new(py, &get_bytes_from_path(path)))
    }

    def get_segment_for_revs(
        &self,
        startrev: PyRevision,
        endrev: PyRevision,
    ) -> PyResult<PyTuple> {
        let inner = self.inner(py).borrow();
        let (offset, data) = inner
            .get_segment_for_revs(Revision(startrev.0), Revision(endrev.0))
            .map_err(|e| revlog_error_from_msg(py, e))?;
        let data = PyBytes::new(py, &data);
        Ok((offset, data).to_py_object(py))
    }

    def raw_text(
        &self,
        _node: PyObject,
        rev: PyRevision
    ) -> PyResult<PyBytes> {
        let inner = self.inner(py).borrow();
        let mut py_bytes = PyBytes::new(py, &[]);
        inner
            .raw_text(Revision(rev.0), |size, f| {
                py_bytes = with_pybytes_buffer(py, size, f)?;
                Ok(())
            }).map_err(|e| revlog_error_from_msg(py, e))?;
        Ok(py_bytes)
    }

    def _chunk(
        &self,
        rev: PyRevision,
    ) -> PyResult<PyBytes> {
        let inner = self.inner(py).borrow();
        let chunk = inner
            .chunk_for_rev(Revision(rev.0))
            .map_err(|e| revlog_error_from_msg(py, e))?;
        let chunk = PyBytes::new(py, &chunk);
        Ok(chunk)
    }

    def write_entry(
        &self,
        transaction: PyObject,
        entry: PyObject,
        data: PyTuple,
        _link: PyObject,
        offset: usize,
        _sidedata: PyObject,
        _sidedata_offset: PyInt,
        index_end: Option<u64>,
        data_end: Option<u64>,
        _sidedata_end: Option<PyInt>,
    ) -> PyResult<PyTuple> {
        let mut inner = self.inner(py).borrow_mut();
        let transaction = PyTransaction::new(transaction);
        let py_bytes = entry.extract(py)?;
        let entry = PyBytesDeref::new(py, py_bytes);
        let header = data.get_item(py, 0).extract::<PyBytes>(py)?;
        let header = header.data(py);
        let data = data.get_item(py, 1);
        let py_bytes = data.extract(py)?;
        let data = PyBytesDeref::new(py, py_bytes);
        Ok(
            inner.write_entry(
                transaction,
                &entry,
                (header, &data),
                offset,
                index_end,
                data_end
            ).map_err(|e| revlog_error_from_msg(py, e))?
             .to_py_object(py)
        )
    }

    def delay(&self) -> PyResult<Option<PyBytes>> {
        let path = self.inner(py)
            .borrow_mut()
            .delay()
            .map_err(|e| revlog_error_from_msg(py, e))?;
        Ok(path.map(|p| PyBytes::new(py, &get_bytes_from_path(p))))
    }

    def write_pending(&self) -> PyResult<PyTuple> {
        let (path, any_pending) = self.inner(py)
            .borrow_mut()
            .write_pending()
            .map_err(|e| revlog_error_from_msg(py, e))?;
        let maybe_path = match path {
            Some(path) => {
                PyBytes::new(py, &get_bytes_from_path(path)).into_object()
            },
            None => {
                py.None()
            }
        };
        Ok(
            (
                maybe_path,
                any_pending
            ).to_py_object(py)
        )
    }

    def finalize_pending(&self) -> PyResult<PyBytes> {
        let path = self.inner(py)
            .borrow_mut()
            .finalize_pending()
            .map_err(|e| revlog_error_from_msg(py, e))?;
        Ok(PyBytes::new(py, &get_bytes_from_path(path)))
    }

    // -- forwarded index methods --

    def _index_get_rev(&self, node: PyBytes) -> PyResult<Option<PyRevision>> {
        let node = node_from_py_bytes(py, &node)?;
        // Filelogs have no persistent nodemaps and are often small, use a
        // brute force lookup from the end backwards. If there is a very large
        // filelog (automation file that changes every commit etc.), it also
        // seems to work quite well for all measured purposes so far.
        let mut nodemap_queries =
            self.nodemap_queries(py).fetch_add(1, Ordering::Relaxed);
        // Still need to add since `fetch_add` returns the old value
        nodemap_queries += 1;
        if !*self.use_persistent_nodemap(py) && nodemap_queries <= 4 {
            let idx = &self.inner(py).borrow().index;
            let res =
                idx.rev_from_node_no_persistent_nodemap(node.into()).ok();
            return Ok(res.map(Into::into))
        }
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().expect("nodetree should be set");
        let ridx = &self.inner(py).borrow().index;
        let rust_rev =
            nt.find_bin(ridx, node.into()).map_err(|e| nodemap_error(py, e))?;
        Ok(rust_rev.map(Into::into))
    }

    /// same as `_index_get_rev()` but raises a bare `error.RevlogError` if node
    /// is not found.
    ///
    /// No need to repeat `node` in the exception, `mercurial/revlog.py`
    /// will catch and rewrap with it
    def _index_rev(&self, node: PyBytes) -> PyResult<PyRevision> {
        self._index_get_rev(py, node)?.ok_or_else(|| revlog_error(py))
    }

    /// return True if the node exist in the index
    def _index_has_node(&self, node: PyBytes) -> PyResult<bool> {
        // TODO OPTIM we could avoid a needless conversion here,
        // to do when scaffolding for pure Rust switch is removed,
        // as `_index_get_rev()` currently does the necessary assertions
        self._index_get_rev(py, node).map(|opt| opt.is_some())
    }

    /// find length of shortest hex nodeid of a binary ID
    def _index_shortest(&self, node: PyBytes) -> PyResult<usize> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().expect("nodetree should be set");
        let idx = &self.inner(py).borrow().index;
        match nt.unique_prefix_len_node(idx, &node_from_py_bytes(py, &node)?)
        {
            Ok(Some(l)) => Ok(l),
            Ok(None) => Err(revlog_error(py)),
            Err(e) => Err(nodemap_error(py, e)),
        }
    }

    def _index_partialmatch(
        &self,
        node: PyObject
    ) -> PyResult<Option<PyBytes>> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().expect("nodetree should be set");
        let idx = &self.inner(py).borrow().index;

        let node = node.extract::<PyBytes>(py)?;
        let node_as_string = String::from_utf8_lossy(node.data(py));

        let prefix = NodePrefix::from_hex(node_as_string.to_string())
            .map_err(|_| PyErr::new::<ValueError, _>(
                py, format!("Invalid node or prefix '{}'", node_as_string))
            )?;

        nt.find_bin(idx, prefix)
            // TODO make an inner API returning the node directly
            .map(|opt| opt.map(|rev| {
                    PyBytes::new(
                        py,
                        idx.node(rev).expect("node should exist").as_bytes()
                    )
            }))
            .map_err(|e| nodemap_error(py, e))

    }

    /// append an index entry
    def _index_append(&self, tup: PyTuple) -> PyResult<PyObject> {
        if tup.len(py) < 8 {
            // this is better than the panic promised by tup.get_item()
            return Err(
                PyErr::new::<IndexError, _>(py, "tuple index out of range"))
        }
        let node_bytes = tup.get_item(py, 7).extract(py)?;
        let node = node_from_py_object(py, &node_bytes)?;

        let rev = self.len(py)? as BaseRevision;

        // This is ok since we will just add the revision to the index
        let rev = Revision(rev);
        self.inner(py)
            .borrow_mut()
            .index
            .append(py_tuple_to_revision_data_params(py, tup)?)
            .map_err(|e| revlog_error_from_msg(py, e))?;
        let idx = &self.inner(py).borrow().index;
        self.get_nodetree(py)?
            .borrow_mut()
            .as_mut()
            .expect("nodetree should be set")
            .insert(idx, &node, rev)
            .map_err(|e| nodemap_error(py, e))?;
        Ok(py.None())
    }

    def _index___delitem__(&self, key: PyObject) -> PyResult<PyObject> {
        // __delitem__ is both for `del idx[r]` and `del idx[r1:r2]`
        let start = if let Ok(rev) = key.extract(py) {
            UncheckedRevision(rev)
        } else {
            let start = key.getattr(py, "start")?;
            UncheckedRevision(start.extract(py)?)
        };
        let mut borrow = self.inner(py).borrow_mut();
        let start = borrow
            .index
            .check_revision(start)
            .ok_or_else(|| {
                nodemap_error(py, NodeMapError::RevisionNotInIndex(start))
            })?;
        borrow.index
            .remove(start)
            .map_err(|e| revlog_error_from_msg(py, e))?;
        drop(borrow);
        let mut opt = self.get_nodetree(py)?.borrow_mut();
        let nt = opt.as_mut().expect("nodetree should be set");
        nt.invalidate_all();
        self.fill_nodemap(py, nt)?;
        Ok(py.None())
    }

    /// return the gca set of the given revs
    def _index_ancestors(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_ancestors(py, args)?;
        Ok(rust_res)
    }

    /// return the heads of the common ancestors of the given revs
    def _index_commonancestorsheads(
        &self,
        *args,
        **_kw
    ) -> PyResult<PyObject> {
        let rust_res = self.inner_commonancestorsheads(py, args)?;
        Ok(rust_res)
    }

    /// Clear the index caches and inner py_class data.
    /// It is Python's responsibility to call `update_nodemap_data` again.
    def _index_clearcaches(&self) -> PyResult<PyObject> {
        self.nt(py).borrow_mut().take();
        self.docket(py).borrow_mut().take();
        self.nodemap_mmap(py).borrow_mut().take();
        self.head_revs_py_list(py).borrow_mut().take();
        self.head_node_ids_py_list(py).borrow_mut().take();
        self.inner(py).borrow_mut().index.clear_caches();
        Ok(py.None())
    }

    /// return the raw binary string representing a revision
    def _index_entry_binary(&self, *args, **_kw) -> PyResult<PyObject> {
        let rindex = &self.inner(py).borrow().index;
        let rev = UncheckedRevision(args.get_item(py, 0).extract(py)?);
        let rust_bytes = rindex.check_revision(rev).and_then(
            |r| rindex.entry_binary(r)).ok_or_else(|| rev_not_in_index(py, rev)
        )?;
        let rust_res = PyBytes::new(py, rust_bytes).into_object();
        Ok(rust_res)
    }


    /// return a binary packed version of the header
    def _index_pack_header(&self, *args, **_kw) -> PyResult<PyObject> {
        let rindex = &self.inner(py).borrow().index;
        let packed = rindex.pack_header(args.get_item(py, 0).extract(py)?);
        let rust_res = PyBytes::new(py, &packed).into_object();
        Ok(rust_res)
    }

    /// compute phases
    def _index_computephasesmapsets(
        &self,
        *args,
        **_kw
    ) -> PyResult<PyObject> {
        let py_roots = args.get_item(py, 0).extract::<PyDict>(py)?;
        let rust_res = self.inner_computephasesmapsets(py, py_roots)?;
        Ok(rust_res)
    }

    /// reachableroots
    def _index_reachableroots2(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_reachableroots2(
            py,
            UncheckedRevision(args.get_item(py, 0).extract(py)?),
            args.get_item(py, 1),
            args.get_item(py, 2),
            args.get_item(py, 3).extract(py)?,
        )?;
        Ok(rust_res)
    }

    /// get head revisions
    def _index_headrevs(&self, *args, **_kw) -> PyResult<PyObject> {
        let (filtered_revs, stop_rev) = match &args.len(py) {
             0 => Ok((py.None(), py.None())),
             1 => Ok((args.get_item(py, 0), py.None())),
             2 => Ok((args.get_item(py, 0), args.get_item(py, 1))),
             _ => Err(PyErr::new::<cpython::exc::TypeError, _>(py, "too many arguments")),
        }?;
        self.inner_headrevs(py, &filtered_revs, &stop_rev)
    }

    /// get head nodeids
    def _index_head_node_ids(&self) -> PyResult<PyObject> {
        let rust_res = self.inner_head_node_ids(py)?;
        Ok(rust_res)
    }

    /// get diff in head revisions
    def _index_headrevsdiff(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_headrevsdiff(
          py,
          &args.get_item(py, 0),
          &args.get_item(py, 1))?;
        Ok(rust_res)
    }

    /// True if the object is a snapshot
    def _index_issnapshot(&self, *args, **_kw) -> PyResult<bool> {
        let rev = UncheckedRevision(args.get_item(py, 0).extract(py)?);
        self.inner_issnapshot(py, rev)
    }

    /// Gather snapshot data in a cache dict
    def _index_findsnapshots(&self, *args, **_kw) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let cache: PyDict = args.get_item(py, 0).extract(py)?;
        // this methods operates by setting new values in the cache,
        // hence we will compare results by letting the C implementation
        // operate over a deepcopy of the cache, and finally compare both
        // caches.
        let c_cache = PyDict::new(py);
        for (k, v) in cache.items(py) {
            c_cache.set_item(py, k, PySet::new(py, v)?)?;
        }

        let start_rev = UncheckedRevision(args.get_item(py, 1).extract(py)?);
        let end_rev = UncheckedRevision(args.get_item(py, 2).extract(py)?);
        let mut cache_wrapper = PySnapshotsCache{ py, dict: cache };
        index.find_snapshots(
            start_rev,
            end_rev,
            &mut cache_wrapper,
        ).map_err(|_| revlog_error(py))?;
        Ok(py.None())
    }

    /// determine revisions with deltas to reconstruct fulltext
    def _index_deltachain(&self, *args, **_kw) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let rev = args.get_item(py, 0).extract::<BaseRevision>(py)?.into();
        let stop_rev =
            args.get_item(py, 1).extract::<Option<BaseRevision>>(py)?;
        let rev = index.check_revision(rev).ok_or_else(|| {
            nodemap_error(py, NodeMapError::RevisionNotInIndex(rev))
        })?;
        let stop_rev = if let Some(stop_rev) = stop_rev {
            let stop_rev = UncheckedRevision(stop_rev);
            Some(index.check_revision(stop_rev).ok_or_else(|| {
                nodemap_error(py, NodeMapError::RevisionNotInIndex(stop_rev))
            })?)
        } else {None};
        let (chain, stopped) = index.delta_chain(
            rev, stop_rev
        ).map_err(|e| {
            PyErr::new::<cpython::exc::ValueError, _>(py, e.to_string())
        })?;

        let chain: Vec<_> = chain.into_iter().map(|r| r.0).collect();
        Ok(
            PyTuple::new(
                py,
                &[
                    chain.into_py_object(py).into_object(),
                    stopped.into_py_object(py).into_object()
                ]
            ).into_object()
        )
    }

    /// slice planned chunk read to reach a density threshold
    def _index_slicechunktodensity(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_slicechunktodensity(
            py,
            args.get_item(py, 0),
            args.get_item(py, 1).extract(py)?,
            args.get_item(py, 2).extract(py)?
        )?;
        Ok(rust_res)
    }

    def _index___len__(&self) -> PyResult<usize> {
        self.len(py)
    }

    def _index___getitem__(&self, key: PyObject) -> PyResult<PyObject> {
        let rust_res = self.inner_getitem(py, key.clone_ref(py))?;
        Ok(rust_res)
    }

    def _index___contains__(&self, item: PyObject) -> PyResult<bool> {
        // ObjectProtocol does not seem to provide contains(), so
        // this is an equivalent implementation of the index_contains()
        // defined in revlog.c
        match item.extract::<i32>(py) {
            Ok(rev) => {
                Ok(rev >= -1 && rev < self.len(py)? as BaseRevision)
            }
            Err(_) => {
                let item_bytes: PyBytes = item.extract(py)?;
                let rust_res = self._index_has_node(py, item_bytes)?;
                Ok(rust_res)
            }
        }
    }

    def _index_nodemap_data_all(&self) -> PyResult<PyBytes> {
        self.inner_nodemap_data_all(py)
    }

    def _index_nodemap_data_incremental(&self) -> PyResult<PyObject> {
        self.inner_nodemap_data_incremental(py)
    }

    def _index_update_nodemap_data(
        &self,
        docket: PyObject,
        nm_data: PyObject
    ) -> PyResult<PyObject> {
        self.inner_update_nodemap_data(py, docket, nm_data)
    }

    @property
    def _index_entry_size(&self) -> PyResult<PyInt> {
        let rust_res: PyInt = INDEX_ENTRY_SIZE.to_py_object(py);
        Ok(rust_res)
    }

    @property
    def _index_rust_ext_compat(&self) -> PyResult<PyInt> {
        // will be entirely removed when the Rust index yet useful to
        // implement in Rust to detangle things when removing `self.cindex`
        let rust_res: PyInt = 1.to_py_object(py);
        Ok(rust_res)
    }

    @property
    def _index_is_rust(&self) -> PyResult<PyBool> {
        Ok(false.to_py_object(py))
    }


});

/// Forwarded index methods?
impl InnerRevlog {
    pub fn pub_inner<'p, 'a: 'p>(
        &'a self,
        py: Python<'p>,
    ) -> PySharedRef<'p, CoreInnerRevlog> {
        self.inner(py)
    }

    fn len(&self, py: Python) -> PyResult<usize> {
        let rust_index_len = self.inner(py).borrow().index.len();
        Ok(rust_index_len)
    }
    /// This is scaffolding at this point, but it could also become
    /// a way to start a persistent nodemap or perform a
    /// vacuum / repack operation
    fn fill_nodemap(
        &self,
        py: Python,
        nt: &mut CoreNodeTree,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        for r in 0..self.len(py)? {
            let rev = Revision(r as BaseRevision);
            // in this case node() won't ever return None
            nt.insert(index, index.node(rev).expect("node should exist"), rev)
                .map_err(|e| nodemap_error(py, e))?
        }
        Ok(py.None())
    }

    fn get_nodetree<'a>(
        &'a self,
        py: Python<'a>,
    ) -> PyResult<&'a RefCell<Option<CoreNodeTree>>> {
        if self.nt(py).borrow().is_none() {
            let readonly = Box::<Vec<_>>::default();
            let mut nt = CoreNodeTree::load_bytes(readonly, 0);
            self.fill_nodemap(py, &mut nt)?;
            self.nt(py).borrow_mut().replace(nt);
        }
        Ok(self.nt(py))
    }

    /// Returns the full nodemap bytes to be written as-is to disk
    fn inner_nodemap_data_all(&self, py: Python) -> PyResult<PyBytes> {
        let nodemap = self
            .get_nodetree(py)?
            .borrow_mut()
            .take()
            .expect("nodetree should exist");
        let (readonly, bytes) = nodemap.into_readonly_and_added_bytes();

        // If there's anything readonly, we need to build the data again from
        // scratch
        let bytes = if readonly.len() > 0 {
            let mut nt = CoreNodeTree::load_bytes(Box::<Vec<_>>::default(), 0);
            self.fill_nodemap(py, &mut nt)?;

            let (readonly, bytes) = nt.into_readonly_and_added_bytes();
            assert_eq!(readonly.len(), 0);

            bytes
        } else {
            bytes
        };

        let bytes = PyBytes::new(py, &bytes);
        Ok(bytes)
    }

    /// Returns the last saved docket along with the size of any changed data
    /// (in number of blocks), and said data as bytes.
    fn inner_nodemap_data_incremental(
        &self,
        py: Python,
    ) -> PyResult<PyObject> {
        let docket = self.docket(py).borrow();
        let docket = match docket.as_ref() {
            Some(d) => d,
            None => return Ok(py.None()),
        };

        let node_tree = self
            .get_nodetree(py)?
            .borrow_mut()
            .take()
            .expect("nodetree should exist");
        let masked_blocks = node_tree.masked_readonly_blocks();
        let (_, data) = node_tree.into_readonly_and_added_bytes();
        let changed = masked_blocks * std::mem::size_of::<Block>();

        Ok((docket, changed, PyBytes::new(py, &data))
            .to_py_object(py)
            .into_object())
    }

    /// Update the nodemap from the new (mmaped) data.
    /// The docket is kept as a reference for later incremental calls.
    fn inner_update_nodemap_data(
        &self,
        py: Python,
        docket: PyObject,
        nm_data: PyObject,
    ) -> PyResult<PyObject> {
        // Safety: we keep the buffer around inside the class as `nodemap_mmap`
        let (buf, bytes) = unsafe { mmap_keeparound(py, nm_data)? };
        let len = buf.item_count();
        self.nodemap_mmap(py).borrow_mut().replace(buf);

        let mut nt = CoreNodeTree::load_bytes(bytes, len);

        let data_tip = docket
            .getattr(py, "tip_rev")?
            .extract::<BaseRevision>(py)?
            .into();
        self.docket(py).borrow_mut().replace(docket.clone_ref(py));
        let idx = &self.inner(py).borrow().index;
        let data_tip = idx.check_revision(data_tip).ok_or_else(|| {
            nodemap_error(py, NodeMapError::RevisionNotInIndex(data_tip))
        })?;
        let current_tip = idx.len();

        for r in (data_tip.0 + 1)..current_tip as BaseRevision {
            let rev = Revision(r);
            // in this case node() won't ever return None
            nt.insert(idx, idx.node(rev).expect("node should exist"), rev)
                .map_err(|e| nodemap_error(py, e))?
        }

        *self.nt(py).borrow_mut() = Some(nt);

        Ok(py.None())
    }

    fn inner_getitem(&self, py: Python, key: PyObject) -> PyResult<PyObject> {
        let idx = &self.inner(py).borrow().index;
        Ok(match key.extract::<BaseRevision>(py) {
            Ok(key_as_int) => {
                let entry_params = if key_as_int == NULL_REVISION.0 {
                    RevisionDataParams::default()
                } else {
                    let rev = UncheckedRevision(key_as_int);
                    match idx.entry_as_params(rev) {
                        Some(e) => e,
                        None => {
                            return Err(PyErr::new::<IndexError, _>(
                                py,
                                "revlog index out of range",
                            ));
                        }
                    }
                };
                revision_data_params_to_py_tuple(py, entry_params)
                    .into_object()
            }
            _ => self
                ._index_get_rev(py, key.extract::<PyBytes>(py)?)?
                .map_or_else(
                    || py.None(),
                    |py_rev| py_rev.into_py_object(py).into_object(),
                ),
        })
    }

    fn inner_head_node_ids(&self, py: Python) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;

        // We don't use the shortcut here, as it's actually slower to loop
        // through the cached `PyList` than to re-do the whole computation for
        // large lists, which are the performance sensitive ones anyway.
        let head_revs = index.head_revs().map_err(|e| graph_error(py, e))?;
        let res: Vec<_> = head_revs
            .iter()
            .map(|r| {
                PyBytes::new(
                    py,
                    index
                        .node(*r)
                        .expect("rev should have been in the index")
                        .as_bytes(),
                )
                .into_object()
            })
            .collect();

        self.cache_new_heads_py_list(&head_revs, py);
        self.cache_new_heads_node_ids_py_list(&head_revs, py);

        Ok(PyList::new(py, &res).into_object())
    }

    fn inner_headrevs(
        &self,
        py: Python,
        filtered_revs: &PyObject,
        stop_rev: &PyObject,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let stop_rev = if stop_rev.is_none(py) {
            None
        } else {
            let rev = stop_rev.extract::<i32>(py)?;
            if 0 <= rev && rev < index.len() as BaseRevision {
                Some(Revision(rev))
            } else {
                None
            }
        };
        let from_core = match (filtered_revs.is_none(py), stop_rev.is_none()) {
            (true, true) => index.head_revs_shortcut(),
            (true, false) => {
                index.head_revs_advanced(&HashSet::new(), stop_rev, false)
            }
            _ => {
                let filtered_revs =
                    rev_pyiter_collect(py, filtered_revs, index)?;
                index.head_revs_advanced(
                    &filtered_revs,
                    stop_rev,
                    stop_rev.is_none(),
                )
            }
        };

        if stop_rev.is_some() {
            // we don't cache result for now
            let new_heads = from_core
                .map_err(|e| graph_error(py, e))?
                .expect("this case should not be cached yet");

            let as_vec: Vec<PyObject> = new_heads
                .iter()
                .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
                .collect();
            Ok(PyList::new(py, &as_vec).into_object())
        } else {
            if let Some(new_heads) =
                from_core.map_err(|e| graph_error(py, e))?
            {
                self.cache_new_heads_py_list(&new_heads, py);
            }

            Ok(self
                .head_revs_py_list(py)
                .borrow()
                .as_ref()
                .expect("head revs should be cached")
                .clone_ref(py)
                .into_object())
        }
    }

    fn check_revision(
        index: &Index,
        rev: UncheckedRevision,
        py: Python,
    ) -> PyResult<Revision> {
        index
            .check_revision(rev)
            .ok_or_else(|| rev_not_in_index(py, rev))
    }

    fn inner_headrevsdiff(
        &self,
        py: Python,
        begin: &PyObject,
        end: &PyObject,
    ) -> PyResult<PyObject> {
        let begin = begin.extract::<BaseRevision>(py)?;
        let end = end.extract::<BaseRevision>(py)?;
        let index = &self.inner(py).borrow().index;
        let begin =
            Self::check_revision(index, UncheckedRevision(begin - 1), py)?;
        let end = Self::check_revision(index, UncheckedRevision(end - 1), py)?;
        let (removed, added) = index
            .head_revs_diff(begin, end)
            .map_err(|e| graph_error(py, e))?;
        let removed: Vec<_> =
            removed.into_iter().map(PyRevision::from).collect();
        let added: Vec<_> = added.into_iter().map(PyRevision::from).collect();
        let res = (removed, added).to_py_object(py).into_object();
        Ok(res)
    }

    fn cache_new_heads_node_ids_py_list(
        &self,
        new_heads: &[Revision],
        py: Python<'_>,
    ) -> PyList {
        let index = &self.inner(py).borrow().index;
        let as_vec: Vec<PyObject> = new_heads
            .iter()
            .map(|r| {
                PyBytes::new(
                    py,
                    index
                        .node(*r)
                        .expect("rev should have been in the index")
                        .as_bytes(),
                )
                .into_object()
            })
            .collect();
        let new_heads_py_list = PyList::new(py, &as_vec);
        *self.head_node_ids_py_list(py).borrow_mut() =
            Some(new_heads_py_list.clone_ref(py));
        new_heads_py_list
    }

    fn cache_new_heads_py_list(
        &self,
        new_heads: &[Revision],
        py: Python<'_>,
    ) -> PyList {
        let as_vec: Vec<PyObject> = new_heads
            .iter()
            .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
            .collect();
        let new_heads_py_list = PyList::new(py, &as_vec);
        *self.head_revs_py_list(py).borrow_mut() =
            Some(new_heads_py_list.clone_ref(py));
        new_heads_py_list
    }

    fn inner_ancestors(
        &self,
        py: Python,
        py_revs: &PyTuple,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let revs: Vec<_> = rev_pyiter_collect(py, py_revs.as_object(), index)?;
        let as_vec: Vec<_> = index
            .ancestors(&revs)
            .map_err(|e| graph_error(py, e))?
            .iter()
            .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
            .collect();
        Ok(PyList::new(py, &as_vec).into_object())
    }

    fn inner_commonancestorsheads(
        &self,
        py: Python,
        py_revs: &PyTuple,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let revs: Vec<_> = rev_pyiter_collect(py, py_revs.as_object(), index)?;
        let as_vec: Vec<_> = index
            .common_ancestor_heads(&revs)
            .map_err(|e| graph_error(py, e))?
            .iter()
            .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
            .collect();
        Ok(PyList::new(py, &as_vec).into_object())
    }

    fn inner_computephasesmapsets(
        &self,
        py: Python,
        py_roots: PyDict,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let roots: Result<HashMap<Phase, Vec<Revision>>, PyErr> = py_roots
            .items_list(py)
            .iter(py)
            .map(|r| {
                let phase = r.get_item(py, 0)?;
                let revs: Vec<_> =
                    rev_pyiter_collect(py, &r.get_item(py, 1)?, index)?;
                let phase = Phase::try_from(phase.extract::<usize>(py)?)
                    .map_err(|_| revlog_error(py));
                Ok((phase?, revs))
            })
            .collect();
        let (len, phase_maps) = index
            .compute_phases_map_sets(roots?)
            .map_err(|e| graph_error(py, e))?;

        // Ugly hack, but temporary
        const IDX_TO_PHASE_NUM: [usize; 4] = [1, 2, 32, 96];
        let py_phase_maps = PyDict::new(py);
        for (idx, roots) in phase_maps.into_iter().enumerate() {
            let phase_num = IDX_TO_PHASE_NUM[idx].into_py_object(py);
            // This is a bit faster than collecting into a `Vec` and passing
            // it to `PySet::new`.
            let set = PySet::empty(py)?;
            for rev in roots {
                set.add(py, PyRevision::from(rev).into_py_object(py))?;
            }
            py_phase_maps.set_item(py, phase_num, set)?;
        }
        Ok(PyTuple::new(
            py,
            &[
                len.into_py_object(py).into_object(),
                py_phase_maps.into_object(),
            ],
        )
        .into_object())
    }

    fn inner_slicechunktodensity(
        &self,
        py: Python,
        revs: PyObject,
        target_density: f64,
        min_gap_size: usize,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let revs: Vec<_> = rev_pyiter_collect(py, &revs, index)?;
        let as_nested_vec =
            index.slice_chunk_to_density(&revs, target_density, min_gap_size);
        let mut res = Vec::with_capacity(as_nested_vec.len());
        let mut py_chunk = Vec::new();
        for chunk in as_nested_vec {
            py_chunk.clear();
            py_chunk.reserve_exact(chunk.len());
            for rev in chunk {
                py_chunk.push(
                    PyRevision::from(rev).into_py_object(py).into_object(),
                );
            }
            res.push(PyList::new(py, &py_chunk).into_object());
        }
        // This is just to do the same as C, not sure why it does this
        if res.len() == 1 {
            Ok(PyTuple::new(py, &res).into_object())
        } else {
            Ok(PyList::new(py, &res).into_object())
        }
    }

    fn inner_reachableroots2(
        &self,
        py: Python,
        min_root: UncheckedRevision,
        heads: PyObject,
        roots: PyObject,
        include_path: bool,
    ) -> PyResult<PyObject> {
        let index = &self.inner(py).borrow().index;
        let heads = rev_pyiter_collect_or_else(py, &heads, index, |_rev| {
            PyErr::new::<IndexError, _>(py, "head out of range")
        })?;
        let roots: Result<_, _> = roots
            .iter(py)?
            .map(|r| {
                r.and_then(|o| match o.extract::<PyRevision>(py) {
                    Ok(r) => Ok(UncheckedRevision(r.0)),
                    Err(e) => Err(e),
                })
            })
            .collect();
        let as_set = index
            .reachable_roots(min_root, heads, roots?, include_path)
            .map_err(|e| graph_error(py, e))?;
        let as_vec: Vec<PyObject> = as_set
            .iter()
            .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
            .collect();
        Ok(PyList::new(py, &as_vec).into_object())
    }
    fn inner_issnapshot(
        &self,
        py: Python,
        rev: UncheckedRevision,
    ) -> PyResult<bool> {
        let inner = &self.inner(py).borrow();
        let index = &self.inner(py).borrow().index;
        let rev = index
            .check_revision(rev)
            .ok_or_else(|| rev_not_in_index(py, rev))?;
        let result = inner.is_snapshot(rev).map_err(|e| {
            PyErr::new::<cpython::exc::ValueError, _>(py, e.to_string())
        })?;
        Ok(result)
    }
}

impl InnerRevlog {
    pub fn inner_new(
        py: Python,
        vfs_base: PyObject,
        fncache: PyObject,
        vfs_is_readonly: bool,
        index_data: PyObject,
        index_file: PyObject,
        data_file: PyObject,
        _sidedata_file: PyObject,
        inline: bool,
        data_config: PyObject,
        delta_config: PyObject,
        feature_config: PyObject,
        _chunk_cache: PyObject,
        _default_compression_header: PyObject,
        revlog_type: usize,
        use_persistent_nodemap: bool,
    ) -> PyResult<Self> {
        let index_file =
            get_path_from_bytes(index_file.extract::<PyBytes>(py)?.data(py))
                .to_owned();
        let data_file =
            get_path_from_bytes(data_file.extract::<PyBytes>(py)?.data(py))
                .to_owned();
        let revlog_type = RevlogType::try_from(revlog_type)
            .map_err(|e| revlog_error_from_msg(py, e))?;
        let data_config = extract_data_config(py, data_config, revlog_type)?;
        let delta_config =
            extract_delta_config(py, delta_config, revlog_type)?;
        let feature_config =
            extract_feature_config(py, feature_config, revlog_type)?;
        let options = RevlogOpenOptions::new(
            inline,
            data_config,
            delta_config,
            feature_config,
        );

        // Safety: we keep the buffer around inside the class as `index_mmap`
        let (buf, bytes) = unsafe { mmap_keeparound(py, index_data)? };
        let index = Index::new(bytes, options.index_header())
            .map_err(|e| revlog_error_from_msg(py, e))?;

        let base = &vfs_base.extract::<PyBytes>(py)?;
        let base = get_path_from_bytes(base.data(py)).to_owned();
        let core = CoreInnerRevlog::new(
            Box::new(FnCacheVfs::new(
                base,
                vfs_is_readonly,
                Box::new(PyFnCache::new(fncache)),
            )),
            index,
            index_file,
            data_file,
            data_config,
            delta_config,
            feature_config,
        );
        Self::create_instance(
            py,
            core,
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(buf),
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(None),
            use_persistent_nodemap,
            AtomicUsize::new(0),
        )
    }
}

py_class!(pub class NodeTree |py| {
    data nt: RefCell<CoreNodeTree>;
    data index: RefCell<UnsafePyLeaked<PySharedIndex>>;

    def __new__(_cls, index: PyObject) -> PyResult<NodeTree> {
        let index = py_rust_index_to_graph(py, index)?;
        let nt = CoreNodeTree::default();  // in-RAM, fully mutable
        Self::create_instance(py, RefCell::new(nt), RefCell::new(index))
    }

    /// Tell whether the NodeTree is still valid
    ///
    /// In case of mutation of the index, the given results are not
    /// guaranteed to be correct, and in fact, the methods borrowing
    /// the inner index would fail because of `PySharedRef` poisoning
    /// (generation-based guard), same as iterating on a `dict` that has
    /// been meanwhile mutated.
    def is_invalidated(&self) -> PyResult<bool> {
        let leaked = &self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let result = unsafe { leaked.try_borrow(py) };
        // two cases for result to be an error:
        // - the index has previously been mutably borrowed
        // - there is currently a mutable borrow
        // in both cases this amounts for previous results related to
        // the index to still be valid.
        Ok(result.is_err())
    }

    def insert(&self, rev: PyRevision) -> PyResult<PyObject> {
        let leaked = &self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let index = &*unsafe { leaked.try_borrow(py)? };

        let rev = UncheckedRevision(rev.0);
        let rev = index
            .check_revision(rev)
            .ok_or_else(|| rev_not_in_index(py, rev))?;
        if rev == NULL_REVISION {
            return Err(rev_not_in_index(py, rev.into()))
        }

        let entry = index.inner.get_entry(rev).expect("entry should exist");
        let mut nt = self.nt(py).borrow_mut();
        nt.insert(index, entry.hash(), rev).map_err(|e| nodemap_error(py, e))?;

        Ok(py.None())
    }

    /// Lookup by node hex prefix in the NodeTree, returning revision number.
    ///
    /// This is not part of the classical NodeTree API, but is good enough
    /// for unit testing, as in `test-rust-revlog.py`.
    def prefix_rev_lookup(
        &self,
        node_prefix: PyBytes
    ) -> PyResult<Option<PyRevision>> {
        let prefix = NodePrefix::from_hex(node_prefix.data(py))
            .map_err(|_| PyErr::new::<ValueError, _>(
                py,
                format!("Invalid node or prefix {:?}",
                        node_prefix.as_object()))
            )?;

        let nt = self.nt(py).borrow();
        let leaked = &self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let index = &*unsafe { leaked.try_borrow(py)? };

        Ok(nt.find_bin(index, prefix)
               .map_err(|e| nodemap_error(py, e))?
               .map(|r| r.into())
        )
    }

    def shortest(&self, node: PyBytes) -> PyResult<usize> {
        let nt = self.nt(py).borrow();
        let leaked = &self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let idx = &*unsafe { leaked.try_borrow(py)? };
        match nt.unique_prefix_len_node(idx, &node_from_py_bytes(py, &node)?)
        {
            Ok(Some(l)) => Ok(l),
            Ok(None) => Err(revlog_error(py)),
            Err(e) => Err(nodemap_error(py, e)),
        }
    }
});

fn panic_after_error(_py: Python) -> ! {
    unsafe {
        python3_sys::PyErr_Print();
    }
    panic!("Python API called failed");
}

/// # Safety
///
/// Don't call this. Its only caller is taken from `PyO3`.
unsafe fn cast_from_owned_ptr_or_panic<T>(
    py: Python,
    p: *mut python3_sys::PyObject,
) -> T
where
    T: cpython::PythonObjectWithCheckedDowncast,
{
    if p.is_null() {
        panic_after_error(py);
    } else {
        PyObject::from_owned_ptr(py, p).cast_into(py).unwrap()
    }
}

fn with_pybytes_buffer<F>(
    py: Python,
    len: usize,
    init: F,
) -> Result<PyBytes, RevlogError>
where
    F: FnOnce(
        &mut dyn RevisionBuffer<Target = PyBytes>,
    ) -> Result<(), RevlogError>,
{
    // Largely inspired by code in PyO3
    // https://pyo3.rs/main/doc/pyo3/types/struct.pybytes#method.new_bound_with
    unsafe {
        let pyptr = python3_sys::PyBytes_FromStringAndSize(
            std::ptr::null(),
            len as python3_sys::Py_ssize_t,
        );
        let pybytes = cast_from_owned_ptr_or_panic::<PyBytes>(py, pyptr);
        let buffer: *mut u8 = python3_sys::PyBytes_AsString(pyptr).cast();
        debug_assert!(!buffer.is_null());
        let mut rev_buf = PyRevisionBuffer::new(pybytes, buffer, len);
        // Initialise the bytestring in init
        // If init returns an Err, the buffer is deallocated by `pybytes`
        init(&mut rev_buf).map(|_| rev_buf.finish())
    }
}

/// Wrapper around a Python-provided buffer into which the revision contents
/// will be written. Done for speed in order to save a large allocation + copy.
struct PyRevisionBuffer {
    py_bytes: PyBytes,
    _buf: *mut u8,
    len: usize,
    current_buf: *mut u8,
    current_len: usize,
}

impl PyRevisionBuffer {
    /// # Safety
    ///
    /// `buf` should be the start of the allocated bytes of `bytes`, and `len`
    /// exactly the length of said allocated bytes.
    #[inline]
    unsafe fn new(bytes: PyBytes, buf: *mut u8, len: usize) -> Self {
        Self {
            py_bytes: bytes,
            _buf: buf,
            len,
            current_len: 0,
            current_buf: buf,
        }
    }

    /// Number of bytes that have been copied to. Will be different to the
    /// total allocated length of the buffer unless the revision is done being
    /// written.
    #[inline]
    fn current_len(&self) -> usize {
        self.current_len
    }
}

impl RevisionBuffer for PyRevisionBuffer {
    type Target = PyBytes;

    #[inline]
    fn extend_from_slice(&mut self, slice: &[u8]) {
        assert!(self.current_len + slice.len() <= self.len);
        unsafe {
            // We cannot use `copy_from_nonoverlapping` since it's *possible*
            // to create a slice from the same Python memory region using
            // [`PyBytesDeref`]. Probable that LLVM has an optimization anyway?
            self.current_buf.copy_from(slice.as_ptr(), slice.len());
            self.current_buf = self.current_buf.add(slice.len());
        }
        self.current_len += slice.len()
    }

    #[inline]
    fn finish(self) -> Self::Target {
        // catch unzeroed bytes before it becomes undefined behavior
        assert_eq!(
            self.current_len(),
            self.len,
            "not enough bytes read for revision"
        );
        self.py_bytes
    }
}

fn revlog_error(py: Python) -> PyErr {
    match py
        .import("mercurial.error")
        .and_then(|m| m.get(py, "RevlogError"))
    {
        Err(e) => e,
        Ok(cls) => PyErr::from_instance(
            py,
            cls.call(py, (py.None(),), None).ok().into_py_object(py),
        ),
    }
}

fn graph_error(py: Python, _err: hg::GraphError) -> PyErr {
    // ParentOutOfRange is currently the only alternative
    // in `hg::GraphError`. The C index always raises this simple ValueError.
    PyErr::new::<ValueError, _>(py, "parent out of range")
}

fn nodemap_rev_not_in_index(py: Python, rev: UncheckedRevision) -> PyErr {
    PyErr::new::<ValueError, _>(
        py,
        format!(
            "Inconsistency: Revision {} found in nodemap \
             is not in revlog index",
            rev
        ),
    )
}

fn rev_not_in_index(py: Python, rev: UncheckedRevision) -> PyErr {
    PyErr::new::<ValueError, _>(
        py,
        format!("revlog index out of range: {}", rev),
    )
}

/// Standard treatment of NodeMapError
fn nodemap_error(py: Python, err: NodeMapError) -> PyErr {
    match err {
        NodeMapError::MultipleResults => revlog_error(py),
        NodeMapError::RevisionNotInIndex(r) => nodemap_rev_not_in_index(py, r),
    }
}

/// Create the module, with __package__ given from parent
pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.revlog", package);
    let m = PyModule::new(py, dotted_name)?;
    m.add(py, "__package__", package)?;
    m.add(py, "__doc__", "RevLog - Rust implementations")?;

    m.add_class::<NodeTree>(py)?;
    m.add_class::<InnerRevlog>(py)?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;

    Ok(m)
}
