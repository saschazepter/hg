// revlog.rs
//
// Copyright 2019 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::cindex;
use cpython::{
    ObjectProtocol, PyClone, PyDict, PyModule, PyObject, PyResult, PyTuple, Python, PythonObject,
    ToPyObject,
};
use hg::Revision;
use std::cell::RefCell;

/// Return a Struct implementing the Graph trait
pub(crate) fn pyindex_to_graph(py: Python, index: PyObject) -> PyResult<cindex::Index> {
    cindex::Index::new(py, index)
}

py_class!(pub class MixedIndex |py| {
    data cindex: RefCell<cindex::Index>;

    def __new__(_cls, cindex: PyObject) -> PyResult<MixedIndex> {
        Self::create_instance(py, RefCell::new(
            cindex::Index::new(py, cindex)?))
    }


    // Reforwarded C index API

    // index_methods (tp_methods). Same ordering as in revlog.c

    /// return the gca set of the given revs
    def ancestors(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "ancestors", args, kw)
    }

    /// return the heads of the common ancestors of the given revs
    def commonancestorsheads(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "commonancestorsheads", args, kw)
    }

    /// clear the index caches
    def clearcaches(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "clearcaches", args, kw)
    }

    /// get an index entry
    def get(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "get", args, kw)
    }

    /// return `rev` associated with a node or None
    def get_rev(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "get_rev", args, kw)
    }

    /// return True if the node exist in the index
    def has_node(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "has_node", args, kw)
    }

    /// return `rev` associated with a node or raise RevlogError
    def rev(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "rev", args, kw)
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
        self.call_cindex(py, "headrevs", args, kw)
    }

    /// get filtered head revisions
    def headrevsfiltered(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "headrevsfiltered", args, kw)
    }

    /// True if the object is a snapshot
    def issnapshot(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "issnapshot", args, kw)
    }

    /// Gather snapshot data in a cache dict
    def findsnapshots(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "findsnapshots", args, kw)
    }

    /// determine revisions with deltas to reconstruct fulltext
    def deltachain(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "deltachain", args, kw)
    }

    /// slice planned chunk read to reach a density threshold
    def slicechunktodensity(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "slicechunktodensity", args, kw)
    }

    /// append an index entry
    def append(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "append", args, kw)
    }

    /// match a potentially ambiguous node ID
    def partialmatch(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "partialmatch", args, kw)
    }

    /// find length of shortest hex nodeid of a binary ID
    def shortest(&self, *args, **kw) -> PyResult<PyObject> {
        self.call_cindex(py, "shortest", args, kw)
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

    def __len__(&self) -> PyResult<usize> {
        self.cindex(py).borrow().inner().len(py)
    }

    def __getitem__(&self, key: PyObject) -> PyResult<PyObject> {
        // this conversion seems needless, but that's actually because
        // `index_getitem` does not handle conversion from PyLong,
        // which expressions such as [e for e in index] internally use.
        // Note that we don't seem to have a direct way to call
        // PySequence_GetItem (does the job), which would be better for
        // for performance
        let key = match key.extract::<Revision>(py) {
            Ok(rev) => rev.to_py_object(py).into_object(),
            Err(_) => key,
        };
        self.cindex(py).borrow().inner().get_item(py, key)
    }

    def __setitem__(&self, key: PyObject, value: PyObject) -> PyResult<()> {
        self.cindex(py).borrow().inner().set_item(py, key, value)
    }

    def __delitem__(&self, key: PyObject) -> PyResult<()> {
        self.cindex(py).borrow().inner().del_item(py, key)
    }

    def __contains__(&self, item: PyObject) -> PyResult<bool> {
        // ObjectProtocol does not seem to provide contains(), so
        // this is an equivalent implementation of the index_contains()
        // defined in revlog.c
        let cindex = self.cindex(py).borrow();
        match item.extract::<Revision>(py) {
            Ok(rev) => {
                Ok(rev >= -1 && rev < cindex.inner().len(py)? as Revision)
            }
            Err(_) => {
                cindex.inner().call_method(
                    py,
                    "has_node",
                    PyTuple::new(py, &[item]),
                    None)?
                .extract(py)
            }
        }
    }


});

impl MixedIndex {
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
