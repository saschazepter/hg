//! Contains string-related utilities.

use std::cell::Cell;
use std::fmt;
use std::io::Write as _;
use std::ops::Deref as _;

use crate::utils::hg_path::HgPath;

/// Useful until rust/issues/56345 is stable
///
/// # Examples
///
/// ```
/// use hg::utils::strings::find_slice_in_slice;
///
/// let haystack = b"This is the haystack".to_vec();
/// assert_eq!(find_slice_in_slice(&haystack, b"the"), Some(8));
/// assert_eq!(find_slice_in_slice(&haystack, b"not here"), None);
/// ```
pub fn find_slice_in_slice<T>(slice: &[T], needle: &[T]) -> Option<usize>
where
    for<'a> &'a [T]: PartialEq,
{
    slice.windows(needle.len()).position(|window| window == needle)
}

/// Replaces the `from` slice with the `to` slice inside the `buf` slice.
/// `from` and `to` need to be of the exact same length, otherwise use
/// [`replace_slice`].
///
/// # Panics
///
/// Panics if `from` and `to` have different lengths.
///
/// # Examples
///
/// ```
/// use hg::utils::strings::replace_slice_exact;
///
/// let mut line = b"I hate writing tests!".to_vec();
/// replace_slice_exact(&mut line, b"hate", b"love");
///
/// assert_eq!(
///     line,
///     b"I love writing tests!".to_vec()
/// );
/// ```
///
/// ```should_panic
/// use hg::utils::strings::replace_slice_exact;
///
/// let mut line = b"I hate writing tests!".to_vec();
/// replace_slice_exact(&mut line, b"hate", b"enjoy");
/// ```
pub fn replace_slice_exact<T>(buf: &mut [T], from: &[T], to: &[T])
where
    T: Clone + PartialEq,
{
    assert_eq!(from.len(), to.len());
    for i in 0..=buf.len() - from.len() {
        if buf[i..].starts_with(from) {
            buf[i..(i + from.len())].clone_from_slice(to);
        }
    }
}

/// Replaces every `from` slice with the `to` slice from `source` and returns
/// a [`Vec`].
/// For cases where `from` and `to` are the same length, use
/// [`replace_slice_exact`] for better performance.
///
/// # Examples
///
/// ```
/// use hg::utils::strings::replace_slice;
///
/// let line = b"I hate writing tests!".to_vec();
/// assert_eq!(
///     replace_slice(&line, b"hate", b"love"),
///     b"I love writing tests!".to_vec()
/// );
/// let line = b"I hate writing tests!".to_vec();
/// assert_eq!(
///     replace_slice(&line, b"hate", b"enjoy"),
///     b"I enjoy writing tests!".to_vec()
/// );
/// let line = b"I hate writing tests!".to_vec();
/// assert_eq!(
///     replace_slice(&line, b"hate", b"am"),
///     b"I am writing tests!".to_vec()
/// );
/// ```
pub fn replace_slice<T>(source: &[T], from: &[T], to: &[T]) -> Vec<T>
where
    T: Clone + PartialEq,
{
    let mut result = source.to_vec();
    let from_len = from.len();
    let to_len = to.len();

    let mut i = 0;
    while i + from_len <= result.len() {
        if result[i..].starts_with(from) {
            result.splice(i..i + from_len, to.iter().cloned());
            i += to_len;
        } else {
            i += 1;
        }
    }

    result
}

pub trait SliceExt {
    fn trim_end(&self) -> &Self;
    fn trim_start(&self) -> &Self;
    fn trim_end_matches(&self, f: impl FnMut(u8) -> bool) -> &Self;
    fn trim_start_matches(&self, f: impl FnMut(u8) -> bool) -> &Self;
    fn trim(&self) -> &Self;
    fn drop_prefix(&self, needle: &Self) -> Option<&Self>;
    fn split_2(&self, separator: u8) -> Option<(&[u8], &[u8])>;
    fn split_2_by_slice(&self, separator: &[u8]) -> Option<(&[u8], &[u8])>;
    fn to_hex_bytes(&self) -> Vec<u8>;
}

impl SliceExt for [u8] {
    fn trim_end(&self) -> &[u8] {
        self.trim_end_matches(|byte| byte.is_ascii_whitespace())
    }

    fn trim_start(&self) -> &[u8] {
        self.trim_start_matches(|byte| byte.is_ascii_whitespace())
    }

    fn trim_end_matches(&self, mut f: impl FnMut(u8) -> bool) -> &Self {
        if let Some(last) = self.iter().rposition(|&byte| !f(byte)) {
            &self[..=last]
        } else {
            &[]
        }
    }

    fn trim_start_matches(&self, mut f: impl FnMut(u8) -> bool) -> &Self {
        if let Some(first) = self.iter().position(|&byte| !f(byte)) {
            &self[first..]
        } else {
            &[]
        }
    }

    /// ```
    /// use hg::utils::strings::SliceExt;
    /// assert_eq!(
    ///     b"  to trim  ".trim(),
    ///     b"to trim"
    /// );
    /// assert_eq!(
    ///     b"to trim  ".trim(),
    ///     b"to trim"
    /// );
    /// assert_eq!(
    ///     b"  to trim".trim(),
    ///     b"to trim"
    /// );
    /// ```
    fn trim(&self) -> &[u8] {
        self.trim_start().trim_end()
    }

    fn drop_prefix(&self, needle: &Self) -> Option<&Self> {
        if self.starts_with(needle) {
            Some(&self[needle.len()..])
        } else {
            None
        }
    }

    fn split_2(&self, separator: u8) -> Option<(&[u8], &[u8])> {
        let pos = memchr::memchr(separator, self)?;
        Some((&self[..pos], &self[pos + 1..]))
    }

    fn split_2_by_slice(&self, separator: &[u8]) -> Option<(&[u8], &[u8])> {
        find_slice_in_slice(self, separator)
            .map(|pos| (&self[..pos], &self[pos + separator.len()..]))
    }

    fn to_hex_bytes(&self) -> Vec<u8> {
        let mut hex = Vec::with_capacity(self.len() * 2);
        for byte in self {
            write!(hex, "{:02x}", byte).unwrap();
        }
        hex
    }
}

pub trait Escaped {
    /// Return bytes escaped for display to the user
    fn escaped_bytes(&self) -> Vec<u8>;
}

impl Escaped for u8 {
    fn escaped_bytes(&self) -> Vec<u8> {
        let mut acc = vec![];
        match self {
            c @ b'\'' | c @ b'\\' => {
                acc.push(b'\\');
                acc.push(*c);
            }
            b'\t' => {
                acc.extend(br"\\t");
            }
            b'\n' => {
                acc.extend(br"\\n");
            }
            b'\r' => {
                acc.extend(br"\\r");
            }
            c if (*c < b' ' || *c >= 127) => {
                write!(acc, "\\x{:x}", self).unwrap();
            }
            c => {
                acc.push(*c);
            }
        }
        acc
    }
}

impl<T: Escaped> Escaped for &[T] {
    fn escaped_bytes(&self) -> Vec<u8> {
        self.iter().flat_map(Escaped::escaped_bytes).collect()
    }
}

impl<T: Escaped> Escaped for Vec<T> {
    fn escaped_bytes(&self) -> Vec<u8> {
        self.deref().escaped_bytes()
    }
}

impl Escaped for &HgPath {
    fn escaped_bytes(&self) -> Vec<u8> {
        self.as_bytes().escaped_bytes()
    }
}

#[cfg(unix)]
pub fn shell_quote(value: &[u8]) -> Vec<u8> {
    if value.iter().all(|&byte| {
        matches!(
            byte,
            b'a'..=b'z'
            | b'A'..=b'Z'
            | b'0'..=b'9'
            | b'.'
            | b'_'
            | b'/'
            | b'+'
            | b'-'
        )
    }) {
        value.to_owned()
    } else {
        let mut quoted = Vec::with_capacity(value.len() + 2);
        quoted.push(b'\'');
        for &byte in value {
            if byte == b'\'' {
                quoted.push(b'\\');
            }
            quoted.push(byte);
        }
        quoted.push(b'\'');
        quoted
    }
}

/// Expand `$FOO` and `${FOO}` environment variables in the given byte string
pub fn expand_vars(s: &[u8]) -> std::borrow::Cow<[u8]> {
    lazy_static::lazy_static! {
        /// https://github.com/python/cpython/blob/3.9/Lib/posixpath.py#L301
        /// The `x` makes whitespace ignored.
        /// `-u` disables the Unicode flag, which makes `\w` like Python with the ASCII flag.
        static ref VAR_RE: regex::bytes::Regex =
            regex::bytes::Regex::new(r"(?x-u)
                \$
                (?:
                    (\w+)
                    |
                    \{
                        ([^}]*)
                    \}
                )
            ").unwrap();
    }
    VAR_RE.replace_all(s, |captures: &regex::bytes::Captures| {
        let var_name = crate::utils::files::get_os_str_from_bytes(
            captures
                .get(1)
                .or_else(|| captures.get(2))
                .expect("either side of `|` must participate in match")
                .as_bytes(),
        );
        std::env::var_os(var_name)
            .map(crate::utils::files::get_bytes_from_os_str)
            .unwrap_or_else(|| {
                // Referencing an environment variable that does not exist.
                // Leave the $FOO reference as-is.
                captures[0].to_owned()
            })
    })
}

/// Join items of the iterable with the given separator, similar to Python’s
/// `separator.join(iter)`.
///
/// Formatting the return value consumes the iterator.
/// Formatting it again will produce an empty string.
pub fn join_display(
    iter: impl IntoIterator<Item = impl fmt::Display>,
    separator: impl fmt::Display,
) -> impl fmt::Display {
    JoinDisplay { iter: Cell::new(Some(iter.into_iter())), separator }
}

struct JoinDisplay<I, S> {
    iter: Cell<Option<I>>,
    separator: S,
}

impl<I, T, S> fmt::Display for JoinDisplay<I, S>
where
    I: Iterator<Item = T>,
    T: fmt::Display,
    S: fmt::Display,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(mut iter) = self.iter.take() {
            if let Some(first) = iter.next() {
                first.fmt(f)?;
            }
            for value in iter {
                self.separator.fmt(f)?;
                value.fmt(f)?;
            }
        }
        Ok(())
    }
}

/// Returns a short representation of a user name or email address.
pub fn short_user(user: &[u8]) -> &[u8] {
    let mut str = user;
    if let Some(i) = memchr::memchr(b'@', str) {
        str = &str[..i];
    }
    if let Some(i) = memchr::memchr(b'<', str) {
        str = &str[i + 1..];
    }
    if let Some(i) = memchr::memchr(b' ', str) {
        str = &str[..i];
    }
    if let Some(i) = memchr::memchr(b'.', str) {
        str = &str[..i];
    }
    str
}

/// Options for [`clean_whitespace`].
#[derive(Copy, Clone)]
pub enum CleanWhitespace {
    /// Remove whitespace at ends of lines.
    AtEol,
    /// Collapse consecutive whitespace characters into a single space.
    Collapse,
    /// Remove all whitespace characters.
    All,
}

/// Normalizes whitespace in text so that it won't apppear in diffs.
pub fn clean_whitespace(text: &mut Vec<u8>, how: CleanWhitespace) {
    // We copy text[i] to text[w], where w advances more slowly than i.
    let mut w = 0;
    match how {
        // To match wsclean in mdiff.py, this removes "\f" (0xC).
        CleanWhitespace::AtEol => {
            let mut newline_dest = 0;
            for i in 0..text.len() {
                let char = text[i];
                match char {
                    b' ' | b'\t' | b'\r' | 0xC => {}
                    _ => {
                        if char == b'\n' {
                            w = newline_dest;
                        }
                        newline_dest = w + 1;
                    }
                }
                text[w] = char;
                w += 1;
            }
        }
        // To match fixws in cext/bdiff.c, CleanWhitespace::Collapse and
        // CleanWhitespace::All do *not* remove "\f".
        CleanWhitespace::Collapse => {
            for i in 0..text.len() {
                match text[i] {
                    b' ' | b'\t' | b'\r' => {
                        if w == 0 || text[w - 1] != b' ' {
                            text[w] = b' ';
                            w += 1;
                        }
                    }
                    b'\n' if w > 0 && text[w - 1] == b' ' => {
                        text[w - 1] = b'\n';
                    }
                    char => {
                        text[w] = char;
                        w += 1;
                    }
                }
            }
        }
        CleanWhitespace::All => {
            for i in 0..text.len() {
                match text[i] {
                    b' ' | b'\t' | b'\r' => {}
                    char => {
                        text[w] = char;
                        w += 1;
                    }
                }
            }
        }
    }
    text.truncate(w);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expand_vars() {
        // Modifying process-global state in a test isn’t great,
        // but hopefully this won’t collide with anything.
        unsafe { std::env::set_var("TEST_EXPAND_VAR", "1") };
        assert_eq!(
            expand_vars(b"before/$TEST_EXPAND_VAR/after"),
            &b"before/1/after"[..]
        );
        assert_eq!(
        expand_vars(b"before${TEST_EXPAND_VAR}${TEST_EXPAND_VAR}${TEST_EXPAND_VAR}after"),
        &b"before111after"[..]
    );
        let s = b"before $SOME_LONG_NAME_THAT_WE_ASSUME_IS_NOT_AN_ACTUAL_ENV_VAR after";
        assert_eq!(expand_vars(s), &s[..]);
    }

    #[test]
    fn test_short_user() {
        assert_eq!(short_user(b""), b"");
        assert_eq!(short_user(b"Name"), b"Name");
        assert_eq!(short_user(b"First Last"), b"First");
        assert_eq!(short_user(b"First Last <user@example.com>"), b"user");
        assert_eq!(short_user(b"First Last <user.name@example.com>"), b"user");
    }

    fn clean_ws(text: &[u8], how: CleanWhitespace) -> Vec<u8> {
        let mut vec = text.to_vec();
        clean_whitespace(&mut vec, how);
        vec
    }

    #[test]
    fn test_clean_whitespace_at_eol() {
        // To match wsclean in mdiff.py, CleanWhitespace::AtEol only removes
        // the final line's trailing whitespace if it ends in \n.
        use CleanWhitespace::AtEol;
        assert_eq!(clean_ws(b"", AtEol), b"");
        assert_eq!(clean_ws(b" ", AtEol), b" ");
        assert_eq!(clean_ws(b"  ", AtEol), b"  ");
        assert_eq!(clean_ws(b"A", AtEol), b"A");
        assert_eq!(clean_ws(b"\n\n\n", AtEol), b"\n\n\n");
        assert_eq!(clean_ws(b" \n", AtEol), b"\n");
        assert_eq!(clean_ws(b"A \n", AtEol), b"A\n");
        assert_eq!(clean_ws(b"A B  C\t\r\n", AtEol), b"A B  C\n");
        assert_eq!(clean_ws(b"A \tB  C\r\nD  ", AtEol), b"A \tB  C\nD  ");
        assert_eq!(clean_ws(b"A\x0CB\x0C\n", AtEol), b"A\x0CB\n");
    }

    #[test]
    fn test_clean_whitespace_collapse() {
        use CleanWhitespace::Collapse;
        assert_eq!(clean_ws(b"", Collapse), b"");
        assert_eq!(clean_ws(b" ", Collapse), b" ");
        assert_eq!(clean_ws(b"  ", Collapse), b" ");
        assert_eq!(clean_ws(b"A", Collapse), b"A");
        assert_eq!(clean_ws(b"\n\n\n", Collapse), b"\n\n\n");
        assert_eq!(clean_ws(b" \n", Collapse), b"\n");
        assert_eq!(clean_ws(b"A \n", Collapse), b"A\n");
        assert_eq!(clean_ws(b"A B  C\t\r\n", Collapse), b"A B C\n");
        assert_eq!(clean_ws(b"A \tB  C\r\nD  ", Collapse), b"A B C\nD ");
        assert_eq!(clean_ws(b"A\x0CB\x0C\n", Collapse), b"A\x0CB\x0C\n");
    }

    #[test]
    fn test_clean_whitespace_all() {
        use CleanWhitespace::All;
        assert_eq!(clean_ws(b"", All), b"");
        assert_eq!(clean_ws(b" ", All), b"");
        assert_eq!(clean_ws(b"  ", All), b"");
        assert_eq!(clean_ws(b"A", All), b"A");
        assert_eq!(clean_ws(b"\n\n\n", All), b"\n\n\n");
        assert_eq!(clean_ws(b" \n", All), b"\n");
        assert_eq!(clean_ws(b"A \n", All), b"A\n");
        assert_eq!(clean_ws(b"A B  C\t\r\n", All), b"ABC\n");
        assert_eq!(clean_ws(b"A \tB  C\r\nD  ", All), b"ABC\nD");
        assert_eq!(clean_ws(b"A\x0CB\x0C\n", All), b"A\x0CB\x0C\n");
    }
}
