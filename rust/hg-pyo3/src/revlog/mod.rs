// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//           2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
#![allow(non_snake_case)]
use pyo3::buffer::PyBuffer;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyBytesMethods, PyList};
use pyo3_sharedref::PyShareable;

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    RwLock, RwLockReadGuard, RwLockWriteGuard,
};

use hg::{
    revlog::{
        index::Index,
        inner_revlog::InnerRevlog as CoreInnerRevlog,
        nodemap::{NodeMap, NodeTree as CoreNodeTree},
        options::RevlogOpenOptions,
        RevlogIndex, RevlogType,
    },
    utils::files::get_path_from_bytes,
    vfs::FnCacheVfs,
    BaseRevision, Revision,
};

use crate::{
    exceptions::{
        map_lock_error, map_try_lock_error, nodemap_error, revlog_error_bare,
        revlog_error_from_msg,
    },
    node::{node_from_py_bytes, node_prefix_from_py_bytes, py_node_for_rev},
    revision::PyRevision,
    store::PyFnCache,
    util::{new_submodule, take_buffer_with_slice},
};

mod config;
use config::*;

#[pyclass]
#[allow(dead_code)]
struct InnerRevlog {
    irl: PyShareable<CoreInnerRevlog>,
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

    fn _index___len__(slf: &Bound<'_, Self>) -> PyResult<usize> {
        Self::with_index_read(slf, |idx| Ok(idx.len()))
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "revlog")?;
    m.add_class::<InnerRevlog>()?;
    Ok(m)
}
