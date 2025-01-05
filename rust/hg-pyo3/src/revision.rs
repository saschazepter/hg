use pyo3::prelude::*;
use pyo3::types::{PyList, PySet};

use hg::revlog::RevlogIndex;
use hg::{BaseRevision, Revision, UncheckedRevision};

use crate::exceptions::{rev_not_in_index, GraphError};
use crate::utils::proxy_index_extract;

/// Revision as exposed to/from the Python layer.
///
/// We need this indirection because of the orphan rule, meaning we can't
/// implement a foreign trait (like [`cpython::ToPyObject`])
/// for a foreign type (like [`hg::UncheckedRevision`]).
///
/// This also acts as a deterrent against blindly trusting Python to send
/// us valid revision numbers.
#[derive(
    Debug,
    Copy,
    Clone,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
    Hash,
    derive_more::From,
    IntoPyObject,
    FromPyObject,
)]
pub struct PyRevision(pub BaseRevision);

impl From<Revision> for PyRevision {
    fn from(r: Revision) -> Self {
        PyRevision(r.0)
    }
}

impl From<PyRevision> for UncheckedRevision {
    fn from(val: PyRevision) -> Self {
        val.0.into()
    }
}

pub fn check_revision(
    index: &impl RevlogIndex,
    rev: impl Into<UncheckedRevision>,
) -> PyResult<Revision> {
    let rev = rev.into();
    index
        .check_revision(rev)
        .ok_or_else(|| rev_not_in_index(rev))
}

/// Utility function to convert a Python iterable into various collections
///
/// We need this in particular
/// - because of the checked upgrade from [`PyRevision`] to [`Revision`].
/// - to feed to various methods of inner objects with `impl
///   IntoIterator<Item=Revision>` arguments, because a `PyErr` can arise at
///   each step of iteration, whereas these methods expect iterables over
///   `Revision`, not over some `Result<Revision, PyErr>`
pub fn rev_pyiter_collect<C, I>(
    revs: &Bound<'_, PyAny>,
    index: &I,
) -> PyResult<C>
where
    C: FromIterator<Revision>,
    I: RevlogIndex,
{
    rev_pyiter_collect_or_else(revs, index, |r| {
        PyErr::new::<GraphError, _>(("InvalidRevision", r.0))
    })
}

pub fn rev_pyiter_collect_with_py_index<C>(
    revs: &Bound<'_, PyAny>,
    proxy_index: &Bound<'_, PyAny>,
) -> PyResult<C>
where
    C: FromIterator<Revision>,
{
    // Safety: we don't leak the "faked" reference out of `UnsafePyLeaked`
    let borrowed_idx = unsafe { proxy_index_extract(proxy_index)? };
    rev_pyiter_collect(revs, borrowed_idx)
}

/// Same as [`rev_pyiter_collect`], giving control on returned errors
pub fn rev_pyiter_collect_or_else<C, I>(
    revs: &Bound<'_, PyAny>,
    index: &I,
    invalid_rev_error: impl FnOnce(PyRevision) -> PyErr + Copy,
) -> PyResult<C>
where
    C: FromIterator<Revision>,
    I: RevlogIndex,
{
    revs.try_iter()?
        .map(|r| {
            r.and_then(|o| match o.extract::<PyRevision>() {
                Ok(r) => index
                    .check_revision(UncheckedRevision(r.0))
                    .ok_or_else(|| invalid_rev_error(r)),
                Err(e) => Err(e),
            })
        })
        .collect()
}

pub fn revs_py_list<U>(
    py: Python<'_>,
    revs: impl IntoIterator<Item = Revision, IntoIter = U>,
) -> PyResult<Py<PyList>>
where
    U: ExactSizeIterator<Item = Revision>,
{
    Ok(PyList::new(py, revs.into_iter().map(PyRevision::from))?.unbind())
}

pub fn revs_py_set<U>(
    py: Python<'_>,
    revs: impl IntoIterator<Item = Revision, IntoIter = U>,
) -> PyResult<Py<PySet>>
where
    U: ExactSizeIterator<Item = Revision>,
{
    Ok(PySet::new(py, revs.into_iter().map(PyRevision::from))?.unbind())
}
