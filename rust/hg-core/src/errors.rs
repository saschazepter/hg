use crate::config::ConfigValueParseError;
use crate::exit_codes;
use crate::revlog::RevlogError;
use crate::utils::hg_path::HgPathError;
use std::fmt;

/// Common error cases that can happen in many different APIs
#[derive(Debug, derive_more::From)]
pub enum HgError {
    IoError {
        error: std::io::Error,
        context: IoErrorContext,
    },

    /// A file under `.hg/` normally only written by Mercurial is not in the
    /// expected format. This indicates a bug in Mercurial, filesystem
    /// corruption, or hardware failure.
    ///
    /// The given string is a short explanation for users, not intended to be
    /// machine-readable.
    CorruptedRepository(String),

    /// The respository or requested operation involves a feature not
    /// supported by the Rust implementation. Falling back to the Python
    /// implementation may or may not work.
    ///
    /// The given string is a short explanation for users, not intended to be
    /// machine-readable.
    UnsupportedFeature(String),

    /// Operation cannot proceed for some other reason.
    ///
    /// The message is a short explanation for users, not intended to be
    /// machine-readable.
    Abort {
        message: String,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<String>,
    },

    /// A configuration value is not in the expected syntax.
    ///
    /// These errors can happen in many places in the code because values are
    /// parsed lazily as the file-level parser does not know the expected type
    /// and syntax of each value.
    #[from]
    ConfigValueParseError(ConfigValueParseError),

    /// Censored revision data.
    CensoredNodeError,
    /// A race condition has been detected. This *must* be handled locally
    /// and not directly surface to the user.
    RaceDetected(String),
    /// An invalid path was found
    Path(HgPathError),
    /// An interrupt was received and we need to stop whatever we're doing
    InterruptReceived,
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
        // TODO: capture a backtrace here and keep it in the error value
        // to aid debugging?
        // https://doc.rust-lang.org/std/backtrace/struct.Backtrace.html
        HgError::CorruptedRepository(explanation.into())
    }

    pub fn unsupported(explanation: impl Into<String>) -> Self {
        HgError::UnsupportedFeature(explanation.into())
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
        }
    }

    pub fn abort_simple(explanation: impl Into<String>) -> Self {
        HgError::Abort {
            message: explanation.into(),
            detailed_exit_code: exit_codes::ABORT,
            hint: None,
        }
    }
}

// TODO: use `DisplayBytes` instead to show non-Unicode filenames losslessly?
impl fmt::Display for HgError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            HgError::Abort { message, .. } => write!(f, "{}", message),
            HgError::IoError { error, context } => {
                write!(f, "abort: {}: {}", context, error)
            }
            HgError::CorruptedRepository(explanation) => {
                write!(f, "abort: {}", explanation)
            }
            HgError::UnsupportedFeature(explanation) => {
                write!(f, "unsupported feature: {}", explanation)
            }
            HgError::CensoredNodeError => {
                write!(f, "encountered a censored node")
            }
            HgError::ConfigValueParseError(error) => error.fmt(f),
            HgError::RaceDetected(context) => {
                write!(f, "encountered a race condition {context}")
            }
            HgError::Path(hg_path_error) => write!(f, "{}", hg_path_error),
            HgError::InterruptReceived => write!(f, "interrupt received"),
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
            IoErrorContext::CopyingFile { from, to } => write!(
                f,
                "when copying {} to {}",
                from.display(),
                to.display()
            ),
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

pub trait IoResultExt<T> {
    /// Annotate a possible I/O error as related to a reading a file at the
    /// given path.
    ///
    /// This allows printing something like “File not found when reading
    /// example.txt” instead of just “File not found”.
    ///
    /// Converts a `Result` with `std::io::Error` into one with `HgError`.
    fn when_reading_file(self, path: &std::path::Path) -> Result<T, HgError>;

    fn when_writing_file(self, path: &std::path::Path) -> Result<T, HgError>;

    fn with_context(
        self,
        context: impl FnOnce() -> IoErrorContext,
    ) -> Result<T, HgError>;
}

impl<T> IoResultExt<T> for std::io::Result<T> {
    fn when_reading_file(self, path: &std::path::Path) -> Result<T, HgError> {
        self.with_context(|| IoErrorContext::ReadingFile(path.to_owned()))
    }

    fn when_writing_file(self, path: &std::path::Path) -> Result<T, HgError> {
        self.with_context(|| IoErrorContext::WritingFile(path.to_owned()))
    }

    fn with_context(
        self,
        context: impl FnOnce() -> IoErrorContext,
    ) -> Result<T, HgError> {
        self.map_err(|error| HgError::IoError {
            error,
            context: context(),
        })
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
    fn io_not_found_as_none(self) -> Result<Option<T>, HgError>;
}

impl<T> HgResultExt<T> for Result<T, HgError> {
    fn io_not_found_as_none(self) -> Result<Option<T>, HgError> {
        match self {
            Ok(x) => Ok(Some(x)),
            Err(HgError::IoError { error, .. })
                if error.kind() == std::io::ErrorKind::NotFound =>
            {
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
                "abort: working directory revision cannot be specified",
            ),
            RevlogError::InvalidRevision(r) => HgError::abort_simple(format!(
                "abort: invalid revision identifier: {}",
                r
            )),
            RevlogError::AmbiguousPrefix(r) => HgError::abort_simple(format!(
                "abort: ambiguous revision identifier: {}",
                r
            )),
            RevlogError::Other(error) => error,
        }
    }
}
