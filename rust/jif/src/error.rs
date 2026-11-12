//! Errors that `jf` commands can fail with.

use std::ops::Deref;

use format_bytes::Message;
use format_bytes::Utf8;
use format_bytes::message;
use hg::encoding::EncodingErrorKind;
use hg::errors::HgBacktrace;
use hg::errors::HgError;
use hg::errors::HgIoError;
use hg::errors::IoErrorContext;
use hg::requirements::RequirementsErrorKind;
use hg::utils::files::get_bytes_from_path;

use crate::diagnostic::Snippet;

/// Why a `jf` command failed.
///
/// Boxed, so that results stay small when there is no error.
#[derive(Debug)]
pub struct CommandError(Box<Details>);

#[derive(Debug)]
pub struct Details {
    pub kind: ErrorKind,
    /// What was being done, innermost first
    pub context: Vec<Message>,
    pub hint: Option<Message>,
    /// The parts of its source that the error points into
    pub snippets: Vec<Snippet>,
    pub backtrace: HgBacktrace,
}

/// What went wrong.
#[derive(Debug)]
pub enum ErrorKind {
    /// Exit with an error message and "standard" failure exit code.
    Abort(Message),
    /// From `hg-core`, see [`hg_message`]
    Hg(HgError),
}

/// Identifies errors for machines so messages can be changed.
///
/// Note that there is no backwards compatibility promise in `jf` until 1.0,
/// so while there will be deprecation windows, any code may change until then.
///
/// Changes in `hg-core` only change how its errors map to codes here, `jf` is
/// not coupled to `hg-core`'s ordering etc.
/// jf's own error cases will get codes here as they come.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// Any other failure
    Abort,
    /// Reading or writing failed
    Io,
    /// Repository data is not as expected
    CorruptedRepository,
    /// The repository or the operation needs an unsupported feature
    Unsupported,
    /// A configuration value is invalid
    InvalidConfig,
    /// There is no repository where one is needed
    RepoNotFound,
    Interrupted,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::Abort => "abort",
            ErrorCode::Io => "io",
            ErrorCode::CorruptedRepository => "corrupted-repository",
            ErrorCode::Unsupported => "unsupported",
            ErrorCode::InvalidConfig => "invalid-config",
            ErrorCode::RepoNotFound => "repo-not-found",
            ErrorCode::Interrupted => "interrupted",
        }
    }
}

impl ErrorKind {
    pub fn code(&self) -> ErrorCode {
        match self {
            ErrorKind::Abort(_) => ErrorCode::Abort,
            ErrorKind::Hg(error) => match error {
                HgError::IO(_) => ErrorCode::Io,
                HgError::UnsupportedFeature(..) => ErrorCode::Unsupported,
                HgError::ConfigValueParseError(_) => ErrorCode::InvalidConfig,
                HgError::RepoNotFound { .. } => ErrorCode::RepoNotFound,
                HgError::SharedPathNotFound { .. } => {
                    ErrorCode::CorruptedRepository
                }
                HgError::InterruptReceived => ErrorCode::Interrupted,
                HgError::AllocationFailed { .. } => ErrorCode::Abort,
                HgError::Requirements(error) => match error.kind {
                    RequirementsErrorKind::ParseError => {
                        ErrorCode::CorruptedRepository
                    }
                    RequirementsErrorKind::Changed => ErrorCode::Abort,
                    _ => ErrorCode::Unsupported,
                },
                HgError::Encoding(error) => match error.kind {
                    EncodingErrorKind::UnsupportedEncoding(_) => {
                        ErrorCode::Unsupported
                    }
                    _ => ErrorCode::Abort,
                },
                // TODO tell these apart once `hg-core` gives them structure
                HgError::Revlog(_)
                | HgError::Dirstate(_)
                | HgError::Shape(_)
                | HgError::Pattern(_)
                | HgError::FileIndex(_)
                | HgError::Docket(_)
                | HgError::Path(_)
                | HgError::Sparse(_)
                | HgError::Config(_)
                | HgError::Update(_) => ErrorCode::Abort,
            },
        }
    }
}

impl CommandError {
    pub fn abort(message: Message) -> Self {
        Self(Box::new(Details {
            kind: ErrorKind::Abort(message),
            context: vec![],
            hint: None,
            snippets: vec![],
            backtrace: HgBacktrace::capture(),
        }))
    }

    /// Points into the source of the error
    pub fn with_snippet(mut self, snippet: Snippet) -> Self {
        self.0.snippets.push(snippet);
        self
    }
}

impl Deref for CommandError {
    type Target = Details;

    fn deref(&self) -> &Details {
        &self.0
    }
}

impl From<HgError> for CommandError {
    fn from(error: HgError) -> Self {
        let hint = error
            .hint()
            .map(|hint| message!("{hint}", hint = Utf8(hint.into_owned())));
        Self(Box::new(Details {
            kind: ErrorKind::Hg(error),
            context: vec![],
            hint,
            snippets: vec![],
            backtrace: HgBacktrace::capture(),
        }))
    }
}

/// Adds context to errors.
pub trait ResultExt<T> {
    /// Add any message as context to the [`CommandError`].
    fn with_context(
        self,
        context: impl FnOnce() -> Message,
    ) -> Result<T, CommandError>;
}

impl<T, E: Into<CommandError>> ResultExt<T> for Result<T, E> {
    fn with_context(
        self,
        context: impl FnOnce() -> Message,
    ) -> Result<T, CommandError> {
        self.map_err(|error| {
            let mut error = error.into();
            error.0.context.push(context());
            error
        })
    }
}

/// We do our own formatting of `HgError`, since `hg-core` shouldn't care about
/// the presentation layer.
///
/// `jf` has no backwards compatibility to uphold with the output of `hg`, so
/// this purposefully does not use `hg::error_display`: we are free to come up
/// with better errors here.
///
/// TODO this is only a starting point: the domain-specific errors only get
/// a description of their category followed by their debug representation.
pub fn hg_message(error: &HgError) -> Message {
    // `HgError` must be matched exhaustively here, we want breakage to make
    // us think about the new error type and its implications for the end user.
    match error {
        HgError::IO(error) => io_message(error),
        HgError::UnsupportedFeature(feature, _) => message!(
            "unsupported feature: {feature}",
            feature = Utf8(format!("{feature:?}"))
        ),
        HgError::InterruptReceived => message!("interrupted"),
        HgError::AllocationFailed { function, .. } => {
            message!(
                "{function} failed to allocate",
                function = Utf8(*function)
            )
        }
        HgError::RepoNotFound { at, .. } => message!(
            "no repository found in {path}",
            path = get_bytes_from_path(at)
        ),
        HgError::SharedPathNotFound { shared_path, .. } => message!(
            "corrupted repository: .hg/sharedpath points to nonexistent \
            directory {path}",
            path = get_bytes_from_path(shared_path)
        ),
        HgError::ConfigValueParseError(error) => message!(
            "invalid value for config `{section}.{item}`: expected a \
            {expected}, got '{value}'",
            section = error.section.clone(),
            item = error.item.clone(),
            expected = Utf8(error.expected_type),
            value = error.value.clone()
        ),
        HgError::Requirements(error) => message!(
            "unsuitable repository requirements: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Encoding(error) => message!(
            "encoding error: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Update(error) => message!(
            "working copy update failed: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Docket(error) => message!(
            "docket error for '{path}': {kind}",
            path = get_bytes_from_path(&error.docket_path),
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Shape(error) => message!(
            "invalid store shapes: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::FileIndex(error) => message!(
            "corrupted file index: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Path(error) => message!(
            "invalid path: {kind}",
            kind = Utf8(format!("{:?}", error.kind))
        ),
        HgError::Config(error) => {
            message!(
                "config error: {error}",
                error = Utf8(format!("{error:?}"))
            )
        }
        HgError::Revlog(error) => {
            message!(
                "revlog error: {error}",
                error = Utf8(format!("{error:?}"))
            )
        }
        HgError::Dirstate(error) => message!(
            "dirstate error: {error}",
            error = Utf8(format!("{error:?}"))
        ),
        HgError::Pattern(error) => message!(
            "invalid pattern: {error}",
            error = Utf8(format!("{error:?}"))
        ),
        HgError::Sparse(error) => message!(
            "invalid sparse or narrow config: {error}",
            error = Utf8(format!("{error:?}"))
        ),
    }
}

/// What went wrong with an I/O operation, then what the operation was
fn io_message(error: &HgIoError) -> Message {
    match error {
        HgIoError::IO { kind, context, .. } => {
            let kind = Utf8(kind.to_string());
            match context {
                IoErrorContext::ReadingMetadata(path) => message!(
                    "{kind} while reading the metadata of '{path}'",
                    path = get_bytes_from_path(path)
                ),
                IoErrorContext::ReadingFile(path) => message!(
                    "{kind} while reading '{path}'",
                    path = get_bytes_from_path(path)
                ),
                IoErrorContext::WritingFile(path) => message!(
                    "{kind} while writing '{path}'",
                    path = get_bytes_from_path(path)
                ),
                IoErrorContext::RemovingFile(path) => message!(
                    "{kind} while removing '{path}'",
                    path = get_bytes_from_path(path)
                ),
                IoErrorContext::RenamingFile { from, to } => message!(
                    "{kind} while renaming '{from}' to '{to}'",
                    from = get_bytes_from_path(from),
                    to = get_bytes_from_path(to)
                ),
                IoErrorContext::CopyingFile { from, to } => message!(
                    "{kind} while copying '{from}' to '{to}'",
                    from = get_bytes_from_path(from),
                    to = get_bytes_from_path(to)
                ),
                IoErrorContext::CanonicalizingPath(path) => message!(
                    "{kind} while canonicalizing '{path}'",
                    path = get_bytes_from_path(path)
                ),
                IoErrorContext::CurrentDir => {
                    message!("{kind} while getting the current directory")
                }
                IoErrorContext::CurrentExe => {
                    message!("{kind} while getting the current executable")
                }
            }
        }
        HgIoError::WriteAttemptInReadonlyVfs(_) => {
            message!("attempted to write in a read-only location")
        }
        HgIoError::NonUTF8Lock(_) => {
            message!("a lock file contains non-UTF8 data")
        }
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    use super::*;
    use crate::terminal::Terminal;

    #[test]
    fn context_innermost_first() {
        let result: Result<(), _> = Err(CommandError::abort(message!("a")));
        let error = result
            .with_context(|| message!("b"))
            .with_context(|| message!("c"))
            .unwrap_err();
        let mut terminal = Terminal(vec![]);
        for context in &error.context {
            context.write_to(&mut terminal).unwrap();
        }
        assert_eq!(terminal.0, b"bc");
    }

    #[test]
    fn hg_message_escapes_paths() {
        let error = HgError::RepoNotFound {
            at: OsStr::from_bytes(b"/caf\xe9").into(),
            backtrace: HgBacktrace::disabled(),
        };
        let mut terminal = Terminal(vec![]);
        hg_message(&error).write_to(&mut terminal).unwrap();
        assert_eq!(terminal.0, b"no repository found in /caf\\xe9");
    }
}
