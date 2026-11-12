use std::backtrace::Backtrace;
use std::backtrace::BacktraceStatus;
use std::borrow::Cow;
use std::fmt;
use std::fmt::Write;
use std::io::ErrorKind;
use std::path::Path;
use std::path::PathBuf;

use crate::config::ConfigError;
use crate::config::ConfigValueParseError;
use crate::dirstate::DirstateError;
use crate::dirstate::status::StatusError;
use crate::encoding::EncodingError;
use crate::encoding::EncodingErrorKind;
use crate::exit_codes;
use crate::file_index::Error as FileIndexError;
use crate::file_patterns::PatternError;
use crate::narrow::VALID_PREFIXES;
use crate::narrow::shape::Error as ShapeError;
use crate::requirements::RequirementsError;
use crate::revlog::RevlogError;
use crate::sparse::SparseConfigError;
use crate::update::UpdateError;
use crate::update::UpdateErrorKind;
use crate::utils::docket::DocketError;
use crate::utils::hg_path::HgPathError;

/// Common error cases that can happen in many different APIs
#[derive(Debug, derive_more::From)]
pub enum HgError {
    /// A low-level IO error
    #[from]
    IO(HgIoError),

    /// The respository or requested operation involves a feature not
    /// supported by the Rust implementation. Falling back to the Python
    /// implementation may or may not work.
    ///
    /// Some of the other variants also fall in this category, see
    /// [`Self::is_unsupported`].
    UnsupportedFeature(UnsupportedFeatureKind, HgBacktrace),

    /// A memory allocation has failed in this foreign function
    AllocationFailed { function: &'static str, backtrace: HgBacktrace },

    /// A configuration value is not in the expected syntax.
    ///
    /// These errors can happen in many places in the code because values are
    /// parsed lazily as the file-level parser does not know the expected type
    /// and syntax of each value.
    #[from]
    ConfigValueParseError(ConfigValueParseError),
    /// An error that happened when reading or querying the config.
    /// Boxed to avoid very large `Result` types.
    Config(Box<ConfigError>),
    /// An error at the revlog layer
    Revlog(RevlogError),
    /// An error occured in the dirstate
    #[from]
    Dirstate(DirstateError),
    #[from]
    Shape(ShapeError),
    #[from]
    Pattern(PatternError),
    #[from]
    FileIndex(FileIndexError),
    /// Updating the working copy has failed
    #[from]
    Update(UpdateError),
    /// The sparse or narrow configuration of the repository is invalid
    #[from]
    Sparse(SparseConfigError),
    /// Setting up or using the character encoding has failed
    #[from]
    Encoding(EncodingError),
    /// The requirements of the repository are invalid or not supported
    #[from]
    Requirements(RequirementsError),
    /// An error about a docket or the data files it points to
    #[from]
    Docket(DocketError),
    /// An invalid path was found
    #[from]
    Path(HgPathError),
    /// An interrupt was received and we need to stop whatever we're doing
    InterruptReceived,
    /// No repository was found for an operation that required one
    RepoNotFound { at: PathBuf, backtrace: HgBacktrace },
    /// The repository is a share whose source does not exist
    SharedPathNotFound { shared_path: PathBuf, backtrace: HgBacktrace },
}

impl From<ConfigError> for HgError {
    fn from(value: ConfigError) -> Self {
        Self::Config(Box::new(value))
    }
}

impl From<StatusError> for HgError {
    fn from(value: StatusError) -> Self {
        match value {
            StatusError::Path(err) => HgError::Path(err),
            StatusError::Pattern(err) => HgError::Pattern(err),
            StatusError::Dirstate(err) => HgError::Dirstate(err),
        }
    }
}

/// Details about where an I/O error happened
#[derive(Debug, PartialEq)]
pub enum IoErrorContext {
    /// `std::fs::metadata`
    ReadingMetadata(PathBuf),
    ReadingFile(PathBuf),
    WritingFile(PathBuf),
    RemovingFile(PathBuf),
    RenamingFile {
        from: PathBuf,
        to: PathBuf,
    },
    CopyingFile {
        from: PathBuf,
        to: PathBuf,
    },
    /// `std::fs::canonicalize`
    CanonicalizingPath(PathBuf),
    /// `std::env::current_dir`
    CurrentDir,
    /// `std::env::current_exe`
    CurrentExe,
}

/// Features that are not supported by the Rust implementation and that are
/// not specific to one of the other error types.
#[derive(Debug, PartialEq)]
pub enum UnsupportedFeatureKind {
    /// The repository is a bundle
    BundleRepo,
    /// `cat` on the working directory
    WdirCat,
    /// Listing the files of the working directory
    WdirFiles,
    /// This revset is either invalid or uses parts of the language that are
    /// not implemented
    Revset(String),
}

impl From<UnsupportedFeatureKind> for HgError {
    fn from(kind: UnsupportedFeatureKind) -> Self {
        Self::UnsupportedFeature(kind, HgBacktrace::capture())
    }
}

impl HgError {
    /// The detailed exit code for this error
    pub fn exit_code(&self) -> exit_codes::ExitCode {
        match self {
            HgError::ConfigValueParseError(_) => exit_codes::CONFIG_ERROR_ABORT,
            HgError::Config(config_error) => match **config_error {
                ConfigError::Parse(_) | ConfigError::InvalidValue { .. } => {
                    exit_codes::CONFIG_ERROR_ABORT
                }
                ConfigError::MalformedCliOption { .. } => {
                    exit_codes::CONFIG_PARSE_ERROR_ABORT
                }
                _ => exit_codes::ABORT,
            },
            // Like Python, where only this one is a `StateError`
            HgError::Sparse(SparseConfigError::StaleNarrowspec) => {
                exit_codes::STATE_ERROR
            }
            HgError::Update(UpdateError {
                kind: UpdateErrorKind::UntrackedFilesDiffer,
                ..
            }) => exit_codes::STATE_ERROR,
            _ => exit_codes::ABORT,
        }
    }

    /// An optional hint for the user.
    pub fn hint(&self) -> Option<Cow<'_, str>> {
        match self {
            HgError::Config(config_error) => match &**config_error {
                ConfigError::NoUsername { .. } => Some(Cow::Borrowed(
                    "use 'hg config --edit' to set your username",
                )),
                ConfigError::WrongQueryType { asked, default_type, .. } => {
                    let mut hint = format!(
                        "asked for {asked}, type of default is \
                        '{default_type}'"
                    );
                    if *asked == "bytes" {
                        hint.push_str(", which cannot be interpreted as bytes");
                    }
                    Some(Cow::Owned(hint))
                }
                ConfigError::Items(_) => {
                    Some(Cow::Borrowed("Check 'mercurial/configitems.toml'"))
                }
                ConfigError::DefaultItems(_) => Some(Cow::Borrowed(
                    "`mercurial/configitems.toml` is not valid",
                )),
                ConfigError::Parse(_)
                | ConfigError::MalformedCliOption { .. }
                | ConfigError::InvalidValue { .. } => None,
            },
            HgError::Sparse(sparse_error) => match sparse_error {
                SparseConfigError::InvalidNarrowPrefix(_) => {
                    Some(Cow::Owned(format!(
                        "narrow patterns must begin with one of the \
                        following: {}",
                        VALID_PREFIXES.join(", ")
                    )))
                }
                SparseConfigError::StaleNarrowspec => Some(Cow::Borrowed(
                    "run 'hg tracked --update-working-copy'",
                )),
                SparseConfigError::EntryOutsideSection { .. } => {
                    Some(Cow::Borrowed(
                        "add an [include] or [exclude] line to declare the \
                        entry type",
                    ))
                }
                SparseConfigError::IncludesAfterExcludes { .. }
                | SparseConfigError::IncludesInNarrow => None,
            },
            _ => None,
        }
    }

    /// Returns `true` if this error means that Rust needs to fall back to
    /// Python, hoping it can recover/handle that feature.
    pub fn is_unsupported(&self) -> bool {
        match self {
            HgError::UnsupportedFeature(..) => true,
            HgError::Revlog(
                RevlogError::EllipsisNode { .. }
                | RevlogError::UnsupportedCompressionEngine { .. },
            ) => true,
            HgError::Requirements(error) => error.is_unsupported(),
            HgError::Encoding(EncodingError {
                kind: EncodingErrorKind::UnsupportedEncoding(_),
                ..
            }) => true,
            HgError::Pattern(pattern_error) => matches!(
                pattern_error,
                PatternError::UnsupportedSyntax(..)
                    | PatternError::RegexError { .. }
                    | PatternError::NonUtf8Pattern { .. }
            ),
            _ => false,
        }
    }
}

#[derive(Debug, PartialEq)]
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
            RevlogError::IO(hg_io_error) => HgError::from(*hg_io_error),
            RevlogError::Docket(error) => HgError::Docket(error),
            err => HgError::Revlog(err),
        }
    }
}

/// A simple wrapper around [`Backtrace`] that helps hide its display output
/// when it's turned off. See [`HgBacktrace`]'s [`Display`] implementation
/// for more info.
#[derive(Debug)]
pub struct HgBacktrace(Backtrace);

impl PartialEq for HgBacktrace {
    fn eq(&self, _other: &Self) -> bool {
        // We don't want the backtrace to affect any [`PartialEq`] or [`Eq`]
        // implementations for all the error structs it's used in.
        true
    }
}

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
