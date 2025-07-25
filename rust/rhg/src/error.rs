use std::convert::From;

use format_bytes::format_bytes;
use hg::config::ConfigError;
use hg::config::ConfigParseError;
use hg::config::ConfigValueParseError;
use hg::dirstate::on_disk::DirstateV2ParseError;
use hg::dirstate::status::StatusError;
use hg::dirstate::DirstateError;
use hg::dirstate::DirstateMapError;
use hg::errors::HgBacktrace;
use hg::errors::HgError;
use hg::exit_codes;
use hg::filepatterns::PatternError;
use hg::repo::RepoError;
use hg::revlog::RevlogError;
use hg::sparse::SparseConfigError;
use hg::utils::files::get_bytes_from_path;
use hg::utils::hg_path::HgPathError;

use crate::ui::UiError;
use crate::NoRepoInCwdError;

/// The kind of command error
#[derive(Debug)]
pub enum CommandError {
    /// Exit with an error message and "standard" failure exit code.
    Abort {
        message: Vec<u8>,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<Vec<u8>>,
        backtrace: HgBacktrace,
    },

    /// Exit with a failure exit code but no message.
    Unsuccessful,

    /// Encountered something (such as a CLI argument, repository layout, …)
    /// not supported by this version of `rhg`. Depending on configuration
    /// `rhg` may attempt to silently fall back to Python-based `hg`, which
    /// may or may not support this feature.
    UnsupportedFeature { message: Vec<u8> },
    /// The fallback executable does not exist (or has some other problem if
    /// we end up being more precise about broken fallbacks).
    InvalidFallback { path: Vec<u8>, err: String },
}

impl CommandError {
    pub fn abort(message: impl AsRef<str>) -> Self {
        CommandError::abort_with_exit_code(message, exit_codes::ABORT)
    }

    pub fn abort_with_exit_code(
        message: impl AsRef<str>,
        detailed_exit_code: exit_codes::ExitCode,
    ) -> Self {
        CommandError::Abort {
            // TODO: bytes-based (instead of Unicode-based) formatting
            // of error messages to handle non-UTF-8 filenames etc:
            // https://www.mercurial-scm.org/wiki/EncodingStrategy#Mixing_output
            message: message.as_ref().as_bytes().to_owned(),
            detailed_exit_code,
            hint: None,
            backtrace: HgBacktrace::capture(),
        }
    }

    fn abort_with_exit_code_and_hint(
        message: impl AsRef<str>,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<impl AsRef<str>>,
        backtrace: HgBacktrace,
    ) -> Self {
        CommandError::Abort {
            message: message.as_ref().as_bytes().to_owned(),
            detailed_exit_code,
            hint: hint.map(|h| h.as_ref().as_bytes().to_owned()),
            backtrace,
        }
    }

    pub fn abort_with_exit_code_bytes(
        message: impl AsRef<[u8]>,
        detailed_exit_code: exit_codes::ExitCode,
    ) -> Self {
        // TODO: use this everywhere it makes sense instead of the string
        // version.
        CommandError::Abort {
            message: message.as_ref().into(),
            detailed_exit_code,
            hint: None,
            backtrace: HgBacktrace::capture(),
        }
    }

    pub fn unsupported(message: impl AsRef<str>) -> Self {
        CommandError::UnsupportedFeature {
            message: message.as_ref().as_bytes().to_owned(),
        }
    }
}

/// For now we don’t differenciate between invalid CLI args and valid for `hg`
/// but not supported yet by `rhg`.
impl From<clap::Error> for CommandError {
    fn from(error: clap::Error) -> Self {
        CommandError::unsupported(error.to_string())
    }
}

impl From<HgError> for CommandError {
    fn from(error: HgError) -> Self {
        match error {
            HgError::UnsupportedFeature(message, backtrace) => {
                CommandError::unsupported(format!("{}{}", backtrace, message))
            }
            e @ HgError::CensoredNodeError(_, _) => {
                CommandError::unsupported(format!("abort: {}", e))
            }
            HgError::Abort { message, detailed_exit_code, hint, backtrace } => {
                CommandError::abort_with_exit_code_and_hint(
                    message,
                    detailed_exit_code,
                    hint,
                    backtrace,
                )
            }
            _ => CommandError::abort(error.to_string()),
        }
    }
}

impl From<ConfigValueParseError> for CommandError {
    fn from(error: ConfigValueParseError) -> Self {
        CommandError::abort_with_exit_code(
            error.to_string(),
            exit_codes::CONFIG_ERROR_ABORT,
        )
    }
}

impl From<UiError> for CommandError {
    fn from(_error: UiError) -> Self {
        // If we already failed writing to stdout or stderr,
        // writing an error message to stderr about it would be likely to fail
        // too.
        CommandError::abort("")
    }
}

impl From<RepoError> for CommandError {
    fn from(error: RepoError) -> Self {
        match error {
            RepoError::NotFound { at } => {
                CommandError::abort_with_exit_code_bytes(
                    format_bytes!(
                        b"abort: repository {} not found",
                        get_bytes_from_path(at)
                    ),
                    exit_codes::ABORT,
                )
            }
            RepoError::ConfigParseError(error) => error.into(),
            RepoError::Other(error) => error.into(),
        }
    }
}

impl<'a> From<&'a NoRepoInCwdError> for CommandError {
    fn from(error: &'a NoRepoInCwdError) -> Self {
        let NoRepoInCwdError { cwd } = error;
        CommandError::abort_with_exit_code_bytes(
            format_bytes!(
                b"abort: no repository found in '{}' (.hg not found)!",
                get_bytes_from_path(cwd)
            ),
            exit_codes::ABORT,
        )
    }
}

impl From<ConfigError> for CommandError {
    fn from(error: ConfigError) -> Self {
        match error {
            ConfigError::Parse(error) => error.into(),
            ConfigError::Other(error) => error.into(),
        }
    }
}

impl From<ConfigParseError> for CommandError {
    fn from(error: ConfigParseError) -> Self {
        let ConfigParseError { origin, line, message } = error;
        let line_message = if let Some(line_number) = line {
            format_bytes!(b":{}", line_number.to_string().into_bytes())
        } else {
            Vec::new()
        };
        CommandError::abort_with_exit_code_bytes(
            format_bytes!(
                b"config error at {}{}: {}",
                origin,
                line_message,
                message
            ),
            exit_codes::CONFIG_ERROR_ABORT,
        )
    }
}

impl From<RevlogError> for CommandError {
    fn from(err: RevlogError) -> CommandError {
        let err: HgError = err.into();
        err.into()
    }
}

impl From<StatusError> for CommandError {
    fn from(error: StatusError) -> Self {
        match error {
            StatusError::Pattern(_) => {
                CommandError::unsupported(format!("{}", error))
            }
            _ => CommandError::abort(format!("{}", error)),
        }
    }
}

impl From<HgPathError> for CommandError {
    fn from(error: HgPathError) -> Self {
        CommandError::unsupported(format!("{}", error))
    }
}

impl From<PatternError> for CommandError {
    fn from(error: PatternError) -> Self {
        CommandError::unsupported(format!("{}", error))
    }
}

impl From<DirstateMapError> for CommandError {
    fn from(error: DirstateMapError) -> Self {
        CommandError::abort(format!("{}", error))
    }
}

impl From<DirstateError> for CommandError {
    fn from(error: DirstateError) -> Self {
        match error {
            DirstateError::Common(error) => error.into(),
            DirstateError::Map(error) => error.into(),
        }
    }
}

impl From<DirstateV2ParseError> for CommandError {
    fn from(error: DirstateV2ParseError) -> Self {
        HgError::from(error).into()
    }
}

impl From<SparseConfigError> for CommandError {
    fn from(e: SparseConfigError) -> Self {
        match e {
            SparseConfigError::IncludesAfterExcludes { context } => {
                Self::abort_with_exit_code_bytes(
                    format_bytes!(
                        b"{} config cannot have includes after excludes",
                        context
                    ),
                    exit_codes::CONFIG_PARSE_ERROR_ABORT,
                )
            }
            SparseConfigError::EntryOutsideSection { context, line } => {
                Self::abort_with_exit_code_bytes(
                    format_bytes!(
                        b"{} config entry outside of section: {}",
                        context,
                        &line,
                    ),
                    exit_codes::CONFIG_PARSE_ERROR_ABORT,
                )
            }
            SparseConfigError::InvalidNarrowPrefix(prefix) => {
                Self::abort_with_exit_code_bytes(
                    format_bytes!(
                        b"invalid prefix on narrow pattern: {}",
                        &prefix
                    ),
                    exit_codes::ABORT,
                )
            }
            SparseConfigError::WhitespaceAtEdgeOfPattern(prefix) => {
                Self::abort_with_exit_code_bytes(
                    format_bytes!(
                        b"narrow pattern with whitespace at the edge: {}",
                        &prefix
                    ),
                    exit_codes::ABORT,
                )
            }
            SparseConfigError::IncludesInNarrow => Self::abort(
                "including other spec files using '%include' \
                    is not supported in narrowspec",
            ),
            SparseConfigError::HgError(e) => Self::from(e),
            SparseConfigError::PatternError(e) => {
                Self::unsupported(format!("{}", e))
            }
        }
    }
}
