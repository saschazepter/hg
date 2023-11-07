// conversion.rs
//
// Copyright 2019 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the hg::ancestors module provided by the
//! `hg-core` crate. From Python, this will be seen as `rustext.ancestor`

use cpython::{ObjectProtocol, PyErr, PyObject, PyResult, Python};
use hg::{Revision, RevlogIndex, UncheckedRevision};

use crate::{exceptions::GraphError, PyRevision};

/// Utility function to convert a Python iterable into various collections
///
/// We need this in particular to feed to various methods of inner objects
/// with `impl IntoIterator<Item=Revision>` arguments, because
/// a `PyErr` can arise at each step of iteration, whereas these methods
/// expect iterables over `Revision`, not over some `Result<Revision, PyErr>`
pub fn rev_pyiter_collect<C, I>(
    py: Python,
    revs: &PyObject,
    index: &I,
) -> PyResult<C>
where
    C: FromIterator<Revision>,
    I: RevlogIndex,
{
    revs.iter(py)?
        .map(|r| {
            r.and_then(|o| match o.extract::<PyRevision>(py) {
                Ok(r) => index
                    .check_revision(UncheckedRevision(r.0))
                    .ok_or_else(|| {
                        PyErr::new::<GraphError, _>(
                            py,
                            ("InvalidRevision", r.0),
                        )
                    }),
                Err(e) => Err(e),
            })
        })
        .collect()
}
