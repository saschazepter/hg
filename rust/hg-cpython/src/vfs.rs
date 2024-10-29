use std::{
    cell::Cell,
    fs::File,
    io::Error,
    os::fd::{AsRawFd, FromRawFd},
    path::{Path, PathBuf},
};

use cpython::{
    ObjectProtocol, PyBytes, PyClone, PyDict, PyErr, PyInt, PyObject,
    PyResult, PyTuple, Python, PythonObject, ToPyObject,
};
use hg::{
    errors::{HgError, IoResultExt},
    exit_codes,
    utils::files::{get_bytes_from_path, get_path_from_bytes},
    vfs::{Vfs, VfsFile},
};

/// Wrapper around a Python VFS object to call back into Python from `hg-core`.
pub struct PyVfs {
    inner: PyObject,
    base: PathBuf,
}

impl Clone for PyVfs {
    fn clone(&self) -> Self {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        Self {
            inner: self.inner.clone_ref(py),
            base: self.base.clone(),
        }
    }
}

impl PyVfs {
    pub fn new(
        _py: Python,
        py_vfs: PyObject,
        base: PathBuf,
    ) -> PyResult<Self> {
        Ok(Self {
            inner: py_vfs,
            base,
        })
    }

    fn inner_open(
        &self,
        filename: &Path,
        create: bool,
        check_ambig: bool,
        atomic_temp: bool,
        write: bool,
    ) -> Result<(File, Option<PathBuf>), HgError> {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        let mode = if atomic_temp {
            PyBytes::new(py, b"w")
        } else if create {
            PyBytes::new(py, b"w+")
        } else if write {
            PyBytes::new(py, b"r+")
        } else {
            PyBytes::new(py, b"rb")
        };
        let res = self.inner.call(
            py,
            (
                PyBytes::new(py, &get_bytes_from_path(filename)),
                mode,
                atomic_temp,
                check_ambig,
            ),
            None,
        );
        match res {
            Ok(tup) => {
                let tup = tup
                    .extract::<PyTuple>(py)
                    .map_err(|e| vfs_error("vfs did not return a tuple", e))?;
                let fileno = tup.get_item(py, 0).extract(py).map_err(|e| {
                    vfs_error("vfs did not return a valid fileno", e)
                })?;
                let temp_name = tup.get_item(py, 1);
                // Safety: this must be a valid owned file descriptor, and
                // Python has just given it to us, it will only exist here now
                let file = unsafe { File::from_raw_fd(fileno) };
                let temp_name = if atomic_temp {
                    Some(
                        get_path_from_bytes(
                            temp_name
                                .extract::<PyBytes>(py)
                                .map_err(|e| vfs_error("invalid tempname", e))?
                                .data(py),
                        )
                        .to_owned(),
                    )
                } else {
                    None
                };
                Ok((file, temp_name))
            }
            Err(mut e) => {
                // TODO surely there is a better way of comparing
                if e.instance(py).get_type(py).name(py) == "FileNotFoundError"
                {
                    return Err(HgError::IoError {
                        error: Error::new(
                            std::io::ErrorKind::NotFound,
                            e.instance(py).to_string(),
                        ),
                        context: hg::errors::IoErrorContext::ReadingFile(
                            filename.to_owned(),
                        ),
                    });
                }
                Err(vfs_error("failed to call opener", e))
            }
        }
    }
}

fn vfs_error(reason: impl Into<String>, mut error: PyErr) -> HgError {
    let gil = &Python::acquire_gil();
    let py = gil.python();
    HgError::abort(
        format!("{}: {}", reason.into(), error.instance(py)),
        exit_codes::ABORT,
        None,
    )
}

py_class!(pub class PyFile |py| {
    data number: Cell<i32>;

    def fileno(&self) -> PyResult<PyInt> {
        Ok(self.number(py).get().to_py_object(py))
    }
});

impl Vfs for PyVfs {
    fn open(&self, filename: &Path) -> Result<VfsFile, HgError> {
        self.inner_open(filename, false, false, false, false)
            .map(|(f, _)| VfsFile::normal(f, filename.to_owned()))
    }

    fn open_write(&self, filename: &Path) -> Result<VfsFile, HgError> {
        self.inner_open(filename, false, false, false, true)
            .map(|(f, _)| VfsFile::normal(f, filename.to_owned()))
    }

    fn open_check_ambig(&self, filename: &Path) -> Result<VfsFile, HgError> {
        self.inner_open(filename, false, true, false, true)
            .map(|(f, _)| VfsFile::normal(f, filename.to_owned()))
    }

    fn create(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        self.inner_open(filename, true, check_ambig, false, true)
            .map(|(f, _)| VfsFile::normal(f, filename.to_owned()))
    }

    fn create_atomic(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        self.inner_open(filename, true, false, true, true).map(
            |(fp, temp_name)| {
                VfsFile::Atomic(hg::vfs::AtomicFile::from_file(
                    fp,
                    check_ambig,
                    temp_name.expect("temp name should exist"),
                    filename.to_owned(),
                ))
            },
        )
    }

    fn file_size(&self, file: &VfsFile) -> Result<u64, HgError> {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        let raw_fd = file.as_raw_fd();
        let py_fd = PyFile::create_instance(py, Cell::new(raw_fd))
            .expect("create_instance cannot fail");
        let fstat = self
            .inner
            .call_method(py, "fstat", (py_fd,), None)
            .map_err(|e| {
                vfs_error(format!("failed to fstat fd '{}'", raw_fd), e)
            })?;
        fstat
            .getattr(py, "st_size")
            .map(|v| {
                v.extract(py).map_err(|e| {
                    vfs_error(format!("invalid size for fd '{}'", raw_fd), e)
                })
            })
            .map_err(|e| {
                vfs_error(format!("failed to get size of fd '{}'", raw_fd), e)
            })?
    }

    fn exists(&self, filename: &Path) -> bool {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        self.inner
            .call_method(
                py,
                "exists",
                (PyBytes::new(py, &get_bytes_from_path(filename)),),
                None,
            )
            .unwrap_or_else(|_| false.into_py_object(py).into_object())
            .extract(py)
            .unwrap()
    }

    fn unlink(&self, filename: &Path) -> Result<(), HgError> {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        if let Err(e) = self.inner.call_method(
            py,
            "unlink",
            (PyBytes::new(py, &get_bytes_from_path(filename)),),
            None,
        ) {
            return Err(vfs_error(
                format!("failed to unlink '{}'", filename.display()),
                e,
            ));
        }
        Ok(())
    }

    fn rename(
        &self,
        from: &Path,
        to: &Path,
        check_ambig: bool,
    ) -> Result<(), HgError> {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        let kwargs = PyDict::new(py);
        kwargs
            .set_item(py, "checkambig", check_ambig)
            .map_err(|e| vfs_error("dict setitem failed", e))?;
        if let Err(e) = self.inner.call_method(
            py,
            "rename",
            (
                PyBytes::new(py, &get_bytes_from_path(from)),
                PyBytes::new(py, &get_bytes_from_path(to)),
            ),
            Some(&kwargs),
        ) {
            let msg = format!(
                "failed to rename '{}' to '{}'",
                from.display(),
                to.display()
            );
            return Err(vfs_error(msg, e));
        }
        Ok(())
    }

    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError> {
        let gil = &Python::acquire_gil();
        let py = gil.python();
        let from = self
            .inner
            .call_method(
                py,
                "join",
                (PyBytes::new(py, &get_bytes_from_path(from)),),
                None,
            )
            .unwrap();
        let from = from.extract::<PyBytes>(py).unwrap();
        let from = get_path_from_bytes(from.data(py));
        let to = self
            .inner
            .call_method(
                py,
                "join",
                (PyBytes::new(py, &get_bytes_from_path(to)),),
                None,
            )
            .unwrap();
        let to = to.extract::<PyBytes>(py).unwrap();
        let to = get_path_from_bytes(to.data(py));
        std::fs::copy(from, to).when_writing_file(to)?;
        Ok(())
    }

    fn base(&self) -> &Path {
        &self.base
    }
}
