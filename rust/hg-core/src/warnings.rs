//! All of hg-core's warnings, to be exposed to its consumers so they can
//! handle the actual formatting.

use crossbeam_channel::Receiver;
use crossbeam_channel::Sender;

use crate::file_patterns::PatternFileWarning;
use crate::sparse::SparseNarrowWarning;
use crate::update::UpdateWarning;

/// A warning in any Mercurial logic
#[derive(Debug, derive_more::From)]
pub enum HgWarning {
    SparseNarrow(SparseNarrowWarning),
    PatternFile(PatternFileWarning),
    Update(UpdateWarning),
}

/// A simple convenience wrapper around a [`Sender<HgWarning>`].
pub struct HgWarningSender {
    inner: Sender<HgWarning>,
}

impl HgWarningSender {
    /// Send a warning through the channel.
    ///
    /// # Panics
    ///
    /// Panics if the channel has been closed.
    pub fn send<T: Into<HgWarning>>(&self, warning: T) {
        self.inner.send(warning.into()).expect("warning channel must stay open")
    }
}

// This way we keep track of the sender at compile-time and don't risk causing
// a deadlock because a sender has been cloned, unless someone does something
// quite careless and explicit with `mem::forget` or something.
static_assertions_next::assert_impl!(HgWarningSender: !Clone);

/// Manages the context for the passing of [`HgWarning`] to high-level logic.
/// It is the only way of getting an `HgWarningSender`, which lower-level code
/// expects as the blessed way of bubbling up warnings while being a nicely
/// behaved library.
pub struct HgWarningContext {
    sender: HgWarningSender,
    receiver: Receiver<HgWarning>,
}

impl HgWarningContext {
    /// Returns a brand new context with a new channel.
    pub fn new() -> Self {
        let (sender, receiver) = crossbeam_channel::unbounded();
        Self { sender: HgWarningSender { inner: sender }, receiver }
    }

    /// Returns a reference to the sender for this context.
    pub fn sender(&self) -> &HgWarningSender {
        &self.sender
    }

    // TODO progressive/polled display of warnings

    /// Ends the warning context with a way of handling queued up messages.
    ///
    /// The sender is first dropped, then every message in the channel is passed
    /// to the `on_message` callback, and then the context is dropped.
    pub fn finish<E>(
        self,
        mut on_message: impl FnMut(HgWarning) -> Result<(), E>,
    ) -> Result<(), E> {
        drop(self.sender);
        for warning in self.receiver.iter() {
            on_message(warning)?;
        }
        Ok(())
    }
}

impl Default for HgWarningContext {
    fn default() -> Self {
        Self::new()
    }
}

/// /!\
/// This module shouldn't really exist in `hg-core`, since it's the consumer
/// crates' responsibility to handle any user-facing formatting. However,
/// both `rhg` and `hg-pyo3` share the exact same behavior w.r.t displaying
/// warnings, so we keep it in here.
/// Creating a separate crate for this seems heavy-handed, so make sure to not
/// use anything that wouldn't work (the orphan rule in particular).
/// /!\
pub mod format {
    use std::path::Path;

    use format_bytes::write_bytes;

    use super::*;
    use crate::utils::files::get_bytes_from_path;

    /// See this module's doc for why this function is in `hg-core`.
    #[inline(always)]
    pub fn write_warning(
        warning: &HgWarning,
        output: &mut dyn std::io::Write,
        working_directory: &Path,
    ) -> std::io::Result<()> {
        match warning {
            HgWarning::SparseNarrow(w) => {
                write_sparse_narrow_warning(w, output)
            }
            HgWarning::PatternFile(w) => {
                write_pattern_file_warning(w, output, working_directory)
            }
            HgWarning::Update(w) => {
                write_update_warning(w, output, working_directory)
            }
        }
    }

    fn write_sparse_narrow_warning(
        warning: &SparseNarrowWarning,
        output: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        match warning {
            SparseNarrowWarning::RootWarning { context, line } => write_bytes!(
                output,
                b"warning: {} profile cannot use paths \
                starting with /, ignoring {}\n",
                context,
                line
            ),
            SparseNarrowWarning::ProfileNotFound { profile, node } => {
                write_bytes!(
                    output,
                    b"warning: sparse profile '{}' not found \
                    in rev {} - ignoring it\n",
                    profile,
                    node.map(|n| format!("{:x}", n.short()))
                        .unwrap_or_else(|| String::from("unknown"))
                        .as_bytes()
                )
            }
        }
    }

    fn write_pattern_file_warning(
        warning: &PatternFileWarning,
        output: &mut dyn std::io::Write,
        working_directory: &Path,
    ) -> std::io::Result<()> {
        match warning {
            PatternFileWarning::InvalidSyntax(path, syntax) => {
                write_bytes!(
                    output,
                    b"{}: ignoring invalid syntax '{}'\n",
                    get_bytes_from_path(path),
                    syntax
                )
            }
            PatternFileWarning::NoSuchFile(path) => {
                let path = if let Ok(relative) =
                    path.strip_prefix(working_directory)
                {
                    relative
                } else {
                    path
                };
                write_bytes!(
                    output,
                    b"skipping unreadable pattern file '{}': \
                        No such file or directory\n",
                    get_bytes_from_path(path),
                )
            }
        }
    }

    fn write_update_warning(
        warning: &UpdateWarning,
        output: &mut dyn std::io::Write,
        working_directory: &Path,
    ) -> std::io::Result<()> {
        match warning {
            UpdateWarning::UnlinkFailure(path, err) => {
                write_bytes!(
                    output,
                    b"update failed to remove {}: \"{}\"!\n",
                    get_bytes_from_path(path),
                    err.to_string().as_bytes(),
                )
            }
            UpdateWarning::CwdRemoved => {
                write_bytes!(
                    output,
                    b"current directory was removed\n\
                    (consider changing to repo root: {})\n",
                    get_bytes_from_path(working_directory),
                )
            }
            UpdateWarning::UntrackedConflict(path) => {
                write_bytes!(
                    output,
                    b"{}: untracked file differs\n",
                    path.as_bytes(),
                )
            }
            UpdateWarning::ReplacingUntracked(path) => {
                write_bytes!(
                    output,
                    b"{}: replacing untracked file\n",
                    path.as_bytes(),
                )
            }
        }
    }
}
