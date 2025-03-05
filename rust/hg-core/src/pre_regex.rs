use core::str;

use lazy_static::lazy_static;

use crate::filepatterns::PatternError;

lazy_static! {
    static ref RE_ESCAPE: Vec<Vec<u8>> = {
        let mut v: Vec<Vec<u8>> = (0..=255).map(|byte| vec![byte]).collect();
        let to_escape = b"()[]{}?*+-|^$\\.&~#\t\n\r\x0b\x0c";
        for byte in to_escape {
            v[*byte as usize].insert(0, b'\\');
        }
        v
    };
}

pub fn escape_char_for_re(c: u8) -> &'static [u8] {
    &RE_ESCAPE[c as usize]
}

/// An intermediate regular expression representation, that can be used
/// both to compile down to a `Regex` for matching, or converted to
/// a string directly for diagnostics.
#[derive(Debug, Clone)]
pub enum PreRegex {
    Empty,
    Dot,
    DotStar,
    Eof,
    NonslashStar,
    Byte(u8),
    Bytes(Vec<u8>),
    SlashOrEof,
    Re((regex_syntax::hir::Hir, Vec<u8>)),
    Maybe(Box<Self>),
    Alternation(Vec<Self>),
    Sequence(Vec<Self>),
}

mod to_hir {
    use itertools::Itertools;
    use regex_syntax::hir::{
        Class, ClassBytes, ClassBytesRange, Dot, Hir, Look, Repetition,
    };

    use super::PreRegex;

    fn hir_star(hir: Hir) -> Hir {
        Hir::repetition(Repetition {
            min: 0,
            max: None,
            greedy: false,
            sub: Box::new(hir),
        })
    }

    fn hir_eof() -> Hir {
        Hir::look(Look::End)
    }

    fn hir_nonslash() -> Hir {
        let mut class =
            Class::Bytes(ClassBytes::new([ClassBytesRange::new(b'/', b'/')]));
        Class::negate(&mut class);
        Hir::class(class)
    }

    fn hir_byte(b: u8) -> Hir {
        let class =
            Class::Bytes(ClassBytes::new([ClassBytesRange::new(b, b)]));
        Hir::class(class)
    }

    fn hir_literal(text: &[u8]) -> Hir {
        let b: Box<[u8]> = Box::from(text);
        Hir::literal(b)
    }

    pub(crate) fn to_hir(re: &PreRegex) -> regex_syntax::hir::Hir {
        match re {
            PreRegex::Empty => Hir::empty(),
            PreRegex::Dot => Hir::dot(Dot::AnyByte),
            PreRegex::DotStar => hir_star(Hir::dot(Dot::AnyByte)),
            PreRegex::Eof => hir_eof(),
            PreRegex::NonslashStar => hir_star(hir_nonslash()),
            PreRegex::Byte(b) => hir_byte(*b),
            PreRegex::Bytes(bs) => hir_literal(bs),
            PreRegex::SlashOrEof => {
                Hir::alternation(vec![hir_byte(b'/'), hir_eof()])
            }
            PreRegex::Re((hir, _)) => hir.clone(),
            PreRegex::Maybe(s) => {
                Hir::alternation(vec![Hir::empty(), s.to_hir()])
            }
            PreRegex::Alternation(alt) => {
                let alt = alt.iter().map(|r| r.to_hir()).collect_vec();
                Hir::alternation(alt)
            }
            PreRegex::Sequence(seq) => {
                let seq = seq.iter().map(|r| r.to_hir()).collect_vec();
                Hir::concat(seq)
            }
        }
    }
}

impl PreRegex {
    pub fn to_hir(&self) -> regex_syntax::hir::Hir {
        to_hir::to_hir(self)
    }

    fn to_bytes_rec(&self, out: &mut Vec<u8>) {
        match self {
            PreRegex::Empty => (),
            PreRegex::Dot => out.push(b'.'),
            PreRegex::DotStar => out.extend_from_slice(&b".*"[..]),
            PreRegex::Eof => out.push(b'$'),
            PreRegex::NonslashStar => out.extend_from_slice(&b"[^/]*"[..]),
            PreRegex::Byte(b) => out.extend_from_slice(escape_char_for_re(*b)),
            PreRegex::Bytes(bytes) => {
                for b in bytes {
                    out.extend_from_slice(escape_char_for_re(*b))
                }
            }
            PreRegex::SlashOrEof => out.extend_from_slice(&b"(?:/|$)"[..]),
            PreRegex::Re((_hir, src)) => out.extend_from_slice(src),
            PreRegex::Alternation(alt) => {
                if alt.is_empty() {
                    // something that can never match
                    out.extend_from_slice(&b" ^"[..])
                } else {
                    out.extend_from_slice(&b"(?:"[..]);
                    let mut first = true;
                    for r in alt {
                        if first {
                            first = false
                        } else {
                            out.extend_from_slice(&b"|"[..]);
                        }
                        r.to_bytes_rec(out)
                    }
                    out.extend_from_slice(&b")"[..]);
                }
            }
            PreRegex::Sequence(seq) => {
                for r in seq {
                    r.to_bytes_rec(out)
                }
            }
            PreRegex::Maybe(r) => {
                out.extend_from_slice(&b"(?:"[..]);
                r.to_bytes_rec(out);
                out.extend_from_slice(&b")?"[..]);
            }
        }
    }

    pub fn parse(re: &[u8]) -> Result<Self, PatternError> {
        let re_str = str::from_utf8(re)
            .map_err(|err| PatternError::UnsupportedSyntax(err.to_string()))?;
        Ok(Self::Re((
            regex_syntax::parse(re_str).map_err(|err| {
                PatternError::UnsupportedSyntax(err.to_string())
            })?,
            re.to_vec(),
        )))
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = vec![];
        self.to_bytes_rec(&mut out);
        out
    }

    pub fn literal(prefix: &[u8]) -> PreRegex {
        Self::Bytes(prefix.to_vec())
    }

    pub fn preceding_dir_components() -> Self {
        Self::Maybe(Box::new(Self::Sequence(vec![
            Self::DotStar,
            Self::Byte(b'/'),
        ])))
    }
}
