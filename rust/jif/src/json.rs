//! Output for machines as JSON.

use std::io;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use format_bytes::ArgName;
use format_bytes::DisplayBytes;
use format_bytes::Message;
use format_bytes::Visit;
use serde_json::Value;
use serde_json::json;

use crate::error::CommandError;
use crate::error::ErrorKind;
use crate::error::hg_message;
use crate::terminal::Terminal;

/// An error as `{"code", "message", "context", "hint"}`, with messages as
/// written by [`message`], and context outermost first.
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
    })
}

/// A message as `{"text", "template", "args"}`, where `text` is as on a
/// terminal, and `args` maps names (or positions) to values: numbers,
/// arrays, messages, or text (which is the object `{"base64": …}` when not
/// UTF-8), and `null` when they fail to display.
pub fn message(message: &Message) -> Value {
    let mut text = Terminal(vec![]);
    message.write_to(&mut text).expect("a `Terminal` on a `Vec` cannot fail");
    let template = message.template();
    let args = template.args.iter().enumerate().map(|(index, name)| {
        let name = match name {
            ArgName::Index(index) => index.to_string(),
            ArgName::Name(name) => name.to_string(),
        };
        (name, value(message.arg(index)))
    });
    json!({
        "text": String::from_utf8(text.0).expect("escaping makes it UTF-8"),
        "template": template.source,
        "args": args.collect::<serde_json::Map<_, _>>(),
    })
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
}
