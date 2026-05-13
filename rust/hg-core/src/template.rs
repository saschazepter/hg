//! Pest parser for Mercurial template expressions
//!
//! This implements parsing for an incomplete subset of template expressions.
//! Remaining expressions will fall back to the Python parser.

use itertools::Itertools as _;
use pest::Parser;
use pest::iterators::Pair;
use pest_derive::Parser;

/// pest parser generated from `template.pest`. The `Rule` enum used
/// throughout this module is derived from the grammar by this macro.
#[derive(Parser)]
#[grammar = "template.pest"]
pub struct TemplateParser;

/// A node in the parsed template syntax tree.
#[derive(Debug, PartialEq, Eq, Clone)]
pub enum Node {
    /// An integer literal, e.g. `42`.
    Integer(i64),
    /// A bare symbol (keyword or function name), e.g. `rev`.
    Symbol(String),
    /// Literal bytes of plain text or string-literal content.
    Text(Vec<u8>),
    /// An ordered sequence of nodes: the whole template, or the pieces of a
    /// string literal that mixes text and substitutions.
    Template(Vec<Node>),
    /// A function call, e.g. `pad(text, width=10)`.
    FunctionCall {
        /// The function name.
        name: String,
        /// The positional and keyword arguments, in source order.
        args: Vec<Node>,
    },
    /// A `key=value` argument inside a function call.
    KeyValue {
        /// The argument name.
        key: String,
        /// The argument value.
        value: Box<Node>,
    },
}

/// An error produced while parsing a template.
#[derive(Debug)]
pub struct ParseError {
    /// Human-readable description of the failure.
    pub message: String,
    /// Byte offset into the original template input where the error occurred.
    pub location: usize,
}

impl From<pest::error::Error<Rule>> for ParseError {
    fn from(err: pest::error::Error<Rule>) -> Self {
        let location = match err.location {
            pest::error::InputLocation::Pos(p) => p,
            pest::error::InputLocation::Span((s, _)) => s,
        };
        ParseError { message: err.variant.message().into_owned(), location }
    }
}

pub fn parse_template(input: &str) -> Result<Node, ParseError> {
    let mut pairs = TemplateParser::parse(Rule::template, input)?;
    let pair = pairs.next().expect("pest template always produces one pair");
    let chunks = pair
        .into_inner()
        .filter(|p| p.as_rule() != Rule::EOI)
        .map(parse_chunk)
        .collect::<Result<Vec<_>, _>>()?;
    let node = Node::Template(chunks);
    tracing::debug!(output = ?node, "template::parse_template output");
    Ok(node)
}

fn parse_chunk(pair: Pair<Rule>) -> Result<Node, ParseError> {
    match pair.as_rule() {
        Rule::text => Ok(Node::Text(parse_text(pair))),
        Rule::substitution => parse_substitution(pair),
        other => panic!("unexpected chunk rule: {other:?}"),
    }
}

fn parse_substitution(pair: Pair<Rule>) -> Result<Node, ParseError> {
    debug_assert_eq!(pair.as_rule(), Rule::substitution);
    let inner = pair
        .into_inner()
        .next()
        .expect("substitution always contains one expression");
    parse_expr(inner)
}

fn parse_text(pair: Pair<Rule>) -> Vec<u8> {
    let mut out = Vec::with_capacity(pair.as_str().len());
    for part in pair.into_inner() {
        match part.as_rule() {
            Rule::text_content => {
                out.extend_from_slice(part.as_str().as_bytes())
            }
            Rule::text_escape => out.push(escape_byte(part.as_str())),
            other => panic!("unexpected text part: {other:?}"),
        }
    }
    out
}

fn escape_byte(s: &str) -> u8 {
    let bytes = s.as_bytes();
    debug_assert_eq!(bytes.len(), 2);
    debug_assert_eq!(bytes[0], b'\\');
    match bytes[1] {
        b't' => b'\t',
        b'r' => b'\r',
        b'n' => b'\n',
        b'0' => b'\0',
        b'\\' => b'\\',
        b'\'' => b'\'',
        b'"' => b'"',
        b'{' => b'{',
        other => panic!(r"unexpected escape: \{}", other as char),
    }
}

fn parse_string_literal(pair: Pair<Rule>) -> Result<Node, ParseError> {
    debug_assert_eq!(pair.as_rule(), Rule::string_literal);
    let mut chunks = Vec::new();
    let mut buf: Vec<u8> = Vec::new();
    for inner in pair.into_inner() {
        match inner.as_rule() {
            Rule::string_content | Rule::raw_string_content => {
                buf.extend_from_slice(inner.as_str().as_bytes());
            }
            Rule::text_escape => buf.push(escape_byte(inner.as_str())),
            Rule::substitution => {
                if !buf.is_empty() {
                    chunks.push(Node::Text(std::mem::take(&mut buf)));
                }
                chunks.push(parse_substitution(inner)?);
            }
            other => panic!("unexpected string chunk: {other:?}"),
        }
    }
    if !buf.is_empty() {
        chunks.push(Node::Text(buf));
    }
    Ok(Node::Template(chunks))
}

fn parse_expr(pair: Pair<Rule>) -> Result<Node, ParseError> {
    match pair.as_rule() {
        Rule::integer => {
            let location = pair.as_span().start();
            pair.as_str()
                .parse::<i64>()
                .map(Node::Integer)
                .map_err(|e| ParseError { message: e.to_string(), location })
        }
        Rule::symbol => Ok(Node::Symbol(pair.as_str().to_owned())),
        Rule::function => {
            let [name_pair, args_pair] =
                pair.into_inner().collect_array().unwrap();
            debug_assert_eq!(name_pair.as_rule(), Rule::symbol);
            debug_assert_eq!(args_pair.as_rule(), Rule::function_args);
            let name = name_pair.as_str().to_owned();
            let args = args_pair
                .into_inner()
                .map(parse_expr)
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Node::FunctionCall { name, args })
        }
        Rule::string_literal => parse_string_literal(pair),
        Rule::keyvalue => {
            let [key_pair, value_pair] =
                pair.into_inner().collect_array().unwrap();
            debug_assert_eq!(key_pair.as_rule(), Rule::symbol);
            let key = key_pair.as_str().to_owned();
            let value = Box::new(parse_expr(value_pair)?);
            Ok(Node::KeyValue { key, value })
        }
        other => panic!("unexpected expression rule: {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_text_substitutions_and_integers() {
        assert_eq!(
            parse_template("hi {desc} {42}").unwrap(),
            Node::Template(vec![
                Node::Text(b"hi ".to_vec()),
                Node::Symbol("desc".into()),
                Node::Text(b" ".to_vec()),
                Node::Integer(42),
            ]),
        );
    }

    #[test]
    fn rejects_unsupported() {
        assert!(parse_template("{desc|short}").is_err());
        assert!(parse_template(r"a\xb").is_err()); // unrecognized escape
        assert!(parse_template("{}").is_err()); // empty substitution
        assert!(parse_template("{f(a,)}").is_err()); // trailing comma
    }

    /// Recognized backslash escapes are decoded.
    #[test]
    fn collapses_recognized_escapes() {
        assert_eq!(
            parse_template(r"a\nb").unwrap(),
            Node::Template(vec![Node::Text(b"a\nb".to_vec())]),
        );
    }

    /// Function calls with positional and keyword arguments.
    #[test]
    fn parses_function_calls() {
        assert_eq!(
            parse_template("{pad(text, width=10)}").unwrap(),
            Node::Template(vec![Node::FunctionCall {
                name: "pad".into(),
                args: vec![
                    Node::Symbol("text".into()),
                    Node::KeyValue {
                        key: "width".into(),
                        value: Box::new(Node::Integer(10)),
                    },
                ],
            }]),
        );
    }

    /// String literals (including raw strings and embedded substitutions).
    #[test]
    fn parses_string_literals() {
        assert_eq!(
            parse_template("{'on branch {branch}'}").unwrap(),
            Node::Template(vec![Node::Template(vec![
                Node::Text(b"on branch ".to_vec()),
                Node::Symbol("branch".into()),
            ])]),
        );
        assert_eq!(
            parse_template(r"{r'a\nb'}").unwrap(),
            Node::Template(vec![Node::Template(vec![Node::Text(
                br"a\nb".to_vec(),
            )])]),
        );
    }
}
