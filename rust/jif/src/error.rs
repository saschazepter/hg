//! Errors that `jf` commands can fail with.

use std::ops::Deref;

use format_bytes::Message;
use hg::errors::HgBacktrace;

/// Why a `jf` command failed.
///
/// Boxed, so that results stay small when there is no error.
#[derive(Debug)]
pub struct CommandError(Box<Details>);

#[derive(Debug)]
pub struct Details {
    pub kind: ErrorKind,
    pub hint: Option<Message>,
    pub backtrace: HgBacktrace,
}

/// What went wrong.
#[derive(Debug)]
pub enum ErrorKind {
    /// Exit with an error message and "standard" failure exit code.
    Abort(Message),
}

impl CommandError {
    pub fn abort(message: Message) -> Self {
        Self(Box::new(Details {
            kind: ErrorKind::Abort(message),
            hint: None,
            backtrace: HgBacktrace::capture(),
        }))
    }
}

impl Deref for CommandError {
    type Target = Details;

    fn deref(&self) -> &Details {
        &self.0
    }
}
