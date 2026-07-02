//! Rust code for hgext3rd/phantom_commits.py
//!
//! From Python, this will be seen as `mercurial.pyo3_rustext.phantom_commits`

use std::sync::Mutex;
use std::sync::MutexGuard;

use elsa::FrozenVec;
use hg::FastHashMap;
use hg::revlog::diff::text_delta;
use hg::revlog::patch::Delta;
use hg::revlog::patch::DeltaPiece;
use hg::revlog::patch::RichDeltaPiece;
use hg::revlog::patch::SrcToken;
use hg::utils::files::is_binary;
use hg::utils::u32_u;
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyBytes;

use crate::utils::HgPyErrExt;
use crate::utils::new_submodule;
use crate::utils::with_pybytes_buffer;

/// Python wrapper class for [`Squasher`].
#[pyclass(name = "Squasher", frozen)]
struct PySquasher {
    inner: Mutex<OwnedSquasher>,
}

impl PySquasher {
    fn get(&self) -> MutexGuard<'_, OwnedSquasher> {
        self.inner.lock().expect("propagate mutex panic")
    }
}

#[pymethods]
impl PySquasher {
    #[new]
    fn new() -> PyResult<Self> {
        Ok(PySquasher { inner: Mutex::new(OwnedSquasher::empty()) })
    }

    /// See [`Squasher::should_record`].
    fn should_record(&self, path: &[u8]) -> bool {
        self.get().should_record(path)
    }

    /// See [`Squasher::record_prev`].
    fn record_prev(
        &self,
        py: Python<'_>,
        path: &[u8],
        text: Option<Py<PyBytes>>,
        user_kind: &Bound<'_, PyAny>,
    ) -> PyResult<()> {
        let user_kind = user_kind.getattr("value")?;
        let user_kind = UserKind::parse(user_kind.extract::<&[u8]>()?)
            .ok_or_else(|| PyValueError::new_err("invalid UserKind"))?;
        self.get().record_prev(py, path, text, None, user_kind.src_token());
        Ok(())
    }

    /// See [`Squasher::record_prev`].
    /// This should be called last, to record the base revision.
    fn record_base(
        &self,
        py: Python<'_>,
        path: &[u8],
        text: Option<Py<PyBytes>>,
        copy_source_text: Option<Py<PyBytes>>,
    ) -> PyResult<()> {
        self.get().record_prev(py, path, text, copy_source_text, BASE);
        Ok(())
    }

    /// See [`Squasher::get_ai_content`].
    fn get_ai_content(
        &self,
        py: Python<'_>,
        path: &[u8],
    ) -> PyResult<Option<Py<PyBytes>>> {
        self.get().get_ai_content(py, path)
    }

    /// See [`Squasher::did_ai_remove`].
    fn did_ai_remove(&self, path: &[u8]) -> bool {
        self.get().did_ai_remove(path)
    }
}

/// A rich delta source token indicating the base content.
const BASE: SrcToken = 0;

/// A rich delta source token for attributing changes to humans.
const HUMAN: SrcToken = 1;

/// A rich delta source token for attributing changes to AI.
const AI: SrcToken = 2;

/// Enum corresponding to `UserKind` in hgext3rd/phantom_commits.py.
#[derive(Debug, Copy, Clone)]
enum UserKind {
    Human,
    Ai,
}

impl UserKind {
    fn parse(value: &[u8]) -> Option<Self> {
        match value {
            b"human" => Some(Self::Human),
            b"ai" => Some(Self::Ai),
            _ => None,
        }
    }

    fn src_token(&self) -> SrcToken {
        match self {
            Self::Human => HUMAN,
            Self::Ai => AI,
        }
    }
}

self_cell::self_cell! {
    /// A wrapper around [`Squasher`] that owns the text of delta pieces. The
    /// [`RichDeltaPiece`]s in [`Squasher`] point into `owner`.
    struct OwnedSquasher {
        owner: FrozenVec<Vec<u8>>,
        #[covariant]
        dependent: Squasher,
    }
}

impl OwnedSquasher {
    fn empty() -> Self {
        Self::new(FrozenVec::new(), |_| Squasher::new())
    }

    fn should_record(&self, path: &[u8]) -> bool {
        self.borrow_dependent().should_record(path)
    }

    fn record_prev(
        &mut self,
        py: Python<'_>,
        path: &[u8],
        text: Option<Py<PyBytes>>,
        copy_source_text: Option<Py<PyBytes>>,
        src: SrcToken,
    ) {
        self.with_dependent_mut(|delta_storage, squasher| {
            squasher.record_prev(
                py,
                delta_storage,
                path,
                text,
                copy_source_text,
                src,
            );
        })
    }

    fn get_ai_content(
        &self,
        py: Python<'_>,
        path: &[u8],
    ) -> PyResult<Option<Py<PyBytes>>> {
        self.borrow_dependent().get_ai_content(py, path)
    }

    fn did_ai_remove(&self, path: &[u8]) -> bool {
        self.borrow_dependent().did_ai_remove(path)
    }
}

/// [`Squasher`] takes a series of changesets and produces an intermediate
/// squashed commit containing only the changes by one of the users (AI).
///
/// It processes changesets in reverse order, from *final* to *base*.
///
/// For example, consider these changesets:
///
///     base +--> human(1)
///          |
///          +--> AI(2)
///          |
///          +--> human(3)
///          |
///          +--> AI(4)  [final]
///
/// You would call [`Self::record_prev`] on all files in this order: AI(4),
/// human(3), AI(2), human(1), base. Then you can use [`Self::get_ai_content`]
/// and [`Self::did_ai_remove`] to produce the squashed AI commit:
///
///     base -> AI(squashed content) -> human [same content as AI(4)]
///
/// And now if you run annotate, it will correctly attribute lines to human or
/// AI based on who authored the line in the original sequence.
///
/// Internally, it works by combining diffs, filtering out the human parts, and
/// applying it to the base. It does *not* involve merge algorithms. This means
/// there is no possibility of conflicts. However, the squashed AI commit might
/// look strange since it is just some subset of the final lines. For example,
/// it could contain syntax errors even if none of the original changesets did.
struct Squasher<'a> {
    files: FastHashMap<Vec<u8>, FileState<'a>>,
}

/// State of a file during the squashing algorithm, storing its current snapshot
/// and a diff to the final snapshot.
///
/// We start at the final snapshot with [`Diff::Clean`], and then step backwards
/// towards the base snapshot until [`Squasher::should_record`] returns false.
/// At that point we have sufficient information to construct the correct
/// intermediate AI snapshot.
///
/// Representing the snapshot and diff independently means there are some
/// illegal states, but it makes the squashing logic simpler.
struct FileState<'a> {
    /// Author of [`Self::snapshot`].
    src: SrcToken,
    /// Snapshot of the file.
    snapshot: Snapshot,
    /// Diff to the final snapshot.
    diff: Diff<'a>,
}

/// Snapshot of a file that may or may not exist.
enum Snapshot {
    /// File does not exist.
    Absent,
    /// File exists, and is text.
    Text(Py<PyBytes>),
    /// File exists, and is binary according to [`is_binary`].
    Binary(Py<PyBytes>),
}

/// Diff between two [`Snapshot`]s.
///
/// The purpose of the diff is to filter it by [`SrcToken`] and apply it to the
/// base [`FileState::snapshot`] to produce an intermediate AI snapshot. It does
/// not necessarily correspond to the actual diff the user is committing,
/// because we do not always step all the way back to the base snapshot.
///
/// For example, suppose the user removes a file and later writes it again. The
/// `hg status` would be clean or modified, but the [`Diff`] would be `Added`
/// because the file went from absent to present, and we stopped there.
enum Diff<'a> {
    /// A temporary invalid state while computing a new diff.
    Invalid,
    // No change.
    Clean,
    /// File was modified.
    /// The delta is from [`Snapshot::delta_base`] to the final snapshot.
    /// The state's snapshot must NOT be [`Snapshot::Absent`].
    Modified(Delta<'a, RichDeltaPiece<'a>>),
    /// File was added by this [`SrcToken`].
    /// The delta is from [`Snapshot::delta_base`] to the final snapshot.
    /// The state's snapshot is usually [`Snapshot::Absent`], but it is present
    /// if the added file has a copy source in the base.
    Added(SrcToken, Delta<'a, RichDeltaPiece<'a>>),
    /// File was removed by this [`SrcToken`].
    /// The state's snapshot must NOT be [`Snapshot::Absent`].
    Removed(SrcToken),
    /// File was replaced by this [`SrcToken`] with the given bytes.
    Binary(SrcToken, Py<PyBytes>),
}

impl Snapshot {
    /// Returns a new [`Snapshot`]. Checks if the text is binary.
    fn new(py: Python<'_>, text: Option<Py<PyBytes>>) -> Self {
        match text {
            None => Self::Absent,
            Some(text) if is_binary(text.as_bytes(py)) => Self::Binary(text),
            Some(text) => Self::Text(text),
        }
    }

    /// Returns the text that deltas from this snapshot should be based on.
    fn delta_base(&self, py: Python<'_>) -> &[u8] {
        match self {
            Self::Absent => b"",
            Self::Text(text) => text.as_bytes(py),
            // If we're doing a binary->text delta (it can't be binary->binary
            // because that would use `Diff::Binary`, which has no delta),
            // pretend the file is empty so that all initial text lines are
            // attributed to the user who changed the file to text. We'll stop
            // after this because `Squasher::should_record` will return false.
            Self::Binary(_) => b"",
        }
    }

    /// Returns true if this snapshot is equal to `other`.
    fn is_equal(&self, py: Python<'_>, other: &Snapshot) -> bool {
        match (self, other) {
            (Self::Absent, Self::Absent) => true,
            (Self::Text(t1), Self::Text(t2)) => {
                t1.as_bytes(py) == t2.as_bytes(py)
            }
            (Self::Binary(t1), Self::Binary(t2)) => {
                t1.as_bytes(py) == t2.as_bytes(py)
            }
            _ => false,
        }
    }
}

impl<'a> Squasher<'a> {
    /// Create a new empty commit squasher.
    fn new() -> Self {
        Self { files: FastHashMap::default() }
    }

    /// Returns true if the given path needs to be recorded.
    fn should_record(&self, path: &[u8]) -> bool {
        let Some(state) = self.files.get(path) else {
            // If this is our first time seeing it, we need to record it.
            return true;
        };
        match &state.diff {
            Diff::Invalid => panic!("invalid diff"),
            Diff::Clean => true,
            Diff::Modified(..) => match &state.snapshot {
                Snapshot::Absent => panic!("should be Diff::Added"),
                Snapshot::Text(_) => true,
                // We don't care what happened before a binary->text transition.
                Snapshot::Binary(_) => false,
            },
            // We don't care what happened before a file was added or removed.
            Diff::Added(..) => false,
            Diff::Removed(..) => false,
            // We don't care what happened before a binary change.
            Diff::Binary(..) => false,
        }
    }

    /// Records the previous snapshot of the file at `path` with the given text
    /// (or `None` if the file doesn't exist) attributed to `src`. When
    /// recording [`BASE`], if the file has a copy source in the dirstate, you
    /// must also provide that file content as `copy_source_text`.
    ///
    /// This must only be called if [`Self::should_record`] returns true.
    /// Otherwise, it will panic.
    ///
    /// While [`Self::should_record`] returns true, you should:
    ///
    /// 1. Call `record_prev` for all files in the last snapshot
    /// 2. ...
    /// 3. Call `record_prev` for all files in the first snapshot
    /// 4. Call `record_prev` for all files at base with src [`BASE`]
    ///
    /// We process changes in reverse like this because it allows us to skip
    /// work when a later change makes earlier ones irrelevant. For example, if
    /// a file gets removed, it doesn't matter what happened to it before.
    fn record_prev(
        &mut self,
        py: Python<'_>,
        delta_storage: &'a FrozenVec<Vec<u8>>,
        path: &[u8],
        text: Option<Py<PyBytes>>,
        copy_source_text: Option<Py<PyBytes>>,
        src: SrcToken,
    ) {
        if copy_source_text.is_some() {
            assert_eq!(src, BASE, "copy source is only supported for base");
        }
        // For the purposes of choosing `Diff::Added` or `Diff::Modified`, we
        // care about the original `text` for this `path`.
        let treat_as_absent = text.is_none();
        // But apart from that, if there's a copy source, use that instead. This
        // is important to avoid breaking annotate. If we used the original
        // `text`, then renaming a file would lead to the AI commit deleting all
        // the lines and the human commit restoring them.
        let text = copy_source_text.or(text);
        use std::collections::hash_map::Entry;
        match self.files.entry(path.to_owned()) {
            Entry::Vacant(entry) => {
                entry.insert(FileState {
                    src,
                    snapshot: Snapshot::new(py, text),
                    diff: Diff::Clean,
                });
            }
            Entry::Occupied(mut entry) => {
                let next_state = entry.get_mut();
                let next_src = next_state.src;
                let next_snapshot = &next_state.snapshot;
                let next_diff = std::mem::replace(
                    &mut next_state.diff,
                    // This is temporary. We overwrite the entire entry below.
                    Diff::Invalid,
                );
                let snapshot = Snapshot::new(py, text);
                let diff = match next_snapshot {
                    Snapshot::Absent => {
                        // If next_snapshot is Absent, we must still be looking
                        // for who removed the file, so next_diff must be Clean.
                        // Once we find who removed it, we set the diff to
                        // Removed, and then should_record returns false.
                        assert!(matches!(next_diff, Diff::Clean));
                        match snapshot {
                            Snapshot::Absent => Diff::Clean,
                            Snapshot::Text(_) | Snapshot::Binary(_) => {
                                Diff::Removed(next_src)
                            }
                        }
                    }
                    Snapshot::Binary(next_text) => {
                        // If next_snapshot is Binary, we must still be looking
                        // for who changed it, so next_diff must be Clean. Once
                        // we find who changed it, we set the diff to Binary,
                        // and then should_record returns false.
                        assert!(matches!(next_diff, Diff::Clean));
                        if snapshot.is_equal(py, next_snapshot) {
                            Diff::Clean
                        } else {
                            Diff::Binary(next_src, next_text.clone_ref(py))
                        }
                    }
                    Snapshot::Text(next_text) => {
                        let current_to_next = {
                            let raw = text_delta(
                                snapshot.delta_base(py),
                                next_text.as_bytes(py),
                            );
                            let raw = delta_storage.push_get(raw);
                            Delta::new_rich(next_src, raw)
                                .expect("text_delta should create valid patch")
                        };
                        let current_to_final = match next_diff {
                            Diff::Invalid => panic!("invalid diff"),
                            Diff::Clean => current_to_next,
                            Diff::Modified(next_to_final) => {
                                current_to_next.combine(next_to_final)
                            }
                            Diff::Added(..)
                            | Diff::Removed(..)
                            | Diff::Binary(..) => {
                                panic!("should_record would return false")
                            }
                        };
                        match snapshot {
                            _ if treat_as_absent => {
                                Diff::Added(next_src, current_to_final)
                            }
                            Snapshot::Absent => {
                                Diff::Added(next_src, current_to_final)
                            }
                            Snapshot::Text(_) | Snapshot::Binary(_) => {
                                Diff::Modified(current_to_final)
                            }
                        }
                    }
                };
                entry.insert(FileState { src, snapshot, diff });
            }
        }
    }

    /// Returns the content to use for `path` in the squashed AI commit, or
    /// `None` if it should not be included in the commit.
    fn get_ai_content(
        &self,
        py: Python<'_>,
        path: &[u8],
    ) -> PyResult<Option<Py<PyBytes>>> {
        let Some(state) = self.files.get(path) else {
            // File was never recorded.
            return Ok(None);
        };
        let delta = match &state.diff {
            Diff::Invalid => panic!("invalid delta"),
            Diff::Clean => return Ok(None),
            Diff::Modified(delta) => delta,
            Diff::Added(_, delta) => delta,
            Diff::Removed(_) => return Ok(None),
            Diff::Binary(src, text) => match *src {
                AI => return Ok(Some(text.clone_ref(py))),
                HUMAN => return Ok(None),
                _ => unreachable!("SrcToken must be AI or HUMAN"),
            },
        };
        let base = state.snapshot.delta_base(py);
        let mut target_size = base.len() as i32;
        let mut ai_chunks = Vec::with_capacity(delta.chunks.len());
        for chunk in delta.chunks.iter() {
            match chunk.src {
                AI => {
                    target_size += chunk.len_diff();
                    ai_chunks.push(&chunk.inner);
                }
                HUMAN => {}
                _ => unreachable!("SrcToken must be AI or HUMAN"),
            }
        }
        assert!(target_size >= 0, "negative target size: {target_size}");
        let target_size = target_size as usize;
        // If AI did not add the file and is not responsible for any of the net
        // changes, then exclude the file from the AI commit.
        match state.diff {
            Diff::Added(AI, _) => {}
            Diff::Added(..) | Diff::Modified(..) => {
                if ai_chunks.is_empty() {
                    return Ok(None);
                }
            }
            _ => unreachable!("should have returned earlier"),
        }
        let content = with_pybytes_buffer(py, target_size, |buffer| {
            let mut last: usize = 0;
            for p in ai_chunks {
                let o_start = u32_u(p.start());
                let slice = &base[last..o_start];
                buffer.extend_from_slice(slice);
                buffer.extend_from_slice(p.data());
                last = u32_u(p.end());
            }
            buffer.extend_from_slice(&base[last..]);
            Ok(())
        })
        .into_pyerr(py)?;
        Ok(Some(content))
    }

    /// Returns true if `path` should be removed in the squashed AI commit.
    fn did_ai_remove(&self, path: &[u8]) -> bool {
        matches!(
            self.files.get(path),
            Some(FileState { diff: Diff::Removed(AI), .. })
        )
    }
}

pub fn init_module<'py>(
    py: Python<'py>,
    package: &str,
) -> PyResult<Bound<'py, PyModule>> {
    let m = new_submodule(py, package, "phantom_commits")?;
    m.add("__doc__", "Phantom commits - Rust implementation exposed via PyO3")?;
    m.add_class::<PySquasher>()?;
    Ok(m)
}
