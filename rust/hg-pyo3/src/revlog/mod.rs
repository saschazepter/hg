// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//           2020-2024 Raphaël Gomès <raphael.gomes@octobus.net>
//           2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
use pyo3::buffer::PyBuffer;
use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyBytesMethods, PyList};
use pyo3_sharedref::PyShareable;

use std::sync::{atomic::AtomicUsize, RwLock};

use hg::{
    revlog::{
        index::Index, inner_revlog::InnerRevlog as CoreInnerRevlog,
        nodemap::NodeTree as CoreNodeTree, options::RevlogOpenOptions,
        RevlogType,
    },
    utils::files::get_path_from_bytes,
    vfs::FnCacheVfs,
};

use crate::{
    exceptions::revlog_error_from_msg,
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
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "revlog")?;
    m.add_class::<InnerRevlog>()?;
    Ok(m)
}
