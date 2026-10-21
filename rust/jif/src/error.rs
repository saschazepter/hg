//! Errors that `jf` commands can fail with.

use format_bytes::Message;
use hg::errors::HgBacktrace;
use hg::exit_codes;

/// Why a `jf` command failed.
#[derive(Debug)]
pub enum CommandError {
    /// Exit with an error message and "standard" failure exit code.
    Abort {
        message: Message,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<Message>,
        backtrace: HgBacktrace,
    },
}

impl CommandError {
    pub fn abort(message: Message) -> Self {
        Self::Abort {
            message,
            detailed_exit_code: exit_codes::ABORT,
            hint: None,
            backtrace: HgBacktrace::capture(),
        }
    }
}
