//! Where commands write what they produce.

use std::io;
use std::io::IsTerminal;
use std::io::Stdout;
use std::io::Write;
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::sync::PoisonError;

use format_bytes::Sink;
use serde_json::Value;

use crate::json;
use crate::terminal::Terminal;

/// How machines get output
#[derive(Clone, Copy, PartialEq, clap::ValueEnum)]
pub enum Format {
    /// One JSON object per line
    Json,
}

/// Where commands write records, for humans or machines.
///
/// Humans get user data escaped on terminals only, so that pipes get it as-is.
/// Can be shared between threads, and each record is written whole.
pub struct Output<O = Stdout> {
    format: Option<Format>,
    output: Mutex<O>,
    escape_output: bool,
}

impl Output {
    /// Writes to the process' stdout
    pub fn std(format: Option<Format>) -> Self {
        let stdout = io::stdout();
        Self {
            escape_output: stdout.is_terminal(),
            ..Self::new(format, stdout)
        }
    }
}

impl<O: Write> Output<O> {
    /// Writes to `output` as if it were a terminal
    pub fn new(format: Option<Format>, output: O) -> Self {
        Self { format, output: Mutex::new(output), escape_output: true }
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

    pub fn into_inner(self) -> O {
        into_inner(self.output)
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
    use super::*;

    fn record(format: Option<Format>) -> String {
        let output = Output::new(format, vec![]);
        let path = b"caf\xe9".to_vec();
        crate::record!(
            output,
            "status",
            "{status} {path}\n",
            status = b"M",
            path = path
        )
        .expect("writing to a `Vec` cannot fail");
        String::from_utf8(output.into_inner())
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
    fn as_is_when_not_a_terminal() {
        let output =
            Output { escape_output: false, ..Output::new(None, vec![]) };
        let path = b"caf\xe9".to_vec();
        crate::record!(output, "status", "{path}\n").unwrap();
        assert_eq!(output.into_inner(), b"caf\xe9\n");
    }
}
