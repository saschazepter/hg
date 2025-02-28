// copy_tracing.rs
//
// Copyright 2025 Mercurial developers
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for the `hg::copy_tracing` module provided by the
//! `hg-core` package.
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.copy_tracing`

use hg::copy_tracing::ChangedFiles;
use hg::copy_tracing::CombineChangesetCopies;
use hg::Revision;
use pyo3::types::PyBytes;
use pyo3::types::PyDict;
use pyo3::types::PyList;
use pyo3::types::PyTuple;

use crate::revision::PyRevision;
use crate::utils::new_submodule;
use crate::utils::PyBytesDeref;

use pyo3::prelude::*;

/// Combines copies information contained into revision `revs` to build a copy
/// map.
///
/// See mercurial/copies.py for details
#[pyfunction]
#[pyo3(name = "combine_changeset_copies")]
pub fn combine_changeset_copies_wrapper(
    revs: Bound<'_, PyList>,
    children_count: Bound<'_, PyDict>,
    target_rev: PyRevision,
    rev_info: Bound<'_, PyAny>,
    multi_thread: bool,
) -> PyResult<PyObject> {
    let py = revs.py();
    let target_rev = Revision(target_rev.0);
    let children_count = children_count
        .iter()
        .map(|(k, v)| {
            Ok((Revision(k.extract::<PyRevision>()?.0), v.extract()?))
        })
        .collect::<PyResult<_>>()?;

    /// (Revision number, parent 1, parent 2, copy data for this revision)
    type RevInfo<Bytes> = (Revision, Revision, Revision, Option<Bytes>);

    let revs_info =
        revs.iter().map(|rev_py| -> PyResult<RevInfo<Py<PyBytes>>> {
            let rev = Revision(rev_py.extract::<PyRevision>()?.0);
            let ret = rev_info.call1((rev_py,))?;
            let tuple: &Bound<'_, PyTuple> = ret.downcast()?;
            let p1 = Revision(tuple.get_item(0)?.extract::<PyRevision>()?.0);
            let p2 = Revision(tuple.get_item(1)?.extract::<PyRevision>()?.0);
            let opt_bytes = tuple.get_item(2)?.extract()?;
            Ok((rev, p1, p2, opt_bytes))
        });

    let path_copies;
    if !multi_thread {
        let mut combine_changeset_copies =
            CombineChangesetCopies::new(children_count);

        for rev_info in revs_info {
            let (rev, p1, p2, opt_bytes) = rev_info?;
            let files = match &opt_bytes {
                Some(bytes) => ChangedFiles::new(bytes.as_bytes(py)),
                // Python None was extracted to Option::None,
                // meaning there was no copy data.
                None => ChangedFiles::new_empty(),
            };

            combine_changeset_copies.add_revision(rev, p1, p2, files)
        }
        path_copies = combine_changeset_copies.finish(target_rev)
    } else {
        // Use a bounded channel to provide back-pressure:
        // if the child thread is slower to process revisions than this thread
        // is to gather data for them, an unbounded channel would keep
        // growing and eat memory.
        //
        // TODO: tweak the bound?
        let (rev_info_sender, rev_info_receiver) =
            crossbeam_channel::bounded::<RevInfo<PyBytesDeref>>(1000);

        // This channel (going the other way around) however is unbounded.
        // If they were both bounded, there might potentially be deadlocks
        // where both channels are full and both threads are waiting on each
        // other.
        let (pybytes_sender, pybytes_receiver) =
            crossbeam_channel::unbounded();

        // Start a thread that does CPU-heavy processing in parallel with the
        // loop below.
        //
        // If the parent thread panics, `rev_info_sender` will be dropped and
        // “disconnected”. `rev_info_receiver` will be notified of this and
        // exit its own loop.
        let thread = std::thread::spawn(move || {
            let mut combine_changeset_copies =
                CombineChangesetCopies::new(children_count);
            for (rev, p1, p2, opt_bytes) in rev_info_receiver {
                let files = match &opt_bytes {
                    Some(raw) => ChangedFiles::new(raw.as_ref()),
                    // Python None was extracted to Option::None,
                    // meaning there was no copy data.
                    None => ChangedFiles::new_empty(),
                };
                combine_changeset_copies.add_revision(rev, p1, p2, files);

                // Send `PyBytes` back to the parent thread so the parent
                // thread can drop it. Otherwise the GIL would be implicitly
                // acquired here through `impl Drop for PyBytes`.
                if let Some(bytes) = opt_bytes {
                    if pybytes_sender.send(bytes.unwrap()).is_err() {
                        // The channel is disconnected, meaning the parent
                        // thread panicked or returned
                        // early through
                        // `?` to propagate a Python exception.
                        break;
                    }
                }
            }

            combine_changeset_copies.finish(target_rev)
        });

        for rev_info in revs_info {
            let (rev, p1, p2, opt_bytes) = rev_info?;
            let opt_bytes = opt_bytes.map(|b| PyBytesDeref::new(py, b));

            // We’d prefer to avoid the child thread calling into Python code,
            // but this avoids a potential deadlock on the GIL if it does:
            py.allow_threads(|| {
                rev_info_sender.send((rev, p1, p2, opt_bytes)).expect(
                    "combine_changeset_copies: channel is disconnected",
                );
            });

            // Drop anything in the channel, without blocking
            pybytes_receiver.try_iter().for_each(drop);
        }
        // We’d prefer to avoid the child thread calling into Python code,
        // but this avoids a potential deadlock on the GIL if it does:
        path_copies = py.allow_threads(|| {
            // Disconnect the channel to signal the child thread to stop:
            // the `for … in rev_info_receiver` loop will end.
            drop(rev_info_sender);

            // Wait for the child thread to stop, and propagate any panic.
            thread.join().unwrap_or_else(|panic_payload| {
                std::panic::resume_unwind(panic_payload)
            })
        });

        // Drop anything left in the channel
        drop(pybytes_receiver)
    };

    let out = PyDict::new(py);
    for (dest, source) in path_copies.into_iter() {
        out.set_item(
            PyBytes::new(py, &dest.into_vec()),
            PyBytes::new(py, &source.into_vec()),
        )?;
    }
    Ok(out.into_any().unbind())
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "copy_tracing")?;
    m.add_function(wrap_pyfunction!(combine_changeset_copies_wrapper, &m)?)?;
    Ok(m)
}
