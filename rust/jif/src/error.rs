//! Errors that `jf` commands can fail with.

use std::ops::Deref;

use format_bytes::Message;
use format_bytes::Utf8;
use format_bytes::message;
use hg::encoding::EncodingErrorKind;
use hg::errors::HgBacktrace;
use hg::errors::HgError;
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
                HgError::CorruptedRepository(..) => {
                    ErrorCode::CorruptedRepository
                }
                HgError::UnsupportedFeature(..) => ErrorCode::Unsupported,
                HgError::ConfigValueParseError(_) => ErrorCode::InvalidConfig,
                HgError::RepoNotFound { .. } => ErrorCode::RepoNotFound,
                HgError::SharedPathNotFound { .. } => {
                    ErrorCode::CorruptedRepository
                }
                HgError::InterruptReceived => ErrorCode::Interrupted,
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
                HgError::Abort { .. }
                | HgError::Revlog(_)
                | HgError::Dirstate(_)
                | HgError::Shape(_)
                | HgError::Pattern(_)
                | HgError::FileIndex(_)
                | HgError::Docket(_)
                | HgError::Path(_) => ErrorCode::Abort,
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
pub fn hg_message(error: &HgError) -> Message {
    // `HgError` must be matched exhaustively here, we want breakage to make
    // us think about the new error type and its implications for the end user.
    match error {
        HgError::CorruptedRepository(reason, _) => message!(
            "corrupted repository: {reason}",
            reason = Utf8(reason.clone())
        ),
        HgError::UnsupportedFeature(feature, _) => message!(
            "unsupported feature: {feature}",
            feature = Utf8(feature.clone())
        ),
        HgError::Abort { message, .. } => {
            message!("{message}", message = Utf8(message.clone()))
        }
        HgError::InterruptReceived => message!("interrupted"),
        HgError::RepoNotFound { at, .. } => message!(
            "no repository found in {path}",
            path = get_bytes_from_path(at)
        ),
        HgError::SharedPathNotFound { shared_path, .. } => message!(
            "corrupted repository: .hg/sharedpath points to nonexistent \
            directory {path}",
            path = get_bytes_from_path(shared_path)
        ),
        // TODO render these once `hg-core` gives them structure
        HgError::IO(_)
        | HgError::ConfigValueParseError(_)
        | HgError::Revlog(_)
        | HgError::Dirstate(_)
        | HgError::Shape(_)
        | HgError::Pattern(_)
        | HgError::FileIndex(_)
        | HgError::Path(_)
        | HgError::Requirements(_)
        | HgError::Docket(_)
        | HgError::Encoding(_) => {
            message!("{error}", error = Utf8(format!("{error:?}")))
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
