//! Errors that `jf` commands can fail with.

use hg::errors::HgBacktrace;
use hg::exit_codes;

/// Why a `jf` command failed.
#[derive(Debug)]
pub enum CommandError {
    /// Exit with an error message and "standard" failure exit code.
    Abort {
        message: Vec<u8>,
        detailed_exit_code: exit_codes::ExitCode,
        hint: Option<Vec<u8>>,
        backtrace: HgBacktrace,
    },
}

impl CommandError {
    pub fn abort(message: impl AsRef<[u8]>) -> Self {
        Self::Abort {
            message: message.as_ref().to_owned(),
            detailed_exit_code: exit_codes::ABORT,
            hint: None,
            backtrace: HgBacktrace::capture(),
        }
    }
}
