//! Pest parser for Mercurial template expressions
//!
//! This implements parsing for an incomplete subset of template expressions.
//! Remaining expressions will fall back to the Python parser.

use std::sync::LazyLock;

use itertools::Itertools as _;
use pest::Parser;
use pest::iterators::Pair;
use pest::pratt_parser::Assoc;
use pest::pratt_parser::Op;
use pest::pratt_parser::PrattParser;
use pest_derive::Parser;

/// pest parser generated from `template.pest`. The `Rule` enum used
/// throughout this module is derived from the grammar by this macro.
#[derive(Parser)]
#[grammar = "template.pest"]
pub struct TemplateParser;

/// Prefix operator applied to a single operand.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum UnaryOp {
    /// Arithmetic negation, e.g. `-rev`.
    Negate,
}

/// Infix operator applied to a left and right operand.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum BinaryOp {
    /// Member access, e.g. `a.b`.
    Dot,
    /// Filter application, e.g. `node|short`.
    Pipe,
    /// Map/format over a list, e.g. `files % "{file}\n"`.
    List,
    /// Addition.
    Add,
    /// Subtraction.
    Sub,
    /// Multiplication.
    Mul,
    /// Division.
    Div,
}

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
    /// A prefix operator applied to an operand.
    Unary(UnaryOp, Box<Node>),
    /// An infix operator applied to a left and right operand.
    Binary(BinaryOp, Box<Node>, Box<Node>),
    /// Parenthesized expression. This is needed so that `{(0)}` evaluates as
    /// `0` but `{0}` does not (it instead tries to look up a symbol named `0`).
    Group(Box<Node>),
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

pub fn parse_template(input: &[u8]) -> Result<Node, ParseError> {
    // Fast path for the majority of templates: a pure-ASCII input is valid
    // UTF-8, so we can directly call `from_utf8` and parse it. Note that
    // valid UTF-8 that is not ASCII will need to go through the slow path,
    // since the later cast `c as u8` would break otherwise. Either way, the
    // overhead is negligible compared to the cost of parsing (in Python).
    if input.is_ascii() {
        let s = std::str::from_utf8(input).expect("ASCII is valid UTF-8");
        return parse_str(s);
    }
    let chars: String = input.iter().map(|&b| b as char).collect();
    parse_str(&chars).map_err(|mut err| {
        // pest and the integer parser report byte offsets into `chars`.
        // Each input byte is exactly one char, so the input-byte offset is the
        // char count of the prefix.
        err.location = chars[..err.location].chars().count();
        err
    })
}

fn parse_str(input: &str) -> Result<Node, ParseError> {
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

/// Append the original bytes of `s` (a span that was cast from bytes to char)
/// to `out`.
fn extend_span_bytes(out: &mut Vec<u8>, s: &str) {
    out.extend(s.chars().map(|c| c as u8));
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
            Rule::text_content => extend_span_bytes(&mut out, part.as_str()),
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
                extend_span_bytes(&mut buf, inner.as_str());
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

static PRATT: LazyLock<PrattParser<Rule>> = LazyLock::new(|| {
    // In order of ascending precedence.
    PrattParser::new()
        .op(Op::infix(Rule::add_op, Assoc::Left)
            | Op::infix(Rule::sub_op, Assoc::Left))
        .op(Op::infix(Rule::mul_op, Assoc::Left)
            | Op::infix(Rule::div_op, Assoc::Left))
        .op(Op::infix(Rule::pipe_op, Assoc::Left)
            | Op::infix(Rule::list_op, Assoc::Left))
        .op(Op::infix(Rule::dot_op, Assoc::Left))
        .op(Op::prefix(Rule::negate_op))
});

fn parse_expr(pair: Pair<Rule>) -> Result<Node, ParseError> {
    debug_assert_eq!(pair.as_rule(), Rule::expr);
    PRATT
        .map_primary(parse_primary)
        .map_prefix(|op, rhs| {
            let rhs = rhs?;
            let op = match op.as_rule() {
                Rule::negate_op => UnaryOp::Negate,
                r => panic!("unexpected prefix op rule: {r:?}"),
            };
            Ok(Node::Unary(op, Box::new(rhs)))
        })
        .map_infix(|lhs, op, rhs| {
            let lhs = lhs?;
            let rhs = rhs?;
            let op = match op.as_rule() {
                Rule::dot_op => BinaryOp::Dot,
                Rule::pipe_op => BinaryOp::Pipe,
                Rule::list_op => BinaryOp::List,
                Rule::add_op => BinaryOp::Add,
                Rule::sub_op => BinaryOp::Sub,
                Rule::mul_op => BinaryOp::Mul,
                Rule::div_op => BinaryOp::Div,
                r => panic!("unexpected infix op rule: {r:?}"),
            };
            Ok(Node::Binary(op, Box::new(lhs), Box::new(rhs)))
        })
        .parse(pair.into_inner())
}

fn parse_primary(pair: Pair<Rule>) -> Result<Node, ParseError> {
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
                .map(parse_function_arg)
                .collect::<Result<Vec<_>, _>>()?;
            Ok(Node::FunctionCall { name, args })
        }
        Rule::string_literal => parse_string_literal(pair),
        Rule::paren => {
            let inner = pair
                .into_inner()
                .next()
                .expect("paren must have one inner expr");
            Ok(Node::Group(Box::new(parse_expr(inner)?)))
        }
        other => panic!("unexpected primary rule: {other:?}"),
    }
}

fn parse_function_arg(pair: Pair<Rule>) -> Result<Node, ParseError> {
    match pair.as_rule() {
        Rule::keyvalue => {
            let [key_pair, value_pair] =
                pair.into_inner().collect_array().unwrap();
            debug_assert_eq!(key_pair.as_rule(), Rule::symbol);
            let key = key_pair.as_str().to_owned();
            let value = Box::new(parse_expr(value_pair)?);
            Ok(Node::KeyValue { key, value })
        }
        Rule::expr => parse_expr(pair),
        other => panic!("unexpected function arg rule: {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_text_substitutions_and_integers() {
        assert_eq!(
            parse_template(b"hi {desc} {42}").unwrap(),
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
        assert!(parse_template(br#"{\"foo\"}"#).is_err()); // legacy escape-quoted string
        assert!(parse_template(br"a\xb").is_err()); // unrecognized escape
        assert!(parse_template(b"{}").is_err()); // empty substitution
        assert!(parse_template(b"{f(a,)}").is_err()); // trailing comma
    }

    /// Recognized backslash escapes are decoded.
    #[test]
    fn collapses_recognized_escapes() {
        assert_eq!(
            parse_template(br"a\nb").unwrap(),
            Node::Template(vec![Node::Text(b"a\nb".to_vec())]),
        );
    }

    /// Non-UTF-8 data is preserved.
    #[test]
    fn preserves_non_utf8_bytes() {
        // Plain text outside substitutions.
        assert_eq!(
            parse_template(b"a\xe9b").unwrap(),
            Node::Template(vec![Node::Text(b"a\xe9b".to_vec())]),
        );
        // Inside a string literal.
        assert_eq!(
            parse_template(b"{'\xe9'}").unwrap(),
            Node::Template(vec![Node::Template(vec![Node::Text(
                b"\xe9".to_vec(),
            )])]),
        );
    }

    /// Error locations are correct for non-UTF-8 inputs.
    #[test]
    fn error_location_is_input_byte_offset() {
        let err = parse_template(b"\xe9{}").unwrap_err();
        assert_eq!(err.location, 2);
    }

    /// Function calls with positional and keyword arguments.
    #[test]
    fn parses_function_calls() {
        assert_eq!(
            parse_template(b"{pad(text, width=10)}").unwrap(),
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
            parse_template(b"{'on branch {branch}'}").unwrap(),
            Node::Template(vec![Node::Template(vec![
                Node::Text(b"on branch ".to_vec()),
                Node::Symbol("branch".into()),
            ])]),
        );
        assert_eq!(
            parse_template(br"{r'a\nb'}").unwrap(),
            Node::Template(vec![Node::Template(vec![Node::Text(
                br"a\nb".to_vec(),
            )])]),
        );
    }

    /// Unary and binary operators with precedence/associativity.
    #[test]
    fn parses_operators() {
        // Pipe binds tighter than subtraction.
        assert_eq!(
            parse_template(b"{1 - 3 | stringify}").unwrap(),
            Node::Template(vec![Node::Binary(
                BinaryOp::Sub,
                Box::new(Node::Integer(1)),
                Box::new(Node::Binary(
                    BinaryOp::Pipe,
                    Box::new(Node::Integer(3)),
                    Box::new(Node::Symbol("stringify".into())),
                )),
            )]),
        );
        // Parens add an explicit Group wrapper.
        assert_eq!(
            parse_template(b"{(1 + 2) * 3}").unwrap(),
            Node::Template(vec![Node::Binary(
                BinaryOp::Mul,
                Box::new(Node::Group(Box::new(Node::Binary(
                    BinaryOp::Add,
                    Box::new(Node::Integer(1)),
                    Box::new(Node::Integer(2)),
                )))),
                Box::new(Node::Integer(3)),
            )]),
        );
        // Unary negate as a prefix.
        assert_eq!(
            parse_template(b"{-3}").unwrap(),
            Node::Template(vec![Node::Unary(
                UnaryOp::Negate,
                Box::new(Node::Integer(3)),
            )]),
        );
    }
}
