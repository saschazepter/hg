// revlog.rs
//
// Copyright 2019-2020 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::{
    cindex,
    utils::{node_from_py_bytes, node_from_py_object},
    PyRevision,
};
use cpython::{
    buffer::{Element, PyBuffer},
    exc::{IndexError, ValueError},
    ObjectProtocol, PyBool, PyBytes, PyClone, PyDict, PyErr, PyInt, PyList,
    PyModule, PyObject, PyResult, PySet, PyString, PyTuple, Python,
    PythonObject, ToPyObject,
};
use hg::{
    errors::HgError,
    index::{IndexHeader, RevisionDataParams, SnapshotsCache},
    nodemap::{Block, NodeMapError, NodeTree},
    revlog::{nodemap::NodeMap, NodePrefix, RevlogError, RevlogIndex},
    BaseRevision, Revision, UncheckedRevision, NULL_REVISION,
};
use std::cell::RefCell;

/// Return a Struct implementing the Graph trait
pub(crate) fn pyindex_to_graph(
    py: Python,
    index: PyObject,
) -> PyResult<cindex::Index> {
    match index.extract::<MixedIndex>(py) {
        Ok(midx) => Ok(midx.clone_cindex(py)),
        Err(_) => cindex::Index::new(py, index),
    }
}

py_class!(pub class MixedIndex |py| {
    data cindex: RefCell<cindex::Index>;
    data index: RefCell<hg::index::Index>;
    data nt: RefCell<Option<NodeTree>>;
    data docket: RefCell<Option<PyObject>>;
    // Holds a reference to the mmap'ed persistent nodemap data
    data nodemap_mmap: RefCell<Option<PyBuffer>>;
    // Holds a reference to the mmap'ed persistent index data
    data index_mmap: RefCell<Option<PyBuffer>>;

    def __new__(
        _cls,
        cindex: PyObject,
        data: PyObject,
        default_header: u32,
    ) -> PyResult<MixedIndex> {
        Self::new(py, cindex, data, default_header)
    }

    /// Compatibility layer used for Python consumers needing access to the C index
    ///
    /// Only use case so far is `scmutil.shortesthexnodeidprefix`,
    /// that may need to build a custom `nodetree`, based on a specified revset.
    /// With a Rust implementation of the nodemap, we will be able to get rid of
    /// this, by exposing our own standalone nodemap class,
    /// ready to accept `MixedIndex`.
    def get_cindex(&self) -> PyResult<PyObject> {
        Ok(self.cindex(py).borrow().inner().clone_ref(py))
    }

    // Index API involving nodemap, as defined in mercurial/pure/parsers.py

    /// Return Revision if found, raises a bare `error.RevlogError`
    /// in case of ambiguity, same as C version does
    def get_rev(&self, node: PyBytes) -> PyResult<Option<PyRevision>> {
        let opt = self.get_nodetree(py)?.borrow();
        let nt = opt.as_ref().unwrap();
        let idx = &*self.cindex(py).borrow();
        let ridx = &*self.index(py).borrow();
        let node = node_from_py_bytes(py, &node)?;
        let rust_rev =
            nt.find_bin(ridx, node.into()).map_err(|e| nodemap_error(py, e))?;
        let c_rev =
            nt.find_bin(idx, node.into()).map_err(|e| nodemap_error(py, e))?;
        assert_eq!(rust_rev, c_rev);
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
        let mut idx = self.cindex(py).borrow_mut();

        // This is ok since we will just add the revision to the index
        let rev = Revision(rev);
        idx.append(py, tup.clone_ref(py))?;
        self.index(py)
            .borrow_mut()
            .append(py_tuple_to_revision_data_params(py, tup)?)
            .unwrap();
        self.get_nodetree(py)?.borrow_mut().as_mut().unwrap()
            .insert(&*idx, &node, rev)
            .map_err(|e| nodemap_error(py, e))?;
        Ok(py.None())
    }

    def __delitem__(&self, key: PyObject) -> PyResult<()> {
        // __delitem__ is both for `del idx[r]` and `del idx[r1:r2]`
        self.cindex(py).borrow().inner().del_item(py, &key)?;
        let start = key.getattr(py, "start")?;
        let start = UncheckedRevision(start.extract(py)?);
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
    // Reforwarded C index API
    //

    // index_methods (tp_methods). Same ordering as in revlog.c

    /// return the gca set of the given revs
    def ancestors(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "ancestors", args, kw)
    }

    /// return the heads of the common ancestors of the given revs
    def commonancestorsheads(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "commonancestorsheads", args, kw)
    }

    /// Clear the index caches and inner py_class data.
    /// It is Python's responsibility to call `update_nodemap_data` again.
    def clearcaches(&self, *args, **kw) -> PyResult<PyObject> {
        self.nt(py).borrow_mut().take();
        self.docket(py).borrow_mut().take();
        self.nodemap_mmap(py).borrow_mut().take();
        self.index(py).borrow_mut().clear_caches();
        self.call_cindex(py, "clearcaches", args, kw)
    }

    /// return the raw binary string representing a revision
    def entry_binary(&self, *args, **kw) -> PyResult<PyObject> {
        let rindex = self.index(py).borrow();
        let rev = UncheckedRevision(args.get_item(py, 0).extract(py)?);
        let rust_bytes = rindex.check_revision(rev).and_then(
            |r| rindex.entry_binary(r))
            .ok_or_else(|| rev_not_in_index(py, rev))?;
        let rust_res = PyBytes::new(py, rust_bytes).into_object();

        let c_res = self.call_cindex(py, "entry_binary", args, kw)?;
        assert_py_eq(py, "entry_binary", &rust_res, &c_res)?;
        Ok(rust_res)
    }

    /// return a binary packed version of the header
    def pack_header(&self, *args, **kw) -> PyResult<PyObject> {
        let rindex = self.index(py).borrow();
        let packed = rindex.pack_header(args.get_item(py, 0).extract(py)?);
        let rust_res = PyBytes::new(py, &packed).into_object();

        let c_res = self.call_cindex(py, "pack_header", args, kw)?;
        assert_py_eq(py, "pack_header", &rust_res, &c_res)?;
        Ok(rust_res)
    }

    /// compute phases
    def computephasesmapsets(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "computephasesmapsets", args, kw)
    }

    /// reachableroots
    def reachableroots2(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "reachableroots2", args, kw)
    }

    /// get head revisions
    def headrevs(&self, *args, **kw) -> PyResult<PyObject> {
        let rust_res = self.inner_headrevs(py)?;

        let c_res = self.call_cindex(py, "headrevs", args, kw)?;
        assert_py_eq(py, "headrevs", &rust_res, &c_res)?;
        Ok(rust_res)
    }

    /// get filtered head revisions
    def headrevsfiltered(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "headrevsfiltered", args, kw)
    }

    /// True if the object is a snapshot
    def issnapshot(&self, *args, **kw) -> PyResult<bool> {
        let index = self.index(py).borrow();
        let result = index
            .is_snapshot(UncheckedRevision(args.get_item(py, 0).extract(py)?))
            .map_err(|e| {
                PyErr::new::<cpython::exc::ValueError, _>(py, e.to_string())
            })?;
        let cresult = self.call_cindex(py, "issnapshot", args, kw)?;
        assert_eq!(result, cresult.extract(py)?);
        Ok(result)
    }

    /// Gather snapshot data in a cache dict
    def findsnapshots(&self, *args, **kw) -> PyResult<PyObject> {
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

        let c_args = PyTuple::new(
            py,
            &[
                c_cache.clone_ref(py).into_object(),
                args.get_item(py, 1),
                args.get_item(py, 2)
            ]
        );
        self.call_cindex(py, "findsnapshots", &c_args, kw)?;
        assert_py_eq(py, "findsnapshots cache",
                     &cache_wrapper.into_object(),
                     &c_cache.into_object())?;
        Ok(py.None())
    }

    /// determine revisions with deltas to reconstruct fulltext
    def deltachain(&self, *args, **kw) -> PyResult<PyObject> {
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
        let (chain, stopped) = index.delta_chain(rev, stop_rev).map_err(|e| {
            PyErr::new::<cpython::exc::ValueError, _>(py, e.to_string())
        })?;

        let cresult = self.call_cindex(py, "deltachain", args, kw)?;
        let cchain: Vec<BaseRevision> =
            cresult.get_item(py, 0)?.extract::<Vec<BaseRevision>>(py)?;
        let chain: Vec<_> = chain.into_iter().map(|r| r.0).collect();
        assert_eq!(chain, cchain);
        assert_eq!(stopped, cresult.get_item(py, 1)?.extract(py)?);

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
    def slicechunktodensity(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "slicechunktodensity", args, kw)
    }

    /// stats for the index
    def stats(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "stats", args, kw)
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

        // this conversion seems needless, but that's actually because
        // `index_getitem` does not handle conversion from PyLong,
        // which expressions such as [e for e in index] internally use.
        // Note that we don't seem to have a direct way to call
        // PySequence_GetItem (does the job), which would possibly be better
        // for performance
        // gracinet 2023: the above comment can be removed when we use
        // the pure Rust impl only. Note also that `key` can be a binary
        // node id.
        let c_key = match key.extract::<BaseRevision>(py) {
            Ok(rev) => rev.to_py_object(py).into_object(),
            Err(_) => key,
        };
        let c_res = self.cindex(py).borrow().inner().get_item(py, c_key)?;

        assert_py_eq(py, "__getitem__", &rust_res, &c_res)?;
        Ok(rust_res)
    }

    def __contains__(&self, item: PyObject) -> PyResult<bool> {
        // ObjectProtocol does not seem to provide contains(), so
        // this is an equivalent implementation of the index_contains()
        // defined in revlog.c
        let cindex = self.cindex(py).borrow();
        match item.extract::<i32>(py) {
            Ok(rev) => {
                Ok(rev >= -1 && rev < self.len(py)? as BaseRevision)
            }
            Err(_) => {
                let item_bytes: PyBytes = item.extract(py)?;
                let rust_res = self.has_node(py, item_bytes)?;

                let c_res = cindex.inner().call_method(
                    py,
                    "has_node",
                    PyTuple::new(py, &[item.clone_ref(py)]),
                    None)?
                .extract(py)?;

                assert_eq!(rust_res, c_res);
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
        self.cindex(py).borrow().inner().getattr(py, "entry_size")?.extract::<PyInt>(py)
    }

    @property
    def rust_ext_compat(&self) -> PyResult<PyInt> {
        self.cindex(py).borrow().inner().getattr(py, "rust_ext_compat")?.extract::<PyInt>(py)
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
    Box<dyn std::ops::Deref<Target = [u8]> + Send + 'static>,
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

impl<'p> PySnapshotsCache<'p> {
    fn into_object(self) -> PyObject {
        self.dict.into_object()
    }
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

impl MixedIndex {
    fn new(
        py: Python,
        cindex: PyObject,
        data: PyObject,
        header: u32,
    ) -> PyResult<MixedIndex> {
        // Safety: we keep the buffer around inside the class as `index_mmap`
        let (buf, bytes) = unsafe { mmap_keeparound(py, data)? };

        Self::create_instance(
            py,
            RefCell::new(cindex::Index::new(py, cindex)?),
            RefCell::new(
                hg::index::Index::new(
                    bytes,
                    IndexHeader::parse(&header.to_be_bytes())
                        .expect("default header is broken")
                        .unwrap(),
                )
                .unwrap(),
            ),
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(None),
            RefCell::new(Some(buf)),
        )
    }

    fn len(&self, py: Python) -> PyResult<usize> {
        let rust_index_len = self.index(py).borrow().len();
        let cindex_len = self.cindex(py).borrow().inner().len(py)?;
        assert_eq!(rust_index_len, cindex_len);
        Ok(cindex_len)
    }

    /// This is scaffolding at this point, but it could also become
    /// a way to start a persistent nodemap or perform a
    /// vacuum / repack operation
    fn fill_nodemap(
        &self,
        py: Python,
        nt: &mut NodeTree,
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
    ) -> PyResult<&'a RefCell<Option<NodeTree>>> {
        if self.nt(py).borrow().is_none() {
            let readonly = Box::<Vec<_>>::default();
            let mut nt = NodeTree::load_bytes(readonly, 0);
            self.fill_nodemap(py, &mut nt)?;
            self.nt(py).borrow_mut().replace(nt);
        }
        Ok(self.nt(py))
    }

    /// forward a method call to the underlying C index
    fn call_cindex(
        &self,
        py: Python,
        name: &str,
        args: &PyTuple,
        kwargs: Option<&PyDict>,
    ) -> PyResult<PyObject> {
        self.cindex(py)
            .borrow()
            .inner()
            .call_method(py, name, args, kwargs)
    }

    pub fn clone_cindex(&self, py: Python) -> cindex::Index {
        self.cindex(py).borrow().clone_ref(py)
    }

    /// Returns the full nodemap bytes to be written as-is to disk
    fn inner_nodemap_data_all(&self, py: Python) -> PyResult<PyBytes> {
        let nodemap = self.get_nodetree(py)?.borrow_mut().take().unwrap();
        let (readonly, bytes) = nodemap.into_readonly_and_added_bytes();

        // If there's anything readonly, we need to build the data again from
        // scratch
        let bytes = if readonly.len() > 0 {
            let mut nt = NodeTree::load_bytes(Box::<Vec<_>>::default(), 0);
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

        let mut nt = NodeTree::load_bytes(bytes, len);

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

    fn inner_headrevs(&self, py: Python) -> PyResult<PyObject> {
        let index = &mut *self.index(py).borrow_mut();
        let as_vec: Vec<PyObject> = index
            .head_revs()
            .map_err(|e| graph_error(py, e))?
            .iter()
            .map(|r| PyRevision::from(*r).into_py_object(py).into_object())
            .collect();
        Ok(PyList::new(py, &as_vec).into_object())
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

/// assert two Python objects to be equal from a Python point of view
///
/// `method` is a label for the assertion error message, intended to be the
/// name of the caller.
/// `normalizer` is a function that takes a Python variable name and returns
/// an expression that the conparison will actually use.
/// Foe example: `|v| format!("sorted({})", v)`
fn assert_py_eq_normalized(
    py: Python,
    method: &str,
    rust: &PyObject,
    c: &PyObject,
    normalizer: impl FnOnce(&str) -> String + Copy,
) -> PyResult<()> {
    let locals = PyDict::new(py);
    locals.set_item(py, "rust".into_py_object(py).into_object(), rust)?;
    locals.set_item(py, "c".into_py_object(py).into_object(), c)?;
    //    let lhs = format!(normalizer_fmt, "rust");
    //    let rhs = format!(normalizer_fmt, "c");
    let is_eq: PyBool = py
        .eval(
            &format!("{} == {}", &normalizer("rust"), &normalizer("c")),
            None,
            Some(&locals),
        )?
        .extract(py)?;
    assert!(
        is_eq.is_true(),
        "{} results differ. Rust: {:?} C: {:?} (before any normalization)",
        method,
        rust,
        c
    );
    Ok(())
}

fn assert_py_eq(
    py: Python,
    method: &str,
    rust: &PyObject,
    c: &PyObject,
) -> PyResult<()> {
    assert_py_eq_normalized(py, method, rust, c, |v| v.to_owned())
}

/// Create the module, with __package__ given from parent
pub fn init_module(py: Python, package: &str) -> PyResult<PyModule> {
    let dotted_name = &format!("{}.revlog", package);
    let m = PyModule::new(py, dotted_name)?;
    m.add(py, "__package__", package)?;
    m.add(py, "__doc__", "RevLog - Rust implementations")?;

    m.add_class::<MixedIndex>(py)?;

    let sys = PyModule::import(py, "sys")?;
    let sys_modules: PyDict = sys.get(py, "modules")?.extract(py)?;
    sys_modules.set_item(py, dotted_name, &m)?;

    Ok(m)
}
