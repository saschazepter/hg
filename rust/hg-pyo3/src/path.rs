// path.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//           2025 Georges Racinet <georges.racinet@cloudcrane.io>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Utilities about `HgPath` and related objects provided by the `hg-core`
//! package.

use pyo3::prelude::*;
use pyo3::types::{PyBytes, PyList};

use std::convert::Infallible;

use hg::utils::hg_path::{HgPath, HgPathBuf};

#[derive(Eq, Ord, PartialEq, PartialOrd, Hash, derive_more::From)]
pub struct PyHgPathRef<'a>(pub &'a HgPath);

impl<'py> IntoPyObject<'py> for PyHgPathRef<'_> {
    type Target = PyBytes;
    type Output = Bound<'py, Self::Target>;
    type Error = Infallible;

    fn into_pyobject(
        self,
        py: Python<'py>,
    ) -> Result<Self::Output, Self::Error> {
        Ok(PyBytes::new(py, self.0.as_bytes()))
    }
}

#[allow(dead_code)]
pub fn paths_py_list<I, U>(
    py: Python<'_>,
    paths: impl IntoIterator<Item = I, IntoIter = U>,
) -> PyResult<Py<PyList>>
where
    I: AsRef<HgPath>,
    U: ExactSizeIterator<Item = I>,
{
    Ok(PyList::new(
        py,
        paths
            .into_iter()
            .map(|p| PyBytes::new(py, p.as_ref().as_bytes())),
    )?
    .unbind())
}

#[allow(dead_code)]
pub fn paths_pyiter_collect<C>(paths: &Bound<'_, PyAny>) -> PyResult<C>
where
    C: FromIterator<HgPathBuf>,
{
    paths
        .try_iter()?
        .map(|p| {
            let path = p?;
            Ok(HgPathBuf::from_bytes(
                path.downcast::<PyBytes>()?.as_bytes(),
            ))
        })
        .collect()
}
