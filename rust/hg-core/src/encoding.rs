//! Character transcoding support.

use core::str;
use std::borrow::Cow;
use std::ffi::OsString;

use unicode_width::UnicodeWidthStr as _;

use crate::errors::HgBacktrace;
use crate::errors::HgError;

/// The different ways setting up or using an [`Encoder`] can fail
#[derive(Debug, PartialEq)]
pub enum EncodingErrorKind {
    /// This value for `HGENCODING` is not supported by the Rust code
    UnsupportedEncoding(OsString),
    /// This value for `HGENCODINGMODE` is not supported
    UnsupportedMode(OsString),
    /// This value for `HGENCODINGAMBIGUOUS` is not supported
    UnsupportedAmbiguousWidth(OsString),
    /// These bytes are not valid UTF-8
    InvalidUtf8 {
        bytes: Vec<u8>,
        /// See [`std::str::Utf8Error::valid_up_to`]
        valid_up_to: usize,
    },
    /// These bytes are not valid ASCII
    InvalidAscii { bytes: Vec<u8> },
}

/// An error that happened when setting up or using an [`Encoder`]
#[derive(Debug, PartialEq)]
pub struct EncodingError {
    pub kind: EncodingErrorKind,
    pub backtrace: HgBacktrace,
}

impl From<EncodingErrorKind> for EncodingError {
    fn from(kind: EncodingErrorKind) -> Self {
        Self { kind, backtrace: HgBacktrace::capture() }
    }
}

impl From<EncodingErrorKind> for HgError {
    fn from(kind: EncodingErrorKind) -> Self {
        EncodingError::from(kind).into()
    }
}

/// String encoder and decoder.
#[derive(Copy, Clone, Debug)]
pub struct Encoder {
    /// The user's local encoding.
    local_encoding: Encoding,
    /// What to do when decoding fails. (Encoding always uses
    /// `Mode::Replace`).
    decoding_mode: Mode,
    /// Width to use for characters that can be interpreted either as narrow
    /// or wide depending on the context.
    pub ambiguous_width: Width,
}

/// Character encoding.
#[derive(Copy, Clone, Debug)]
pub enum Encoding {
    Utf8,
    Ascii,
}

/// Character decoding mode.
#[derive(Copy, Clone, Debug)]
pub enum Mode {
    /// Produce an error message for invalid characters.
    Strict,
    /// Replace invalid characters with a special character.
    Replace,
}

/// The width of a Unicode character.
#[derive(Copy, Clone, Debug)]
pub enum Width {
    /// Narrow, taking up 1 terminal column.
    Narrow,
    /// Wide, taking up 2 terminal columns.
    Wide,
}

impl Default for Encoder {
    fn default() -> Self {
        Self {
            local_encoding: Encoding::Utf8,
            decoding_mode: Mode::Strict,
            ambiguous_width: Width::Narrow,
        }
    }
}

impl Encoder {
    /// Creates an encoder from environment variables.
    pub fn from_env() -> Result<Self, HgError> {
        let default = Encoder::default();
        let local_encoding = match std::env::var_os("HGENCODING") {
            None => default.local_encoding,
            Some(s)
                if s.eq_ignore_ascii_case("utf-8")
                    || s.eq_ignore_ascii_case("utf8") =>
            {
                Encoding::Utf8
            }
            Some(s) if s.eq_ignore_ascii_case("ascii") => Encoding::Ascii,
            Some(s) => {
                return Err(EncodingErrorKind::UnsupportedEncoding(s).into());
            }
        };
        let decoding_mode = match std::env::var_os("HGENCODINGMODE") {
            None => default.decoding_mode,
            Some(s) if s == "strict" => Mode::Strict,
            Some(s) if s == "replace" => Mode::Replace,
            Some(s) => {
                return Err(EncodingErrorKind::UnsupportedMode(s).into());
            }
        };
        let ambiguous_width = match std::env::var_os("HGENCODINGAMBIGUOUS") {
            None => default.ambiguous_width,
            Some(s) if s == "narrow" => Width::Narrow,
            Some(s) if s == "wide" => Width::Wide,
            Some(s) => {
                return Err(
                    EncodingErrorKind::UnsupportedAmbiguousWidth(s).into()
                );
            }
        };
        Ok(Self { local_encoding, decoding_mode, ambiguous_width })
    }

    /// Decodes an internal UTF-8 string from bytes.
    pub fn decode_internal<'a>(
        &self,
        bytes: &'a [u8],
    ) -> Result<&'a str, HgError> {
        Ok(decode_utf8(bytes)?)
    }

    /// Converts a string from internal UTF-8 to the local character encoding.
    pub fn to_local<'a>(&self, str: &'a str) -> Cow<'a, [u8]> {
        match self.local_encoding {
            Encoding::Utf8 => Cow::Borrowed(str.as_bytes()),
            Encoding::Ascii => {
                if str.is_ascii() {
                    Cow::Borrowed(str.as_bytes())
                } else {
                    Cow::Owned(codepoints_to_ascii_lossy(str).into_bytes())
                }
            }
        }
    }

    /// Converts a string from the local character encoding to UTF-8.
    pub fn from_local<'a>(
        &self,
        bytes: &'a [u8],
    ) -> Result<Cow<'a, str>, HgError> {
        match (self.local_encoding, self.decoding_mode) {
            (Encoding::Utf8, Mode::Strict) => {
                Ok(Cow::Borrowed(decode_utf8(bytes)?))
            }
            (Encoding::Utf8, Mode::Replace) => {
                Ok(String::from_utf8_lossy(bytes))
            }
            (Encoding::Ascii, Mode::Strict) => {
                Ok(Cow::Borrowed(decode_ascii(bytes)?))
            }
            (Encoding::Ascii, Mode::Replace) => {
                Ok(Cow::Owned(bytes_to_ascii_lossy(bytes)))
            }
        }
    }

    /// Returns the column width of a string for display.
    pub fn column_width(&self, str: &str) -> usize {
        match self.ambiguous_width {
            Width::Narrow => str.width(),
            Width::Wide => str.width_cjk(),
        }
    }

    /// Returns the column width if `bytes` can be decoded as UTF-8, otherwise
    /// just returns the length in bytes.
    pub fn column_width_bytes(&self, bytes: &[u8]) -> usize {
        match str::from_utf8(bytes) {
            Ok(str) => self.column_width(str),
            Err(_) => bytes.len(),
        }
    }
}

/// Decodes bytes as UTF-8 or returns a detailed error.
fn decode_utf8(bytes: &[u8]) -> Result<&str, EncodingError> {
    str::from_utf8(bytes).map_err(|err| {
        EncodingErrorKind::InvalidUtf8 {
            bytes: bytes.to_vec(),
            valid_up_to: err.valid_up_to(),
        }
        .into()
    })
}

/// Decodes bytes as ASCII or returns a detailed error.
fn decode_ascii(bytes: &[u8]) -> Result<&str, EncodingError> {
    // TODO: Use `as_ascii` https://github.com/rust-lang/rust/issues/110998
    if bytes.is_ascii() {
        // Safety: Just checked that it's ASCII.
        let str = unsafe { str::from_utf8_unchecked(bytes) };
        Ok(str)
    } else {
        Err(EncodingErrorKind::InvalidAscii { bytes: bytes.to_vec() }.into())
    }
}

/// Replaces all non-ASCII codepoints with '?'.
fn codepoints_to_ascii_lossy(str: &str) -> String {
    let mut ascii = String::new();
    for char in str.chars() {
        ascii.push(if char.is_ascii() { char } else { '?' });
    }
    ascii
}

/// Replaces all non-ASCII bytes with '?'.
fn bytes_to_ascii_lossy(bytes: &[u8]) -> String {
    let mut ascii = String::new();
    for &b in bytes {
        ascii.push(if b.is_ascii() { b as char } else { '?' });
    }
    ascii
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_decode_internal() {
        let encoder = Encoder::default();
        assert_eq!(encoder.decode_internal(b"").unwrap(), "");
        assert_eq!(encoder.decode_internal(b"\xc3\xa9").unwrap(), "é");
        match encoder.decode_internal(b"A\xc3") {
            Ok(_) => panic!("expected an error"),
            Err(err) => {
                assert_eq!(
                    err.to_string(),
                    "invalid UTF-8 at offset 1: \"A\\xc3\""
                );
                let HgError::Encoding(err) = err else {
                    panic!("expected an Encoding error")
                };
                assert_eq!(
                    err.kind,
                    EncodingErrorKind::InvalidUtf8 {
                        bytes: b"A\xc3".to_vec(),
                        valid_up_to: 1
                    }
                )
            }
        }
    }

    #[test]
    fn test_to_local() {
        let encoder = Encoder::default();
        assert_eq!(encoder.to_local("").as_ref(), b"");
        assert_eq!(encoder.to_local("é").as_ref(), b"\xc3\xa9");
    }

    #[test]
    fn test_from_local() {
        let encoder = Encoder::default();
        assert_eq!(encoder.from_local(b"").unwrap(), "");
        assert_eq!(encoder.from_local(b"\xc3\xa9").unwrap(), "é");
        match encoder.from_local(b"A\xc3") {
            Ok(_) => panic!("expected an error"),
            Err(err) => {
                assert_eq!(
                    err.to_string(),
                    "invalid UTF-8 at offset 1: \"A\\xc3\""
                );
                assert!(matches!(
                    err,
                    HgError::Encoding(EncodingError {
                        kind: EncodingErrorKind::InvalidUtf8 { .. },
                        ..
                    })
                ));
            }
        }
    }

    #[test]
    fn test_from_local_replace() {
        let encoder =
            Encoder { decoding_mode: Mode::Replace, ..Default::default() };
        assert_eq!(encoder.from_local(b"A\xc3").unwrap(), "A\u{fffd}");
    }

    #[test]
    fn test_column_width() {
        let encoder = Encoder::default();
        assert_eq!(encoder.column_width(""), 0);
        assert_eq!(encoder.column_width("a"), 1);
        assert_eq!(encoder.column_width("ab"), 2);
        assert_eq!(encoder.column_width("été"), 3);
        assert_eq!(encoder.column_width("\u{1f496}"), 2);
    }

    #[test]
    fn test_column_width_ambiguous() {
        let narrow_encoder =
            Encoder { ambiguous_width: Width::Narrow, ..Default::default() };
        assert_eq!(narrow_encoder.column_width("\u{2606}"), 1);

        let wide_encoder =
            Encoder { ambiguous_width: Width::Wide, ..Default::default() };
        assert_eq!(wide_encoder.column_width("\u{2606}"), 2);
    }

    #[test]
    fn test_column_width_bytes() {
        let encoder = Encoder::default();
        assert_eq!(encoder.column_width_bytes(b""), 0);
        assert_eq!(encoder.column_width_bytes("été".as_bytes()), 3);
        assert_eq!(encoder.column_width_bytes(b"A\xc3"), 2);
    }
}
