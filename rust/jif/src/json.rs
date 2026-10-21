//! Output for machines as JSON.

use std::io;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use format_bytes::ArgName;
use format_bytes::DisplayBytes;
use format_bytes::Message;
use format_bytes::Sink;
use format_bytes::Visit;
use serde_json::Map;
use serde_json::Value;
use serde_json::json;

use crate::diagnostic::Snippet;
use crate::error::CommandError;
use crate::error::ErrorKind;
use crate::error::hg_message;
use crate::terminal;
use crate::warning::Warning;

/// An error as `{"code", "message", "context", "hint", "snippets"}`, with
/// messages and snippets as written by [`message`] and [`snippet`], and context
/// outermost first.
pub fn error(error: &CommandError) -> Value {
    let message = match &error.kind {
        ErrorKind::Abort(message) => message,
        ErrorKind::Hg(error) => &hg_message(error),
    };
    let context = error.context.iter().rev().map(self::message);
    json!({
        "code": error.kind.code().as_str(),
        "message": self::message(message),
        "context": context.collect::<Vec<_>>(),
        "hint": error.hint.as_ref().map(self::message),
        "snippets": error.snippets.iter().map(snippet).collect::<Vec<_>>(),
    })
}

/// A warning as `{"message", "snippets"}`, as in [`error`].
pub fn warning(warning: &Warning) -> Value {
    json!({
        "message": message(&warning.message),
        "snippets": warning.snippets.iter().map(snippet).collect::<Vec<_>>(),
    })
}

/// A snippet as `{"origin", "source", "labels"}`, with `origin` and `source`
/// as text in [`message`], and labels as `{"start", "end", "message"}`, in
/// byte offsets into the source.
pub fn snippet(snippet: &Snippet) -> Value {
    let labels = snippet.labels.iter().map(|label| {
        json!({
            "start": label.span.start,
            "end": label.span.end,
            "message": message(&label.message),
        })
    });
    json!({
        "origin": snippet.origin.as_ref().map(|origin| value(origin)),
        "source": value(&snippet.source),
        "labels": labels.collect::<Vec<_>>(),
    })
}

/// A message as `{"text", "template", "args"}`, where `text` is as on a
/// terminal, and `args` maps names (or positions) to values: numbers,
/// arrays, messages, or text (which is the object `{"base64": …}` when not
/// UTF-8), and `null` when they fail to display.
pub fn message(message: &Message) -> Value {
    let template = message.template();
    let args = template
        .args
        .iter()
        .enumerate()
        .map(|(index, name)| (field(name), value(message.arg(index))));
    json!({
        "text": terminal::render(message),
        "template": template.source,
        "args": args.collect::<serde_json::Map<_, _>>(),
    })
}

/// The field of a record that holds its kind, named so that no argument takes
/// it
pub const KIND: &str = "_internal_jf_kind";

/// A record as an object: its kind under [`KIND`], and its arguments as
/// fields, as `args` in [`message`]. Literals are for humans only.
pub struct Record(pub Map<String, Value>);

impl Record {
    pub fn new(kind: &str) -> Self {
        Self(Map::from_iter([(KIND.into(), kind.into())]))
    }
}

impl Sink for Record {
    fn literal(&mut self, _text: &str) -> io::Result<()> {
        Ok(())
    }

    fn arg(
        &mut self,
        name: ArgName,
        value: &dyn DisplayBytes,
    ) -> io::Result<()> {
        self.0.insert(field(&name), self::value(value));
        Ok(())
    }
}

/// The name of an argument as a field: its name, or its position
fn field(name: &ArgName) -> String {
    match name {
        ArgName::Index(index) => index.to_string(),
        ArgName::Name(name) => name.to_string(),
    }
}

fn value(value: &dyn DisplayBytes) -> Value {
    let mut visitor = ToJson(Value::Null);
    match value.visit(&mut visitor) {
        Ok(()) => visitor.0,
        // So that one value failing to display does not hide the rest
        Err(_) => Value::Null,
    }
}

struct ToJson(Value);

impl Visit for ToJson {
    fn bytes(&mut self, value: &[u8]) -> io::Result<()> {
        self.0 = match std::str::from_utf8(value) {
            Ok(text) => text.into(),
            Err(_) => json!({ "base64": STANDARD.encode(value) }),
        };
        Ok(())
    }

    fn str(&mut self, value: &str) -> io::Result<()> {
        self.0 = value.into();
        Ok(())
    }

    fn int(&mut self, value: i128) -> io::Result<()> {
        self.0 = i64::try_from(value)
            .map_or_else(|_| value.to_string().into(), Value::from);
        Ok(())
    }

    fn uint(&mut self, value: u128) -> io::Result<()> {
        self.0 = u64::try_from(value)
            .map_or_else(|_| value.to_string().into(), Value::from);
        Ok(())
    }

    fn seq(
        &mut self,
        items: &[&dyn DisplayBytes],
        _separator: &dyn DisplayBytes,
    ) -> io::Result<()> {
        self.0 = items.iter().map(|item| value(*item)).collect();
        Ok(())
    }

    fn message(&mut self, message: &Message) -> io::Result<()> {
        self.0 = self::message(message);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use format_bytes::join;
    use format_bytes::message;

    use super::*;
    use crate::error::ResultExt;
    use crate::terminal::tests::Failing;

    #[test]
    fn context_outermost_first() {
        let result: Result<(), _> = Err(CommandError::abort(message!("a")));
        let error = result
            .with_context(|| message!("b"))
            .with_context(|| message!("c"))
            .unwrap_err();
        let message =
            |text| json!({ "text": text, "template": text, "args": {} });
        assert_eq!(
            super::error(&error),
            json!({
                "code": "abort",
                "message": message("a"),
                "context": [message("c"), message("b")],
                "hint": null,
                "snippets": [],
            })
        );
    }

    #[test]
    fn typed_args() {
        let rev = 42;
        let paths = join([b"a".to_vec(), b"caf\xe9".to_vec()], b", ");
        let cause = message!("no {path}", path = b"\x1b".to_vec());
        let message = message!("{rev} {paths}: {cause}");
        assert_eq!(
            super::message(&message),
            json!({
                "text": "42 a, caf\\xe9: no \\u{1b}",
                "template": "{rev} {paths}: {cause}",
                "args": {
                    "rev": 42,
                    "paths": ["a", { "base64": "Y2Fm6Q==" }],
                    "cause": {
                        "text": "no \\u{1b}",
                        "template": "no {path}",
                        "args": { "path": "\u{1b}" },
                    },
                },
            })
        );
    }

    #[test]
    fn failing_args() {
        let message = message!("{value} {rev}", value = Failing, rev = 42);
        assert_eq!(
            super::message(&message),
            json!({
                "text": "<error> 42",
                "template": "{value} {rev}",
                "args": { "value": null, "rev": 42 },
            })
        );
    }

    #[test]
    fn warnings() {
        assert_eq!(
            warning(&Warning::new(message!("a"))),
            json!({
                "message": { "text": "a", "template": "a", "args": {} },
                "snippets": [],
            })
        );
    }

    #[test]
    fn snippets() {
        let snippet = Snippet::new(b"caf\xe9".to_vec())
            .origin(b"revset".to_vec())
            .label(0..4, message!("unknown revision"));
        let error = CommandError::abort(message!("a")).with_snippet(snippet);
        assert_eq!(
            super::error(&error)["snippets"],
            json!([{
                "origin": "revset",
                "source": { "base64": "Y2Fm6Q==" },
                "labels": [{
                    "start": 0,
                    "end": 4,
                    "message": {
                        "text": "unknown revision",
                        "template": "unknown revision",
                        "args": {},
                    },
                }],
            }])
        );
    }
}
