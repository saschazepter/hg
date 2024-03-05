// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::{
    conversion::{rev_pyiter_collect, rev_pyiter_collect_or_else},
    utils::{node_from_py_bytes, node_from_py_object},
    PyRevision,
};
use cpython::{
    buffer::{Element, PyBuffer},
    exc::{IndexError, ValueError},
    ObjectProtocol, PyBool, PyBytes, PyClone, PyDict, PyErr, PyInt, PyList,
    PyModule, PyObject, PyResult, PySet, PyString, PyTuple, Python,
    PythonObject, ToPyObject, UnsafePyLeaked,
};
use hg::{
    errors::HgError,
    index::{
        IndexHeader, Phase, RevisionDataParams, SnapshotsCache,
        INDEX_ENTRY_SIZE,
    },
    nodemap::{Block, NodeMapError, NodeTree as CoreNodeTree},
    revlog::{nodemap::NodeMap, Graph, NodePrefix, RevlogError, RevlogIndex},
    BaseRevision, Node, Revision, UncheckedRevision, NULL_REVISION,
};
use std::{cell::RefCell, collections::HashMap};
use vcsgraph::graph::Graph as VCSGraph;

pub struct PySharedIndex {
    /// The underlying hg-core index
    pub(crate) inner: &'static hg::index::Index,
}

/// Return a Struct implementing the Graph trait
pub(crate) fn py_rust_index_to_graph(
    py: Python,
    index: PyObject,
) -> PyResult<UnsafePyLeaked<PySharedIndex>> {
    let midx = index.extract::<Index>(py)?;
    let leaked = midx.index(py).leak_immutable();
    // Safety: we don't leak the "faked" reference out of the `UnsafePyLeaked`
    Ok(unsafe { leaked.map(py, |idx| PySharedIndex { inner: idx }) })
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

py_class!(pub class Index |py| {
    @shared data index: hg::index::Index;
    data nt: RefCell<Option<CoreNodeTree>>;
    data docket: RefCell<Option<PyObject>>;
    // Holds a reference to the mmap'ed persistent nodemap data
    data nodemap_mmap: RefCell<Option<PyBuffer>>;
    // Holds a reference to the mmap'ed persistent index data
    data index_mmap: RefCell<Option<PyBuffer>>;
    data head_revs_py_list: RefCell<Option<PyList>>;
    data head_node_ids_py_list: RefCell<Option<PyList>>;

    def __new__(
        _cls,
        data: PyObject,
        default_header: u32,
    ) -> PyResult<Self> {
        Self::new(py, data, default_header)
    }

    /// Compatibility layer used for Python consumers needing access to the C index
    ///
    /// Only use case so far is `scmutil.shortesthexnodeidprefix`,
    /// that may need to build a custom `nodetree`, based on a specified revset.
    /// With a Rust implementation of the nodemap, we will be able to get rid of
    /// this, by exposing our own standalone nodemap class,
    /// ready to accept `Index`.
/*    def get_cindex(&self) -> PyResult<PyObject> {
        Ok(self.cindex(py).borrow().inner().clone_ref(py))
    }
*/
    // Index API involving nodemap, as defined in mercurial/pure/parsers.py

    /// Return Revision if found, raises a bare `error.RevlogError`
    /// in case of ambiguity, same as C version does
    def get_rev(&self, node: PyBytes) -> PyResult<Option<PyRevision>> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().unwrap();
        let ridx = &*self.index(py).borrow();
        let node = node_from_py_bytes(py, &node)?;
        let rust_rev =
            nt.find_bin(ridx, node.into()).map_err(|e| nodemap_error(py, e))?;
        Ok(rust_rev.map(Into::into))

    }

    /// same as `get_rev()` but raises a bare `error.RevlogError` if node
    /// is not found.
    ///
    /// No need to repeat `node` in the exception, `mercurial/revlog.py`
    /// will catch and rewrap with it
    def rev(&self, node: PyBytes) -> PyResult<PyRevision> {
        self.get_rev(py, node)?.ok_or_else(|| revlog_error(py))
    }

    /// return True if the node exist in the index
    def has_node(&self, node: PyBytes) -> PyResult<bool> {
        // TODO OPTIM we could avoid a needless conversion here,
        // to do when scaffolding for pure Rust switch is removed,
        // as `get_rev()` currently does the necessary assertions
        self.get_rev(py, node).map(|opt| opt.is_some())
    }

    /// find length of shortest hex nodeid of a binary ID
    def shortest(&self, node: PyBytes) -> PyResult<usize> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().unwrap();
        let idx = &*self.index(py).borrow();
        match nt.unique_prefix_len_node(idx, &node_from_py_bytes(py, &node)?)
        {
            Ok(Some(l)) => Ok(l),
            Ok(None) => Err(revlog_error(py)),
            Err(e) => Err(nodemap_error(py, e)),
        }
    }

    def partialmatch(&self, node: PyObject) -> PyResult<Option<PyBytes>> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().unwrap();
        let idx = &*self.index(py).borrow();

        let node_as_string = if cfg!(feature = "python3-sys") {
            node.cast_as::<PyString>(py)?.to_string(py)?.to_string()
        }
        else {
            let node = node.extract::<PyBytes>(py)?;
            String::from_utf8_lossy(node.data(py)).to_string()
        };

        let prefix = NodePrefix::from_hex(&node_as_string)
            .map_err(|_| PyErr::new::<ValueError, _>(
                py, format!("Invalid node or prefix '{}'", node_as_string))
            )?;

        nt.find_bin(idx, prefix)
            // TODO make an inner API returning the node directly
            .map(|opt| opt.map(
                |rev| PyBytes::new(py, idx.node(rev).unwrap().as_bytes())))
            .map_err(|e| nodemap_error(py, e))

    }

    /// append an index entry
    def append(&self, tup: PyTuple) -> PyResult<PyObject> {
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
        self.index(py)
            .borrow_mut()
            .append(py_tuple_to_revision_data_params(py, tup)?)
            .unwrap();
        let idx = &*self.index(py).borrow();
        self.get_nodetree(py)?.borrow_mut().as_mut().unwrap()
            .insert(idx, &node, rev)
            .map_err(|e| nodemap_error(py, e))?;
        Ok(py.None())
    }

    def __delitem__(&self, key: PyObject) -> PyResult<()> {
        // __delitem__ is both for `del idx[r]` and `del idx[r1:r2]`
        let start = if let Ok(rev) = key.extract(py) {
            UncheckedRevision(rev)
        } else {
            let start = key.getattr(py, "start")?;
            UncheckedRevision(start.extract(py)?)
        };
        let start = self.index(py)
            .borrow()
            .check_revision(start)
            .ok_or_else(|| {
                nodemap_error(py, NodeMapError::RevisionNotInIndex(start))
            })?;
        self.index(py).borrow_mut().remove(start).unwrap();
        let mut opt = self.get_nodetree(py)?.borrow_mut();
        let nt = opt.as_mut().unwrap();
        nt.invalidate_all();
        self.fill_nodemap(py, nt)?;
        Ok(())
    }

    //
    // Index methods previously reforwarded to C index (tp_methods)
    // Same ordering as in revlog.c
    //

    /// return the gca set of the given revs
    def ancestors(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_ancestors(py, args)?;
        Ok(rust_res)
    }

    /// return the heads of the common ancestors of the given revs
    def commonancestorsheads(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_commonancestorsheads(py, args)?;
        Ok(rust_res)
    }

    /// Clear the index caches and inner py_class data.
    /// It is Python's responsibility to call `update_nodemap_data` again.
    def clearcaches(&self) -> PyResult<PyObject> {
        self.nt(py).borrow_mut().take();
        self.docket(py).borrow_mut().take();
        self.nodemap_mmap(py).borrow_mut().take();
        self.head_revs_py_list(py).borrow_mut().take();
        self.head_node_ids_py_list(py).borrow_mut().take();
        self.index(py).borrow().clear_caches();
        Ok(py.None())
    }

    /// return the raw binary string representing a revision
    def entry_binary(&self, *args, **_kw) -> PyResult<PyObject> {
        let rindex = self.index(py).borrow();
        let rev = UncheckedRevision(args.get_item(py, 0).extract(py)?);
        let rust_bytes = rindex.check_revision(rev).and_then(
            |r| rindex.entry_binary(r))
            .ok_or_else(|| rev_not_in_index(py, rev))?;
        let rust_res = PyBytes::new(py, rust_bytes).into_object();
        Ok(rust_res)
    }

    /// return a binary packed version of the header
    def pack_header(&self, *args, **_kw) -> PyResult<PyObject> {
        let rindex = self.index(py).borrow();
        let packed = rindex.pack_header(args.get_item(py, 0).extract(py)?);
        let rust_res = PyBytes::new(py, &packed).into_object();
        Ok(rust_res)
    }

    /// compute phases
    def computephasesmapsets(&self, *args, **_kw) -> PyResult<PyObject> {
        let py_roots = args.get_item(py, 0).extract::<PyDict>(py)?;
        let rust_res = self.inner_computephasesmapsets(py, py_roots)?;
        Ok(rust_res)
    }

    /// reachableroots
    def reachableroots2(&self, *args, **_kw) -> PyResult<PyObject> {
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
    def headrevs(&self) -> PyResult<PyObject> {
        let rust_res = self.inner_headrevs(py)?;
        Ok(rust_res)
    }

    /// get head nodeids
    def head_node_ids(&self) -> PyResult<PyObject> {
        let rust_res = self.inner_head_node_ids(py)?;
        Ok(rust_res)
    }

    /// get diff in head revisions
    def headrevsdiff(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_headrevsdiff(
          py,
          &args.get_item(py, 0),
          &args.get_item(py, 1))?;
        Ok(rust_res)
    }

    /// get filtered head revisions
    def headrevsfiltered(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_headrevsfiltered(py, &args.get_item(py, 0))?;
        Ok(rust_res)
    }

    /// True if the object is a snapshot
    def issnapshot(&self, *args, **_kw) -> PyResult<bool> {
        let index = self.index(py).borrow();
        let result = index
            .is_snapshot(UncheckedRevision(args.get_item(py, 0).extract(py)?))
            .map_err(|e| {
                PyErr::new::<cpython::exc::ValueError, _>(py, e.to_string())
            })?;
        Ok(result)
    }

    /// Gather snapshot data in a cache dict
    def findsnapshots(&self, *args, **_kw) -> PyResult<PyObject> {
        let index = self.index(py).borrow();
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
    def deltachain(&self, *args, **_kw) -> PyResult<PyObject> {
        let index = self.index(py).borrow();
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
        let using_general_delta = args.get_item(py, 2)
            .extract::<Option<u32>>(py)?
            .map(|i| i != 0);
        let (chain, stopped) = index.delta_chain(
            rev, stop_rev, using_general_delta
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
    def slicechunktodensity(&self, *args, **_kw) -> PyResult<PyObject> {
        let rust_res = self.inner_slicechunktodensity(
            py,
            args.get_item(py, 0),
            args.get_item(py, 1).extract(py)?,
            args.get_item(py, 2).extract(py)?
        )?;
        Ok(rust_res)
    }

    // index_sequence_methods and index_mapping_methods.
    //
    // Since we call back through the high level Python API,
    // there's no point making a distinction between index_get
    // and index_getitem.
    // gracinet 2023: this above is no longer true for the pure Rust impl

    def __len__(&self) -> PyResult<usize> {
        self.len(py)
    }

    def __getitem__(&self, key: PyObject) -> PyResult<PyObject> {
        let rust_res = self.inner_getitem(py, key.clone_ref(py))?;
        Ok(rust_res)
    }

    def __contains__(&self, item: PyObject) -> PyResult<bool> {
        // ObjectProtocol does not seem to provide contains(), so
        // this is an equivalent implementation of the index_contains()
        // defined in revlog.c
        match item.extract::<i32>(py) {
            Ok(rev) => {
                Ok(rev >= -1 && rev < self.len(py)? as BaseRevision)
            }
            Err(_) => {
                let item_bytes: PyBytes = item.extract(py)?;
                let rust_res = self.has_node(py, item_bytes)?;
                Ok(rust_res)
            }
        }
    }

    def nodemap_data_all(&self) -> PyResult<PyBytes> {
        self.inner_nodemap_data_all(py)
    }

    def nodemap_data_incremental(&self) -> PyResult<PyObject> {
        self.inner_nodemap_data_incremental(py)
    }
    def update_nodemap_data(
        &self,
        docket: PyObject,
        nm_data: PyObject
    ) -> PyResult<PyObject> {
        self.inner_update_nodemap_data(py, docket, nm_data)
    }

    @property
    def entry_size(&self) -> PyResult<PyInt> {
        let rust_res: PyInt = INDEX_ENTRY_SIZE.to_py_object(py);
        Ok(rust_res)
    }

    @property
    def rust_ext_compat(&self) -> PyResult<PyInt> {
        // will be entirely removed when the Rust index yet useful to
        // implement in Rust to detangle things when removing `self.cindex`
        let rust_res: PyInt = 1.to_py_object(py);
        Ok(rust_res)
    }

    @property
    def is_rust(&self) -> PyResult<PyBool> {
        Ok(false.to_py_object(py))
    }

});

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
            "Nodemap data buffer has an invalid memory representation"
                .to_string(),
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
        .unwrap();
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

impl Index {
    fn new(py: Python, data: PyObject, header: u32) -> PyResult<Self> {
        // Safety: we keep the buffer around inside the class as `index_mmap`
        let (buf, bytes) = unsafe { mmap_keeparound(py, data)? };

        Self::create_instance(
            py,
            hg::index::Index::new(
                bytes,
                IndexHeader::parse(&header.to_be_bytes())
                    .expect("default header is broken")
                    .unwrap(),
            )
            .map_err(|e| {
                revlog_error_with_msg(py, e.to_string().as_bytes())
            })?,
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(Some(buf)),
            RefCell::new(None),
            RefCell::new(None),
        )
    }

    fn len(&self, py: Python) -> PyResult<usize> {
        let rust_index_len = self.index(py).borrow().len();
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
        let index = self.index(py).borrow();
        for r in 0..self.len(py)? {
            let rev = Revision(r as BaseRevision);
            // in this case node() won't ever return None
            nt.insert(&*index, index.node(rev).unwrap(), rev)
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
        let nodemap = self.get_nodetree(py)?.borrow_mut().take().unwrap();
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

        let node_tree = self.get_nodetree(py)?.borrow_mut().take().unwrap();
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
        let idx = self.index(py).borrow();
        let data_tip = idx.check_revision(data_tip).ok_or_else(|| {
            nodemap_error(py, NodeMapError::RevisionNotInIndex(data_tip))
        })?;
        let current_tip = idx.len();

        for r in (data_tip.0 + 1)..current_tip as BaseRevision {
            let rev = Revision(r);
            // in this case node() won't ever return None
            nt.insert(&*idx, idx.node(rev).unwrap(), rev)
                .map_err(|e| nodemap_error(py, e))?
        }

        *self.nt(py).borrow_mut() = Some(nt);

        Ok(py.None())
    }

    fn inner_getitem(&self, py: Python, key: PyObject) -> PyResult<PyObject> {
        let idx = self.index(py).borrow();
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
            _ => self.get_rev(py, key.extract::<PyBytes>(py)?)?.map_or_else(
                || py.None(),
                |py_rev| py_rev.into_py_object(py).into_object(),
            ),
        })
    }

    fn inner_head_node_ids(&self, py: Python) -> PyResult<PyObject> {
        let index = &*self.index(py).borrow();

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

    fn inner_headrevs(&self, py: Python) -> PyResult<PyObject> {
        let index = &*self.index(py).borrow();
        if let Some(new_heads) =
            index.head_revs_shortcut().map_err(|e| graph_error(py, e))?
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

    fn check_revision(
        index: &hg::index::Index,
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
        let index = &*self.index(py).borrow();
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

    fn inner_headrevsfiltered(
        &self,
        py: Python,
        filtered_revs: &PyObject,
    ) -> PyResult<PyObject> {
        let index = &*self.index(py).borrow();
        let filtered_revs = rev_pyiter_collect(py, filtered_revs, index)?;

        if let Some(new_heads) = index
            .head_revs_filtered(&filtered_revs, true)
            .map_err(|e| graph_error(py, e))?
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

    fn cache_new_heads_node_ids_py_list(
        &self,
        new_heads: &[Revision],
        py: Python<'_>,
    ) -> PyList {
        let index = self.index(py).borrow();
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
        let index = &*self.index(py).borrow();
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
        let index = &*self.index(py).borrow();
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
        let index = &*self.index(py).borrow();
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
        let index = &*self.index(py).borrow();
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
        let index = &*self.index(py).borrow();
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
        let leaked = self.index(py).borrow();
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
        let leaked = self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let index = &*unsafe { leaked.try_borrow(py)? };

        let rev = UncheckedRevision(rev.0);
        let rev = index
            .check_revision(rev)
            .ok_or_else(|| rev_not_in_index(py, rev))?;
        if rev == NULL_REVISION {
            return Err(rev_not_in_index(py, rev.into()))
        }

        let entry = index.inner.get_entry(rev).unwrap();
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
        let leaked = self.index(py).borrow();
        // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
        let index = &*unsafe { leaked.try_borrow(py)? };

        Ok(nt.find_bin(index, prefix)
               .map_err(|e| nodemap_error(py, e))?
               .map(|r| r.into())
        )
    }

    def shortest(&self, node: PyBytes) -> PyResult<usize> {
        let nt = self.nt(py).borrow();
        let leaked = self.index(py).borrow();
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

fn revlog_error_with_msg(py: Python, msg: &[u8]) -> PyErr {
    match py
        .import("mercurial.error")
        .and_then(|m| m.get(py, "RevlogError"))
    {
        Err(e) => e,
        Ok(cls) => PyErr::from_instance(
            py,
            cls.call(py, (PyBytes::new(py, msg),), None)
                .ok()
                .into_py_object(py),
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

    m.add_class::<Index>(py)?;
    m.add_class::<NodeTree>(py)?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;

    Ok(m)
}
