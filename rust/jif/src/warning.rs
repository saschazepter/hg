//! Warnings that `jf` commands can report.

use format_bytes::Message;

/// What users should know about, without the command failing
#[derive(Debug)]
pub struct Warning {
    /// What is wrong, worded for users
    pub message: Message,
}

impl Warning {
    /// A warning saying `message`
    pub fn new(message: Message) -> Self {
        Self { message }
    }
}
