//! Writing for humans on a terminal.

use std::io;
use std::io::Write;
use std::ops::Range;

use annotate_snippets::AnnotationKind;
use annotate_snippets::Group;
use annotate_snippets::Level;
use annotate_snippets::Renderer;
use format_bytes::ArgName;
use format_bytes::DisplayBytes;
use format_bytes::Message;
use format_bytes::Sink;
use format_bytes::Visit;

use crate::diagnostic::Snippet;

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

impl<W: Write> Terminal<W> {
    /// Writes `snippet` with its labels drawn under the source
    pub fn snippet(&mut self, snippet: &Snippet) -> io::Result<()> {
        let (source, offsets) = escape_source(&snippet.source);
        // Put guardrails against broken snippet offsets
        let at = |offset: usize| offsets[offset.min(snippet.source.len())];
        let span = |span: &Range<usize>| {
            let end = at(span.end);
            at(span.start).min(end)..end
        };
        let labels: Vec<_> =
            snippet.labels.iter().map(|label| render(&label.message)).collect();
        let annotations = snippet.labels.iter().zip(&labels).enumerate().map(
            |(index, (label, text))| {
                let kind = match index {
                    0 => AnnotationKind::Primary,
                    _ => AnnotationKind::Context,
                };
                kind.span(span(&label.span)).label(text.as_str())
            },
        );
        let origin = snippet.origin.as_ref().map(|origin| render(origin));
        let source = annotate_snippets::Snippet::source(source)
            .path(origin)
            // A large source should stay readable
            .fold(true)
            .annotations(annotations);
        // TODO add levels (warning, hint, etc.) when we introduce colors
        let report = [Group::with_level(Level::ERROR).element(source)];
        writeln!(self.0, "{}", Renderer::plain().render(&report))
    }
}

/// `source` escaped like user data, except for line breaks and tabs, with
/// where each of its bytes ends up
fn escape_source(source: &[u8]) -> (String, Vec<usize>) {
    let mut escaped = Terminal(vec![]);
    let mut offsets = Vec::with_capacity(source.len() + 1);
    let cannot_fail = "a `Terminal` on a `Vec` cannot fail";
    for chunk in source.utf8_chunks() {
        for c in chunk.valid().chars() {
            // Every byte of a character points to the start of its escape
            offsets.extend(std::iter::repeat_n(escaped.0.len(), c.len_utf8()));
            let mut buffer = [0; 4];
            let encoded = c.encode_utf8(&mut buffer);
            if matches!(c, '\n' | '\r' | '\t') {
                // Allow `annotate-snippets` to figure out lines and columns
                escaped.0.extend_from_slice(encoded.as_bytes());
            } else {
                Escape(&mut escaped).str(encoded).expect(cannot_fail);
            }
        }
        for byte in chunk.invalid() {
            offsets.push(escaped.0.len());
            Escape(&mut escaped).bytes(&[*byte]).expect(cannot_fail);
        }
    }
    offsets.push(escaped.0.len());
    let escaped =
        String::from_utf8(escaped.0).expect("escaping makes it UTF-8");
    (escaped, offsets)
}

/// `value` as a [`Terminal`] shows it, such as a whole message
pub fn render(value: &dyn DisplayBytes) -> String {
    let mut terminal = Terminal(vec![]);
    terminal
        .arg(ArgName::Index(0), value)
        .expect("a `Terminal` on a `Vec` cannot fail");
    String::from_utf8(terminal.0).expect("escaping makes it UTF-8")
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

    #[test]
    fn escapes_user_data_only() {
        let path = b"caf\xe9 \xc3\xa9\\\x1b[31m\n".to_vec();
        assert_eq!(
            render(&message!("{path}:\n", path = path)),
            "caf\\xe9 é\\\\\\u{1b}[31m\\n:\n"
        );
    }

    #[test]
    fn nested_messages() {
        let cause = message!("no {path}", path = b"\x1b".to_vec());
        assert_eq!(
            render(&message!("cannot load\t{cause}")),
            "cannot load\tno \\u{1b}"
        );
    }

    #[test]
    fn failing_args() {
        let cause = message!("no {value}", value = Failing);
        assert_eq!(
            render(&message!("{value} {cause}", value = Failing)),
            "<error> no <error>"
        );
    }

    #[test]
    fn snippets() {
        let source = b"draft()\nand caf\xe9\x1b::".to_vec();
        let snippet = Snippet::new(source)
            .origin(b"rev\x1b".to_vec())
            .label(12..17, message!("unknown revision"))
            .label(0..7, message!("some context"));
        let mut terminal = Terminal(vec![]);
        terminal.snippet(&snippet).unwrap();
        let expected = r#" --> rev\u{1b}:2:5
  |
1 | draft()
  | ------- some context
2 | and caf\xe9\u{1b}::
  |     ^^^^^^^^^^^^^ unknown revision
"#;
        assert_eq!(String::from_utf8(terminal.0).unwrap(), expected);
    }
}
