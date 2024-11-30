use pyo3::prelude::*;

use hg::revlog::RevlogIndex;
use hg::{BaseRevision, Revision, UncheckedRevision};

use crate::exceptions::GraphError;

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
