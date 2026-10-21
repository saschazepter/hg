//! Where commands write what they produce.

use std::io;
use std::io::IsTerminal;
use std::io::Stderr;
use std::io::Stdout;
use std::io::Write;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::PoisonError;

use format_bytes::Message;
use format_bytes::Sink;
use format_bytes::write_bytes;
use serde_json::Value;

use crate::error::CommandError;
use crate::error::ErrorKind;
use crate::error::hg_message;
use crate::json;
use crate::terminal::Terminal;

/// How machines get output
#[derive(Clone, Copy, PartialEq, clap::ValueEnum)]
pub enum Format {
    /// One JSON object per line
    Json,
}

/// Where commands write records and errors, for humans or machines.
///
/// Humans get records on `output` and errors on `error`, with user data
/// escaped on terminals only, so that pipes get it as-is. Machines get
/// everything on `output`, errors being records of their own.
/// Can be shared between threads, and each record is written whole.
pub struct Output<O = Stdout, E = Stderr> {
    format: Option<Format>,
    output: Mutex<O>,
    error: Mutex<E>,
    escape_output: bool,
    escape_error: bool,
}

impl Output {
    /// Writes to the process' stdout and stderr
    pub fn std(format: Option<Format>) -> Self {
        let (stdout, stderr) = (io::stdout(), io::stderr());
        Self {
            escape_output: stdout.is_terminal(),
            escape_error: stderr.is_terminal(),
            ..Self::new(format, stdout, stderr)
        }
    }
}

impl<O: Write, E: Write> Output<O, E> {
    /// Writes to `output` and `error` as if they were terminals
    pub fn new(format: Option<Format>, output: O, error: E) -> Self {
        let (output, error) = (Mutex::new(output), Mutex::new(error));
        let (escape_output, escape_error) = (true, true);
        Self { format, output, error, escape_output, escape_error }
    }

    /// Writes a record of `kind` with `write`, see [`record!`](crate::record)
    pub fn record(
        &self,
        kind: &str,
        write: impl FnOnce(&mut dyn Sink) -> io::Result<()>,
    ) -> io::Result<()> {
        let mut out = lock(&self.output);
        match self.format {
            None => for_humans(&mut *out, self.escape_output, write),
            Some(Format::Json) => {
                let mut record = json::Record::new(kind);
                write(&mut record)?;
                writeln!(out, "{}", Value::Object(record.0))
            }
        }
    }

    /// Writes `message` for humans only, such as "no mounts": machines get
    /// records alone.
    pub fn human(&self, message: &Message) -> io::Result<()> {
        match self.format {
            None => for_humans(
                &mut *lock(&self.output),
                self.escape_output,
                |sink| message.write_to(sink),
            ),
            Some(Format::Json) => Ok(()),
        }
    }

    /// Writes `error`. Failing to write is ignored, since the command is
    /// failing already.
    pub fn error(&self, error: &CommandError) {
        if self.format == Some(Format::Json) {
            let _ = self.json("error", json::error(error));
            return;
        }
        let mut out = lock(&self.error);
        let message = match &error.kind {
            ErrorKind::Abort(message) => message,
            ErrorKind::Hg(error) => &hg_message(error),
        };
        let _ = for_humans(&mut *out, self.escape_error, |sink| {
            write_bytes!(sink, "abort: ")?;
            for context in error.context.iter().rev() {
                write_bytes!(sink, "{context}: ")?;
            }
            write_bytes!(sink, "{message}\n")
        });
        if let Some(hint) = &error.hint {
            let _ = for_humans(&mut *out, self.escape_error, |sink| {
                write_bytes!(sink, "({hint})\n")
            });
        }
    }

    /// Writes an object made by [`json`] as a record of `kind`
    fn json(&self, kind: &str, mut value: Value) -> io::Result<()> {
        value[json::KIND] = kind.into();
        writeln!(lock(&self.output), "{value}")
    }

    pub fn into_inner(self) -> (O, E) {
        (into_inner(self.output), into_inner(self.error))
    }
}

/// Writes with `write` for humans, escaping user data if `escape`
fn for_humans(
    writer: &mut impl Write,
    escape: bool,
    write: impl FnOnce(&mut dyn Sink) -> io::Result<()>,
) -> io::Result<()> {
    if escape {
        write(&mut Terminal(writer))
    } else {
        write(writer)
    }
}

// Writing whole records cannot leave a writer half-updated, so poisoning
// does not matter
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn into_inner<T>(mutex: Mutex<T>) -> T {
    mutex.into_inner().unwrap_or_else(PoisonError::into_inner)
}

/// Writes a record to an [`Output`], as a `write_bytes!` format string and
/// its arguments: humans get the text, and machines get the arguments as
/// fields named after them, along with its kind.
///
/// ```ignore
/// record!(output, "status", "{status} {path}\n", status = b"M", path = path)?;
/// ```
#[macro_export]
macro_rules! record {
    ($output:expr, $kind:expr, $($format:tt)+) => {
        $output.record($kind, |sink| {
            ::format_bytes::write_bytes!(sink, $($format)+)
        })
    };
}

#[cfg(test)]
mod tests {
    use format_bytes::message;

    use super::*;

    fn record(format: Option<Format>) -> String {
        let output = Output::new(format, vec![], vec![]);
        let path = b"caf\xe9".to_vec();
        crate::record!(
            output,
            "status",
            "{status} {path}\n",
            status = b"M",
            path = path
        )
        .expect("writing to a `Vec` cannot fail");
        String::from_utf8(output.into_inner().0)
            .expect("escaping and JSON make it UTF-8")
    }

    #[test]
    fn records() {
        assert_eq!(record(None), "M caf\\xe9\n");
        assert_eq!(
            record(Some(Format::Json)),
            r#"{"_internal_jf_kind":"status","path":{"base64":"Y2Fm6Q=="},"status":"M"}
"#
        );
    }

    #[test]
    fn as_is_when_not_terminals() {
        let output = Output {
            escape_output: false,
            escape_error: false,
            ..Output::new(None, vec![], vec![])
        };
        let path = b"caf\xe9".to_vec();
        crate::record!(output, "status", "{path}\n").unwrap();
        let message = message!("{path}", path = path.clone());
        output.error(&CommandError::abort(message));
        let expected = (b"caf\xe9\n".to_vec(), b"abort: caf\xe9\n".to_vec());
        assert_eq!(output.into_inner(), expected);
    }

    #[test]
    fn errors() {
        let output = Output::new(None, vec![], vec![]);
        output.error(&CommandError::abort(message!("a")));
        assert_eq!(output.into_inner(), (vec![], b"abort: a\n".to_vec()));

        let output = Output::new(Some(Format::Json), vec![], vec![]);
        output.error(&CommandError::abort(message!("a")));
        let (stdout, stderr) = output.into_inner();
        assert_eq!(stderr, b"");
        let record: Value = serde_json::from_slice(&stdout).unwrap();
        assert_eq!(record[json::KIND], "error");
    }
}
