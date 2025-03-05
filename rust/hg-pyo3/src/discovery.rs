//! Discovery of common node sets
use std::collections::HashSet;

use hg::{discovery::PartialDiscovery as CorePartialDiscovery, Revision};
use pyo3::{
    intern, pyclass, pymethods,
    types::{PyAnyMethods, PyDict, PyModule, PyModuleMethods, PyTuple},
    Bound, Py, PyAny, PyObject, PyResult, Python,
};
use pyo3_sharedref::SharedByPyObject;

use crate::{
    exceptions::GraphError,
    revision::{rev_pyiter_collect, PyRevision},
    revlog::PySharedIndex,
    utils::{new_submodule, py_rust_index_to_graph},
};

#[pyclass]
struct PartialDiscovery {
    inner: SharedByPyObject<CorePartialDiscovery<PySharedIndex>>,
    idx: SharedByPyObject<PySharedIndex>,
}

#[pymethods]
impl PartialDiscovery {
    #[pyo3(signature = (repo, targetheads, respectsize, randomize=true))]
    #[new]
    fn new(
        py: Python,
        repo: &Bound<'_, PyAny>,
        targetheads: &Bound<'_, PyAny>,
        respectsize: bool,
        randomize: bool,
    ) -> PyResult<Self> {
        let index = repo
            .getattr(intern!(py, "changelog"))?
            .getattr(intern!(py, "index"))?;
        let cloned_index = py_rust_index_to_graph(&index.clone())?;
        let index = py_rust_index_to_graph(&index)?;

        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let target_heads = {
            let borrowed_idx = unsafe { index.try_borrow(py)? };
            rev_pyiter_collect(targetheads, &*borrowed_idx)?
        };
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let lazy_disco = unsafe {
            index.map(py, |idx| {
                CorePartialDiscovery::new(
                    idx,
                    target_heads,
                    respectsize,
                    randomize,
                )
            })
        };
        Ok(Self {
            inner: lazy_disco,
            idx: cloned_index,
        })
    }

    fn addcommons(
        &mut self,
        py: Python,
        commons: &Bound<'_, PyAny>,
    ) -> PyResult<PyObject> {
        let commons = self.pyiter_to_vec(commons)?;
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let mut inner = unsafe { self.inner.try_borrow_mut(py)? };
        inner
            .add_common_revisions(commons)
            .map_err(GraphError::from_hg)?;
        Ok(py.None())
    }

    fn addmissings(
        &mut self,
        py: Python,
        missings: &Bound<'_, PyAny>,
    ) -> PyResult<PyObject> {
        let missings = self.pyiter_to_vec(missings)?;
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let mut inner = unsafe { self.inner.try_borrow_mut(py)? };
        inner
            .add_missing_revisions(missings)
            .map_err(GraphError::from_hg)?;
        Ok(py.None())
    }

    fn addinfo(
        &mut self,
        py: Python,
        sample: &Bound<'_, PyAny>,
    ) -> PyResult<PyObject> {
        let mut missing: Vec<Revision> = vec![];
        let mut common: Vec<Revision> = vec![];
        for info in sample.try_iter()? {
            // info is a pair (Revision, bool)
            let info = info?;
            let info = info.downcast::<PyTuple>()?;
            let rev: PyRevision = info.get_item(0)?.extract()?;
            // This is fine since we're just using revisions as integers
            // for the purposes of discovery
            let rev = Revision(rev.0);
            let known: bool = info.get_item(1)?.extract()?;
            if known {
                common.push(rev);
            } else {
                missing.push(rev);
            }
        }
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let mut inner = unsafe { self.inner.try_borrow_mut(py)? };
        inner
            .add_common_revisions(common)
            .map_err(GraphError::from_hg)?;
        inner
            .add_missing_revisions(missing)
            .map_err(GraphError::from_hg)?;
        Ok(py.None())
    }

    fn hasinfo(&self, py: Python<'_>) -> PyResult<bool> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let inner = unsafe { self.inner.try_borrow(py)? };
        Ok(inner.has_info())
    }

    fn iscomplete(&self, py: Python<'_>) -> PyResult<bool> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let inner = unsafe { self.inner.try_borrow(py)? };
        Ok(inner.is_complete())
    }

    fn stats(&self, py: Python<'_>) -> PyResult<Py<PyDict>> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let inner = unsafe { self.inner.try_borrow(py)? };
        let stats = inner.stats();
        let as_dict = PyDict::new(py);
        as_dict.set_item("undecided", stats.undecided)?;
        Ok(as_dict.unbind())
    }

    fn commonheads(&self, py: Python<'_>) -> PyResult<HashSet<PyRevision>> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let inner = unsafe { self.inner.try_borrow(py)? };
        let common_heads =
            inner.common_heads().map_err(GraphError::from_hg)?;
        Ok(common_heads.into_iter().map(Into::into).collect())
    }

    fn takefullsample(
        &mut self,
        py: Python,
        _headrevs: &Bound<'_, PyAny>,
        size: usize,
    ) -> PyResult<Py<PyTuple>> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let mut inner = unsafe { self.inner.try_borrow_mut(py)? };
        let sample =
            inner.take_full_sample(size).map_err(GraphError::from_hg)?;
        let as_pyrevision = sample.into_iter().map(|rev| PyRevision(rev.0));
        Ok(PyTuple::new(py, as_pyrevision)?.unbind())
    }

    fn takequicksample(
        &mut self,
        py: Python,
        headrevs: &Bound<'_, PyAny>,
        size: usize,
    ) -> PyResult<Py<PyTuple>> {
        let revs = self.pyiter_to_vec(headrevs)?;
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let mut inner = unsafe { self.inner.try_borrow_mut(py)? };
        let sample = inner
            .take_quick_sample(revs, size)
            .map_err(GraphError::from_hg)?;
        let as_pyrevision = sample.into_iter().map(|rev| PyRevision(rev.0));
        Ok(PyTuple::new(py, as_pyrevision)?.unbind())
    }
}

impl PartialDiscovery {
    /// Convert a Python iterator of revisions into a vector
    fn pyiter_to_vec(
        &self,
        iter: &Bound<'_, PyAny>,
    ) -> PyResult<Vec<Revision>> {
        // Safety: we don't leak any reference derived form the "faked" one in
        // `SharedByPyObject`
        let index = unsafe { self.idx.try_borrow(iter.py())? };
        rev_pyiter_collect(iter, &*index)
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "discovery")?;
    m.add_class::<PartialDiscovery>()?;
    Ok(m)
}
