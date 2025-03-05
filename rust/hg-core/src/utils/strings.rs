//! Contains string-related utilities.

use crate::utils::hg_path::HgPath;
use lazy_static::lazy_static;
use regex::bytes::Regex;
use std::{borrow::Cow, cell::Cell, fmt, io::Write as _, ops::Deref as _};

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
    slice
        .windows(needle.len())
        .position(|window| window == needle)
}

/// Replaces the `from` slice with the `to` slice inside the `buf` slice.
///
/// # Examples
///
/// ```
/// use hg::utils::strings::replace_slice;
/// let mut line = b"I hate writing tests!".to_vec();
/// replace_slice(&mut line, b"hate", b"love");
/// assert_eq!(
///     line,
///     b"I love writing tests!".to_vec()
/// );
/// ```
pub fn replace_slice<T>(buf: &mut [T], from: &[T], to: &[T])
where
    T: Clone + PartialEq,
{
    if buf.len() < from.len() || from.len() != to.len() {
        return;
    }
    for i in 0..=buf.len() - from.len() {
        if buf[i..].starts_with(from) {
            buf[i..(i + from.len())].clone_from_slice(to);
        }
    }
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

impl<'a, T: Escaped> Escaped for &'a [T] {
    fn escaped_bytes(&self) -> Vec<u8> {
        self.iter().flat_map(Escaped::escaped_bytes).collect()
    }
}

impl<T: Escaped> Escaped for Vec<T> {
    fn escaped_bytes(&self) -> Vec<u8> {
        self.deref().escaped_bytes()
    }
}

impl<'a> Escaped for &'a HgPath {
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
    JoinDisplay {
        iter: Cell::new(Some(iter.into_iter())),
        separator,
    }
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
    /// Do nothing.
    None,
    /// Remove whitespace at ends of lines.
    AtEol,
    /// Collapse consecutive whitespace characters into a single space.
    Collapse,
    /// Remove all whitespace characters.
    All,
}

/// Normalizes whitespace in text so that it won't apppear in diffs.
/// Returns `Cow::Borrowed(text)` if the result is unchanged.
pub fn clean_whitespace(text: &[u8], how: CleanWhitespace) -> Cow<[u8]> {
    lazy_static! {
        // To match wsclean in mdiff.py, this includes "\f".
        static ref AT_EOL: Regex =
            Regex::new(r"(?m)[ \t\r\f]+$").expect("valid regex");
        // To match fixws in cext/bdiff.c, this does *not* include "\f".
        static ref MULTIPLE: Regex =
            Regex::new(r"[ \t\r]+").expect("valid regex");
    }
    let replacement: &[u8] = match how {
        CleanWhitespace::None => return Cow::Borrowed(text),
        CleanWhitespace::AtEol => return AT_EOL.replace_all(text, b""),
        CleanWhitespace::Collapse => b" ",
        CleanWhitespace::All => b"",
    };
    let text = MULTIPLE.replace_all(text, replacement);
    replace_all_cow(&AT_EOL, text, b"")
}

/// Helper to call [`Regex::replace_all`] with `Cow` as input and output.
fn replace_all_cow<'a>(
    regex: &Regex,
    haystack: Cow<'a, [u8]>,
    replacement: &[u8],
) -> Cow<'a, [u8]> {
    match haystack {
        Cow::Borrowed(haystack) => regex.replace_all(haystack, replacement),
        Cow::Owned(haystack) => {
            Cow::Owned(regex.replace_all(&haystack, replacement).into_owned())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_expand_vars() {
        // Modifying process-global state in a test isn’t great,
        // but hopefully this won’t collide with anything.
        std::env::set_var("TEST_EXPAND_VAR", "1");
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
}
