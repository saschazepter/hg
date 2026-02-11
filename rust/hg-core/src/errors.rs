use std::backtrace::Backtrace;
use std::backtrace::BacktraceStatus;
use std::fmt;
use std::fmt::Write;
use std::io::ErrorKind;
use std::path::Path;
use std::path::PathBuf;

use crate::Node;
use crate::config::ConfigValueParseError;
use crate::dirstate::DirstateError;
use crate::dirstate::status::StatusError;
use crate::exit_codes;
use crate::file_patterns::PatternError;
use crate::revlog::RevlogError;
use crate::utils::hg_path::HgPathError;

/// Common error cases that can happen in many different APIs
#[derive(Debug, derive_more::From)]
pub enum HgError {
    /// A low-level IO error
    #[from]
    IO(HgIoError),

    /// A file under `.hg/` normally only written by Mercurial is not in the
    /// expected format. This indicates a bug in Mercurial, filesystem
    /// corruption, or hardware failure.
    ///
    /// The given string is a short explanation for users, not intended to be
    /// machine-readable.
    CorruptedRepository(String, HgBacktrace),

    /// The respository or requested operation involves a feature not
    /// supported by the Rust implementation. Falling back to the Python
    /// implementation may or may not work.
    ///
    /// The given string is a short explanation for users, not intended to be
    /// machine-readable.
    UnsupportedFeature(String, HgBacktrace),

    /// Operation cannot proceed for some other reason.
    ///
    /// The message is a short explanation for users, not intended to be
    /// machine-readable.
    Abort {
        message: String,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<String>,
        backtrace: HgBacktrace,
    },

    /// A configuration value is not in the expected syntax.
    ///
    /// These errors can happen in many places in the code because values are
    /// parsed lazily as the file-level parser does not know the expected type
    /// and syntax of each value.
    #[from]
    ConfigValueParseError(ConfigValueParseError),

    /// Censored revision data.
    CensoredNodeError(Node, HgBacktrace),
    /// An error occured in the dirstate
    Dirstate(Box<DirstateError>),
    #[from]
    Pattern(PatternError),
    /// A race condition has been detected. This *must* be handled locally
    /// and not directly surface to the user.
    RaceDetected(String),
    /// An invalid path was found
    Path(HgPathError),
    /// An interrupt was received and we need to stop whatever we're doing
    InterruptReceived,
    /// No repository was found for an operation that required one
    RepoNotFound { at: PathBuf, backtrace: HgBacktrace },
}

impl From<StatusError> for HgError {
    fn from(value: StatusError) -> Self {
        match value {
            StatusError::Path(err) => HgError::Path(err),
            StatusError::Pattern(err) => HgError::Pattern(err),
            StatusError::DirstateV2ParseError(dirstate_v2_parse_error) => {
                Self::Dirstate(Box::new(dirstate_v2_parse_error.into()))
            }
        }
    }
}

impl From<DirstateError> for HgError {
    fn from(value: DirstateError) -> Self {
        match value {
            DirstateError::Map(_) => Self::Dirstate(Box::new(value)),
            DirstateError::Common(hg_error) => hg_error,
        }
    }
}

/// Details about where an I/O error happened
#[derive(Debug)]
pub enum IoErrorContext {
    /// `std::fs::metadata`
    ReadingMetadata(std::path::PathBuf),
    ReadingFile(std::path::PathBuf),
    WritingFile(std::path::PathBuf),
    RemovingFile(std::path::PathBuf),
    RenamingFile {
        from: std::path::PathBuf,
        to: std::path::PathBuf,
    },
    CopyingFile {
        from: std::path::PathBuf,
        to: std::path::PathBuf,
    },
    /// `std::fs::canonicalize`
    CanonicalizingPath(std::path::PathBuf),
    /// `std::env::current_dir`
    CurrentDir,
    /// `std::env::current_exe`
    CurrentExe,
}

impl HgError {
    pub fn corrupted(explanation: impl Into<String>) -> Self {
        HgError::CorruptedRepository(explanation.into(), HgBacktrace::capture())
    }

    pub fn unsupported(explanation: impl Into<String>) -> Self {
        HgError::UnsupportedFeature(explanation.into(), HgBacktrace::capture())
    }

    pub fn abort(
        explanation: impl Into<String>,
        exit_code: exit_codes::ExitCode,
        hint: Option<String>,
    ) -> Self {
        HgError::Abort {
            message: explanation.into(),
            detailed_exit_code: exit_code,
            hint,
            backtrace: HgBacktrace::capture(),
        }
    }

    pub fn abort_simple(explanation: impl Into<String>) -> Self {
        HgError::Abort {
            message: explanation.into(),
            detailed_exit_code: exit_codes::ABORT,
            hint: None,
            backtrace: HgBacktrace::capture(),
        }
    }
}

// TODO: use `DisplayBytes` instead to show non-Unicode filenames losslessly?
impl fmt::Display for HgError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            HgError::Abort { message, backtrace, .. } => {
                write!(f, "{}{}", backtrace, message)
            }
            HgError::IO(io_err) => io_err.fmt(f),
            HgError::CorruptedRepository(explanation, backtrace) => {
                write!(f, "{}{}", backtrace, explanation)
            }
            HgError::UnsupportedFeature(explanation, backtrace) => {
                write!(f, "{}unsupported feature: {}", backtrace, explanation)
            }
            HgError::CensoredNodeError(node, backtrace) => {
                write!(
                    f,
                    "{}censored node: {:x}\n\
                    (set censor.policy to ignore errors)",
                    backtrace,
                    node.short()
                )
            }
            HgError::ConfigValueParseError(error) => error.fmt(f),
            HgError::RaceDetected(context) => {
                write!(f, "encountered a race condition {context}")
            }
            HgError::Path(hg_path_error) => write!(f, "{}", hg_path_error),
            HgError::InterruptReceived => write!(f, "interrupt received"),
            HgError::RepoNotFound { at, backtrace } => {
                write!(
                    f,
                    "{backtrace}no repository found in '{}' (.hg not found)!",
                    at.display()
                )
            }
            HgError::Dirstate(dirstate_error) => dirstate_error.fmt(f),
            HgError::Pattern(pattern_error) => pattern_error.fmt(f),
        }
    }
}

// TODO: use `DisplayBytes` instead to show non-Unicode filenames losslessly?
impl fmt::Display for IoErrorContext {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            IoErrorContext::ReadingMetadata(path) => {
                write!(f, "when reading metadata of {}", path.display())
            }
            IoErrorContext::ReadingFile(path) => {
                write!(f, "when reading {}", path.display())
            }
            IoErrorContext::WritingFile(path) => {
                write!(f, "when writing {}", path.display())
            }
            IoErrorContext::RemovingFile(path) => {
                write!(f, "when removing {}", path.display())
            }
            IoErrorContext::RenamingFile { from, to } => write!(
                f,
                "when renaming {} to {}",
                from.display(),
                to.display()
            ),
            IoErrorContext::CopyingFile { from, to } => {
                write!(f, "when copying {} to {}", from.display(), to.display())
            }
            IoErrorContext::CanonicalizingPath(path) => {
                write!(f, "when canonicalizing {}", path.display())
            }
            IoErrorContext::CurrentDir => {
                write!(f, "error getting current working directory")
            }
            IoErrorContext::CurrentExe => {
                write!(f, "error getting current executable")
            }
        }
    }
}

#[derive(Debug)]
pub enum HgIoError {
    /// General IO error
    IO {
        /// The underlying raw os error code, if present
        raw_os_error: Option<i32>,
        /// The underlying os [`ErrorKind`], which is redundant with
        /// `raw_os_error`, but it's easier to reason with. There are still
        /// some common error codes that don't map to a specific kind,
        /// unfortunately, https://github.com/rust-lang/rust/issues/86442.
        kind: ErrorKind,
        /// What operation led to this error (reading this file, etc.)
        context: IoErrorContext,
        /// Backtrace information for debugging
        backtrace: HgBacktrace,
    },
    /// Attempted to write in a readonly VFS, along with the backtrace
    WriteAttemptInReadonlyVfs(HgBacktrace),
    /// A lock has non-UTF8 information, along with the backtrace
    NonUTF8Lock(HgBacktrace),
}

impl HgIoError {
    /// Create a `HgIoError` from a stdlib error + some context
    pub fn from_os_error(err: std::io::Error, context: IoErrorContext) -> Self {
        Self::IO {
            raw_os_error: err.raw_os_error(),
            kind: err.kind(),
            context,
            backtrace: HgBacktrace::capture(),
        }
    }

    /// Return the underlying raw os error, if applicable
    pub fn raw_os_error(&self) -> Option<i32> {
        match self {
            HgIoError::IO { raw_os_error, .. } => *raw_os_error,
            _ => None,
        }
    }

    /// Return the underlying os error kind, if applicable
    pub fn kind(&self) -> Option<ErrorKind> {
        match self {
            HgIoError::IO { kind, .. } => Some(*kind),
            _ => None,
        }
    }
}

// TODO remove this once all users have their Display impls removed
// Only top-level code (like `rhg` or `hg-pyo3`) should care about this
impl std::fmt::Display for HgIoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HgIoError::IO { kind, context, backtrace, raw_os_error: _ } => {
                write!(f, "{}abort: {}: {}", backtrace, context, kind)
            }
            HgIoError::WriteAttemptInReadonlyVfs(backtrace) => {
                write!(
                    f,
                    "{}abort: attempted write in a readonly vfs",
                    backtrace
                )
            }
            HgIoError::NonUTF8Lock(backtrace) => {
                write!(f, "{}abort: lock contains non-UTF8 bytes", backtrace)
            }
        }
    }
}

pub trait IoResultExt<T> {
    /// Annotate a possible I/O error as related to a reading a file at the
    /// given path.
    ///
    /// This allows printing something like “File not found when reading
    /// example.txt” instead of just “File not found”.
    ///
    /// Converts a `Result` with `std::io::Error` into one with `HgError`.
    fn when_reading_file(self, path: impl AsRef<Path>) -> Result<T, HgIoError>;

    fn when_writing_file(self, path: impl AsRef<Path>) -> Result<T, HgIoError>;

    fn with_context(
        self,
        context: impl FnOnce() -> IoErrorContext,
    ) -> Result<T, HgIoError>;
}

impl<T> IoResultExt<T> for std::io::Result<T> {
    fn when_reading_file(self, path: impl AsRef<Path>) -> Result<T, HgIoError> {
        self.with_context(|| {
            IoErrorContext::ReadingFile(path.as_ref().to_owned())
        })
    }

    fn when_writing_file(self, path: impl AsRef<Path>) -> Result<T, HgIoError> {
        self.with_context(|| {
            IoErrorContext::WritingFile(path.as_ref().to_owned())
        })
    }

    fn with_context(
        self,
        context: impl FnOnce() -> IoErrorContext,
    ) -> Result<T, HgIoError> {
        self.map_err(|error| HgIoError::from_os_error(error, context()))
    }
}

pub trait HgResultExt<T> {
    /// Handle missing files separately from other I/O error cases.
    ///
    /// Wraps the `Ok` type in an `Option`:
    ///
    /// * `Ok(x)` becomes `Ok(Some(x))`
    /// * An I/O "not found" error becomes `Ok(None)`
    /// * Other errors are unchanged
    fn io_not_found_as_none(self) -> Result<Option<T>, HgIoError>;
}

impl<T> HgResultExt<T> for Result<T, HgIoError> {
    fn io_not_found_as_none(self) -> Result<Option<T>, HgIoError> {
        match self {
            Ok(x) => Ok(Some(x)),
            Err(err) if err.kind() == Some(std::io::ErrorKind::NotFound) => {
                Ok(None)
            }
            Err(other_error) => Err(other_error),
        }
    }
}

impl From<RevlogError> for HgError {
    fn from(err: RevlogError) -> HgError {
        match err {
            RevlogError::WDirUnsupported => HgError::abort_simple(
                "working directory revision cannot be specified",
            ),
            RevlogError::InvalidRevision(r) => HgError::abort_simple(format!(
                "invalid revision identifier: {}",
                r
            )),
            RevlogError::AmbiguousPrefix(r) => HgError::abort_simple(format!(
                "ambiguous revision identifier: {}",
                r
            )),
            RevlogError::Other(error) => error,
            RevlogError::IO(hg_io_error) => HgError::from(*hg_io_error),
        }
    }
}

/// A simple wrapper around [`Backtrace`] that helps hide its display output
/// when it's turned off. See [`HgBacktrace`]'s [`Display`] implementation
/// for more info.
#[derive(Debug)]
pub struct HgBacktrace(Backtrace);

impl HgBacktrace {
    /// See [`Backtrace::capture`].
    pub fn capture() -> Self {
        Self(Backtrace::capture())
    }

    /// See [`Backtrace::force_capture`].
    pub fn force_capture() -> Self {
        Self(Backtrace::force_capture())
    }

    /// See [`Backtrace::disabled`].
    pub const fn disabled() -> Self {
        Self(Backtrace::disabled())
    }

    /// See [`Backtrace::status`].
    pub fn status(&self) -> BacktraceStatus {
        self.0.status()
    }
}

impl format_bytes::DisplayBytes for HgBacktrace {
    fn display_bytes(
        &self,
        output: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        output.write_all(self.to_string().as_bytes())
    }
}

impl std::fmt::Display for HgBacktrace {
    /// [`Backtrace`] shows messages like `disabled backtrace` when disabled
    /// or with a different status than
    /// `[std::backtrace::BacktraceStatus::Captured]`, which we don't want.
    ///
    /// We also take the opportunity to filter out:
    ///    - Rust runtime stuff about setting up the backtrace itself, because
    ///      that's 60+ lines of useless output for our stdlib-using OS-having
    ///      use cases.
    ///    - Python FFI module setup in the context of Rust extensions
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self.0.status() {
            std::backtrace::BacktraceStatus::Captured => {
                let mut python_filtered = false;
                // This is not really too performance sensitive since it
                // only activates when `RUST_BACKTRACE*` is detected, and
                // that means we're debugging.
                let output = self.0.to_string();
                for line in output.lines() {
                    if line.contains("/Python-3.") {
                        python_filtered = true;
                        break;
                    }
                    if line.contains("__rust_begin_short_backtrace") {
                        break;
                    }
                    f.write_str(line)?;
                    f.write_char('\n')?;
                }
                if python_filtered {
                    f.write_str(
                        "(Python and rustc backtrace setups filtered out)\n",
                    )?;
                } else {
                    f.write_str("(rustc backtrace setup filtered out)\n")?;
                }
                Ok(())
            }
            _ => Ok(()),
        }
    }
}
