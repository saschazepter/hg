//! Writing for humans on a terminal.

use std::io;
use std::io::Write;

use format_bytes::ArgName;
use format_bytes::DisplayBytes;
use format_bytes::Message;
use format_bytes::Sink;
use format_bytes::Visit;

/// A [`Sink`] for terminals: our text is written as-is, while user data is
/// escaped so that it is readable and cannot control the terminal.
///
/// Valid UTF-8 is kept, other bytes become `\xNN`, and control characters and
/// backslashes are escaped.
pub struct Terminal<W>(pub W);

impl<W: Write> Sink for Terminal<W> {
    fn literal(&mut self, text: &str) -> io::Result<()> {
        self.0.write_all(text.as_bytes())
    }

    fn arg(
        &mut self,
        _name: ArgName,
        value: &dyn DisplayBytes,
    ) -> io::Result<()> {
        // Buffered, so that a value failing to display is written as
        // `<error>` instead of cutting the output short
        let mut escaped = Terminal(vec![]);
        match value.visit(&mut Escape(&mut escaped)) {
            Ok(()) => self.0.write_all(&escaped.0),
            Err(_) => self.0.write_all(b"<error>"),
        }
    }
}

/// Visits an argument for a [`Terminal`]
struct Escape<'a, W>(&'a mut Terminal<W>);

impl<W: Write> Visit for Escape<'_, W> {
    fn bytes(&mut self, value: &[u8]) -> io::Result<()> {
        let out = &mut self.0.0;
        for chunk in value.utf8_chunks() {
            for c in chunk.valid().chars() {
                if c.is_control() || c == '\\' {
                    write!(out, "{}", c.escape_default())?;
                } else {
                    write!(out, "{}", c)?;
                }
            }
            for byte in chunk.invalid() {
                write!(out, "\\x{:02x}", byte)?;
            }
        }
        Ok(())
    }

    fn str(&mut self, value: &str) -> io::Result<()> {
        self.bytes(value.as_bytes())
    }

    fn message(&mut self, message: &Message) -> io::Result<()> {
        message.write_to(self.0)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use format_bytes::message;

    use super::*;

    pub(crate) struct Failing;

    impl DisplayBytes for Failing {
        fn display_bytes(&self, _: &mut dyn Write) -> io::Result<()> {
            Err(io::Error::other("failing"))
        }
    }

    fn render(message: Message) -> String {
        let mut terminal = Terminal(vec![]);
        message
            .write_to(&mut terminal)
            .expect("a `Terminal` on a `Vec` cannot fail");
        String::from_utf8(terminal.0).expect("escaping makes it UTF-8")
    }

    #[test]
    fn escapes_user_data_only() {
        let path = b"caf\xe9 \xc3\xa9\\\x1b[31m\n".to_vec();
        assert_eq!(
            render(message!("{path}:\n", path = path)),
            "caf\\xe9 é\\\\\\u{1b}[31m\\n:\n"
        );
    }

    #[test]
    fn nested_messages() {
        let cause = message!("no {path}", path = b"\x1b".to_vec());
        assert_eq!(
            render(message!("cannot load\t{cause}")),
            "cannot load\tno \\u{1b}"
        );
    }

    #[test]
    fn failing_args() {
        let cause = message!("no {value}", value = Failing);
        assert_eq!(
            render(message!("{value} {cause}", value = Failing)),
            "<error> no <error>"
        );
    }
}
