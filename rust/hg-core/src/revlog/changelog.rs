use std::ascii::escape_default;
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fmt::{Debug, Formatter};
use std::{iter, str};

use chrono::{DateTime, FixedOffset, Utc};
use itertools::{Either, Itertools};

use crate::errors::HgError;
use crate::revlog::Index;
use crate::revlog::Revision;
use crate::revlog::{Node, NodePrefix};
use crate::revlog::{Revlog, RevlogEntry, RevlogError};
use crate::utils::hg_path::HgPath;
use crate::vfs::VfsImpl;
use crate::{Graph, GraphError, UncheckedRevision};

use super::options::RevlogOpenOptions;

/// A specialized `Revlog` to work with changelog data format.
pub struct Changelog {
    /// The generic `revlog` format.
    pub(crate) revlog: Revlog,
}

impl Changelog {
    /// Open the `changelog` of a repository given by its root.
    pub fn open(
        store_vfs: &VfsImpl,
        options: RevlogOpenOptions,
    ) -> Result<Self, HgError> {
        let revlog = Revlog::open(store_vfs, "00changelog.i", None, options)?;
        Ok(Self { revlog })
    }

    /// Return the `ChangelogRevisionData` for the given node ID.
    pub fn data_for_node(
        &self,
        node: NodePrefix,
    ) -> Result<ChangelogRevisionData, RevlogError> {
        let rev = self.revlog.rev_from_node(node)?;
        self.entry(rev)?.data()
    }

    /// Return the [`ChangelogEntry`] for the given revision number.
    pub fn entry_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<ChangelogEntry, RevlogError> {
        let revlog_entry = self.revlog.get_entry_for_unchecked_rev(rev)?;
        Ok(ChangelogEntry { revlog_entry })
    }

    /// Same as [`Self::entry_for_unchecked_rev`] for a checked revision
    pub fn entry(&self, rev: Revision) -> Result<ChangelogEntry, RevlogError> {
        let revlog_entry = self.revlog.get_entry(rev)?;
        Ok(ChangelogEntry { revlog_entry })
    }

    /// Return the [`ChangelogRevisionData`] for the given revision number.
    ///
    /// This is a useful shortcut in case the caller does not need the
    /// generic revlog information (parents, hashes etc). Otherwise
    /// consider taking a [`ChangelogEntry`] with
    /// [`Self::entry_for_unchecked_rev`] and doing everything from there.
    pub fn data_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<ChangelogRevisionData, RevlogError> {
        self.entry_for_unchecked_rev(rev)?.data()
    }

    pub fn node_from_rev(&self, rev: Revision) -> &Node {
        self.revlog.node_from_rev(rev)
    }

    pub fn node_from_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Option<&Node> {
        self.revlog.node_from_unchecked_rev(rev)
    }

    pub fn rev_from_node(
        &self,
        node: NodePrefix,
    ) -> Result<Revision, RevlogError> {
        self.revlog.rev_from_node(node)
    }

    pub fn get_index(&self) -> &Index {
        self.revlog.index()
    }
}

impl Graph for Changelog {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        self.revlog.parents(rev)
    }
}

/// A specialized `RevlogEntry` for `changelog` data format
///
/// This is a `RevlogEntry` with the added semantics that the associated
/// data should meet the requirements for `changelog`, materialized by
/// the fact that `data()` constructs a `ChangelogRevisionData`.
/// In case that promise would be broken, the `data` method returns an error.
#[derive(Clone)]
pub struct ChangelogEntry<'changelog> {
    /// Same data, as a generic `RevlogEntry`.
    pub(crate) revlog_entry: RevlogEntry<'changelog>,
}

impl<'changelog> ChangelogEntry<'changelog> {
    pub fn data<'a>(
        &'a self,
    ) -> Result<ChangelogRevisionData<'changelog>, RevlogError> {
        let bytes = self.revlog_entry.data()?;
        if bytes.is_empty() {
            Ok(ChangelogRevisionData::null())
        } else {
            Ok(ChangelogRevisionData::new(bytes).map_err(|err| {
                RevlogError::Other(HgError::CorruptedRepository(format!(
                    "Invalid changelog data for revision {}: {:?}",
                    self.revlog_entry.revision(),
                    err
                )))
            })?)
        }
    }

    /// Obtain a reference to the underlying `RevlogEntry`.
    ///
    /// This allows the caller to access the information that is common
    /// to all revlog entries: revision number, node id, parent revisions etc.
    pub fn as_revlog_entry(&self) -> &RevlogEntry {
        &self.revlog_entry
    }

    pub fn p1_entry(&self) -> Result<Option<ChangelogEntry>, RevlogError> {
        Ok(self
            .revlog_entry
            .p1_entry()?
            .map(|revlog_entry| Self { revlog_entry }))
    }

    pub fn p2_entry(&self) -> Result<Option<ChangelogEntry>, RevlogError> {
        Ok(self
            .revlog_entry
            .p2_entry()?
            .map(|revlog_entry| Self { revlog_entry }))
    }
}

/// `Changelog` entry which knows how to interpret the `changelog` data bytes.
#[derive(PartialEq)]
pub struct ChangelogRevisionData<'changelog> {
    /// The data bytes of the `changelog` entry.
    bytes: Cow<'changelog, [u8]>,
    /// The end offset for the hex manifest (not including the newline)
    manifest_end: usize,
    /// The end offset for the user+email (not including the newline)
    user_end: usize,
    /// The end offset for the timestamp+timezone+extras (not including the
    /// newline)
    timestamp_end: usize,
    /// The end offset for the file list (not including the newline)
    files_end: usize,
}

impl<'changelog> ChangelogRevisionData<'changelog> {
    fn new(bytes: Cow<'changelog, [u8]>) -> Result<Self, HgError> {
        let mut line_iter = bytes.split(|b| b == &b'\n');
        let manifest_end = line_iter
            .next()
            .expect("Empty iterator from split()?")
            .len();
        let user_slice = line_iter.next().ok_or_else(|| {
            HgError::corrupted("Changeset data truncated after manifest line")
        })?;
        let user_end = manifest_end + 1 + user_slice.len();
        let timestamp_slice = line_iter.next().ok_or_else(|| {
            HgError::corrupted("Changeset data truncated after user line")
        })?;
        let timestamp_end = user_end + 1 + timestamp_slice.len();
        let mut files_end = timestamp_end + 1;
        loop {
            let line = line_iter.next().ok_or_else(|| {
                HgError::corrupted("Changeset data truncated in files list")
            })?;
            if line.is_empty() {
                if files_end == bytes.len() {
                    // The list of files ended with a single newline (there
                    // should be two)
                    return Err(HgError::corrupted(
                        "Changeset data truncated after files list",
                    ));
                }
                files_end -= 1;
                break;
            }
            files_end += line.len() + 1;
        }

        Ok(Self {
            bytes,
            manifest_end,
            user_end,
            timestamp_end,
            files_end,
        })
    }

    fn null() -> Self {
        Self::new(Cow::Borrowed(
            b"0000000000000000000000000000000000000000\n\n0 0\n\n",
        ))
        .unwrap()
    }

    /// Return an iterator over the lines of the entry.
    pub fn lines(&self) -> impl Iterator<Item = &[u8]> {
        self.bytes.split(|b| b == &b'\n')
    }

    /// Return the node id of the `manifest` referenced by this `changelog`
    /// entry.
    pub fn manifest_node(&self) -> Result<Node, HgError> {
        let manifest_node_hex = &self.bytes[..self.manifest_end];
        Node::from_hex_for_repo(manifest_node_hex)
    }

    /// The full user string (usually a name followed by an email enclosed in
    /// angle brackets)
    pub fn user(&self) -> &[u8] {
        &self.bytes[self.manifest_end + 1..self.user_end]
    }

    /// The full timestamp line (timestamp in seconds, offset in seconds, and
    /// possibly extras)
    // TODO: We should expose this in a more useful way
    pub fn timestamp_line(&self) -> &[u8] {
        &self.bytes[self.user_end + 1..self.timestamp_end]
    }

    /// Parsed timestamp.
    pub fn timestamp(&self) -> Result<DateTime<FixedOffset>, HgError> {
        parse_timestamp(self.timestamp_line())
    }

    /// Optional commit extras.
    pub fn extra(&self) -> Result<BTreeMap<String, Vec<u8>>, HgError> {
        parse_timestamp_line_extra(self.timestamp_line())
    }

    /// The files changed in this revision.
    pub fn files(&self) -> impl Iterator<Item = &HgPath> {
        if self.timestamp_end == self.files_end {
            Either::Left(iter::empty())
        } else {
            Either::Right(
                self.bytes[self.timestamp_end + 1..self.files_end]
                    .split(|b| b == &b'\n')
                    .map(HgPath::new),
            )
        }
    }

    /// The change description.
    pub fn description(&self) -> &[u8] {
        &self.bytes[self.files_end + 2..]
    }
}

impl Debug for ChangelogRevisionData<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChangelogRevisionData")
            .field("bytes", &debug_bytes(&self.bytes))
            .field("manifest", &debug_bytes(&self.bytes[..self.manifest_end]))
            .field(
                "user",
                &debug_bytes(
                    &self.bytes[self.manifest_end + 1..self.user_end],
                ),
            )
            .field(
                "timestamp",
                &debug_bytes(
                    &self.bytes[self.user_end + 1..self.timestamp_end],
                ),
            )
            .field(
                "files",
                &debug_bytes(
                    &self.bytes[self.timestamp_end + 1..self.files_end],
                ),
            )
            .field(
                "description",
                &debug_bytes(&self.bytes[self.files_end + 2..]),
            )
            .finish()
    }
}

fn debug_bytes(bytes: &[u8]) -> String {
    String::from_utf8_lossy(
        &bytes.iter().flat_map(|b| escape_default(*b)).collect_vec(),
    )
    .to_string()
}

/// Parse the raw bytes of the timestamp line from a changelog entry.
///
/// According to the documentation in `hg help dates` and the
/// implementation in `changelog.py`, the format of the timestamp line
/// is `time tz extra\n` where:
///
/// - `time` is an ASCII-encoded signed int or float denoting a UTC timestamp
///   as seconds since the UNIX epoch.
///
/// - `tz` is the timezone offset as an ASCII-encoded signed integer denoting
///   seconds WEST of UTC (so negative for timezones east of UTC, which is the
///   opposite of the sign in ISO 8601 timestamps).
///
/// - `extra` is an optional set of NUL-delimited key-value pairs, with the key
///   and value in each pair separated by an ASCII colon. Keys are limited to
///   ASCII letters, digits, hyphens, and underscores, whereas values can be
///   arbitrary bytes.
fn parse_timestamp(
    timestamp_line: &[u8],
) -> Result<DateTime<FixedOffset>, HgError> {
    let mut parts = timestamp_line.splitn(3, |c| *c == b' ');

    let timestamp_bytes = parts
        .next()
        .ok_or_else(|| HgError::corrupted("missing timestamp"))?;
    let timestamp_str = str::from_utf8(timestamp_bytes).map_err(|e| {
        HgError::corrupted(format!("timestamp is not valid UTF-8: {e}"))
    })?;
    let timestamp_utc = timestamp_str
        .parse()
        .map_err(|e| {
            HgError::corrupted(format!("failed to parse timestamp: {e}"))
        })
        .and_then(|secs| {
            DateTime::from_timestamp(secs, 0).ok_or_else(|| {
                HgError::corrupted(format!(
                    "integer timestamp out of valid range: {secs}"
                ))
            })
        })
        // Attempt to parse the timestamp as a float if we can't parse
        // it as an int. It doesn't seem like float timestamps are actually
        // used in practice, but the Python code supports them.
        .or_else(|_| parse_float_timestamp(timestamp_str))?;

    let timezone_bytes = parts
        .next()
        .ok_or_else(|| HgError::corrupted("missing timezone"))?;
    let timezone_secs: i32 = str::from_utf8(timezone_bytes)
        .map_err(|e| {
            HgError::corrupted(format!("timezone is not valid UTF-8: {e}"))
        })?
        .parse()
        .map_err(|e| {
            HgError::corrupted(format!("timezone is not an integer: {e}"))
        })?;
    let timezone = FixedOffset::west_opt(timezone_secs)
        .ok_or_else(|| HgError::corrupted("timezone offset out of bounds"))?;

    Ok(timestamp_utc.with_timezone(&timezone))
}

/// Attempt to parse the given string as floating-point timestamp, and
/// convert the result into a `chrono::NaiveDateTime`.
fn parse_float_timestamp(
    timestamp_str: &str,
) -> Result<DateTime<Utc>, HgError> {
    let timestamp = timestamp_str.parse::<f64>().map_err(|e| {
        HgError::corrupted(format!("failed to parse timestamp: {e}"))
    })?;

    // To construct a `NaiveDateTime` we'll need to convert the float
    // into signed integer seconds and unsigned integer nanoseconds.
    let mut secs = timestamp.trunc() as i64;
    let mut subsecs = timestamp.fract();

    // If the timestamp is negative, we need to express the fractional
    // component as positive nanoseconds since the previous second.
    if timestamp < 0.0 {
        secs -= 1;
        subsecs += 1.0;
    }

    // This cast should be safe because the fractional component is
    // by definition less than 1.0, so this value should not exceed
    // 1 billion, which is representable as an f64 without loss of
    // precision and should fit into a u32 without overflowing.
    //
    // (Any loss of precision in the fractional component will have
    // already happened at the time of initial parsing; in general,
    // f64s are insufficiently precise to provide nanosecond-level
    // precision with present-day timestamps.)
    let nsecs = (subsecs * 1_000_000_000.0) as u32;

    DateTime::from_timestamp(secs, nsecs).ok_or_else(|| {
        HgError::corrupted(format!(
            "float timestamp out of valid range: {timestamp}"
        ))
    })
}

/// Decode changeset extra fields.
///
/// Extras are null-delimited key-value pairs where the key consists of ASCII
/// alphanumeric characters plus hyphens and underscores, and the value can
/// contain arbitrary bytes.
fn decode_extra(extra: &[u8]) -> Result<BTreeMap<String, Vec<u8>>, HgError> {
    extra
        .split(|c| *c == b'\0')
        .map(|pair| {
            let pair = unescape_extra(pair);
            let mut iter = pair.splitn(2, |c| *c == b':');

            let key_bytes =
                iter.next().filter(|k| !k.is_empty()).ok_or_else(|| {
                    HgError::corrupted("empty key in changeset extras")
                })?;

            let key = str::from_utf8(key_bytes)
                .ok()
                .filter(|k| {
                    k.chars().all(|c| {
                        c.is_ascii_alphanumeric() || c == '_' || c == '-'
                    })
                })
                .ok_or_else(|| {
                    let key = String::from_utf8_lossy(key_bytes);
                    HgError::corrupted(format!(
                        "invalid key in changeset extras: {key}",
                    ))
                })?
                .to_string();

            let value = iter.next().map(Into::into).ok_or_else(|| {
                HgError::corrupted(format!(
                    "missing value for changeset extra: {key}"
                ))
            })?;

            Ok((key, value))
        })
        .collect()
}

/// Parse the extra fields from a changeset's timestamp line.
fn parse_timestamp_line_extra(
    timestamp_line: &[u8],
) -> Result<BTreeMap<String, Vec<u8>>, HgError> {
    Ok(timestamp_line
        .splitn(3, |c| *c == b' ')
        .nth(2)
        .map(decode_extra)
        .transpose()?
        .unwrap_or_default())
}

/// Decode Mercurial's escaping for changelog extras.
///
/// The `_string_escape` function in `changelog.py` only escapes 4 characters
/// (null, backslash, newline, and carriage return) so we only decode those.
///
/// The Python code also includes a workaround for decoding escaped nuls
/// that are followed by an ASCII octal digit, since Python's built-in
/// `string_escape` codec will interpret that as an escaped octal byte value.
/// That workaround is omitted here since we don't support decoding octal.
fn unescape_extra(bytes: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(bytes.len());
    let mut input = bytes.iter().copied();

    while let Some(c) = input.next() {
        if c != b'\\' {
            output.push(c);
            continue;
        }

        match input.next() {
            Some(b'0') => output.push(b'\0'),
            Some(b'\\') => output.push(b'\\'),
            Some(b'n') => output.push(b'\n'),
            Some(b'r') => output.push(b'\r'),
            // The following cases should never occur in theory because any
            // backslashes in the original input should have been escaped
            // with another backslash, so it should not be possible to
            // observe an escape sequence other than the 4 above.
            Some(c) => output.extend_from_slice(&[b'\\', c]),
            None => output.push(b'\\'),
        }
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vfs::VfsImpl;
    use crate::NULL_REVISION;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_create_changelogrevisiondata_invalid() {
        // Completely empty
        assert!(ChangelogRevisionData::new(Cow::Borrowed(b"abcd")).is_err());
        // No newline after manifest
        assert!(ChangelogRevisionData::new(Cow::Borrowed(b"abcd")).is_err());
        // No newline after user
        assert!(ChangelogRevisionData::new(Cow::Borrowed(b"abcd\n")).is_err());
        // No newline after timestamp
        assert!(
            ChangelogRevisionData::new(Cow::Borrowed(b"abcd\n\n0 0")).is_err()
        );
        // Missing newline after files
        assert!(ChangelogRevisionData::new(Cow::Borrowed(
            b"abcd\n\n0 0\nfile1\nfile2"
        ))
        .is_err(),);
        // Only one newline after files
        assert!(ChangelogRevisionData::new(Cow::Borrowed(
            b"abcd\n\n0 0\nfile1\nfile2\n"
        ))
        .is_err(),);
    }

    #[test]
    fn test_create_changelogrevisiondata() {
        let data = ChangelogRevisionData::new(Cow::Borrowed(
            b"0123456789abcdef0123456789abcdef01234567
Some One <someone@example.com>
0 0
file1
file2

some
commit
message",
        ))
        .unwrap();
        assert_eq!(
            data.manifest_node().unwrap(),
            Node::from_hex("0123456789abcdef0123456789abcdef01234567")
                .unwrap()
        );
        assert_eq!(data.user(), b"Some One <someone@example.com>");
        assert_eq!(data.timestamp_line(), b"0 0");
        assert_eq!(
            data.files().collect_vec(),
            vec![HgPath::new("file1"), HgPath::new("file2")]
        );
        assert_eq!(data.description(), b"some\ncommit\nmessage");
    }

    #[test]
    fn test_data_from_rev_null() -> Result<(), RevlogError> {
        // an empty revlog will be enough for this case
        let temp = tempfile::tempdir().unwrap();
        let vfs = VfsImpl::new(temp.path().to_owned(), false);
        std::fs::write(temp.path().join("foo.i"), b"").unwrap();
        let revlog =
            Revlog::open(&vfs, "foo.i", None, RevlogOpenOptions::default())
                .unwrap();

        let changelog = Changelog { revlog };
        assert_eq!(
            changelog.data_for_unchecked_rev(NULL_REVISION.into())?,
            ChangelogRevisionData::null()
        );
        // same with the intermediate entry object
        assert_eq!(
            changelog
                .entry_for_unchecked_rev(NULL_REVISION.into())?
                .data()?,
            ChangelogRevisionData::null()
        );
        Ok(())
    }

    #[test]
    fn test_empty_files_list() {
        assert!(ChangelogRevisionData::null()
            .files()
            .collect_vec()
            .is_empty());
    }

    #[test]
    fn test_unescape_basic() {
        // '\0', '\\', '\n', and '\r' are correctly unescaped.
        let expected = b"AAA\0BBB\\CCC\nDDD\rEEE";
        let escaped = br"AAA\0BBB\\CCC\nDDD\rEEE";
        let unescaped = unescape_extra(escaped);
        assert_eq!(&expected[..], &unescaped[..]);
    }

    #[test]
    fn test_unescape_unsupported_sequence() {
        // Other escape sequences are left unaltered.
        for c in 0u8..255 {
            match c {
                b'0' | b'\\' | b'n' | b'r' => continue,
                c => {
                    let expected = &[b'\\', c][..];
                    let unescaped = unescape_extra(expected);
                    assert_eq!(expected, &unescaped[..]);
                }
            }
        }
    }

    #[test]
    fn test_unescape_trailing_backslash() {
        // Trailing backslashes are OK.
        let expected = br"hi\";
        let unescaped = unescape_extra(expected);
        assert_eq!(&expected[..], &unescaped[..]);
    }

    #[test]
    fn test_unescape_nul_followed_by_octal() {
        // Escaped NUL chars followed by octal digits are decoded correctly.
        let expected = b"\x0012";
        let escaped = br"\012";
        let unescaped = unescape_extra(escaped);
        assert_eq!(&expected[..], &unescaped[..]);
    }

    #[test]
    fn test_parse_float_timestamp() {
        let test_cases = [
            // Zero should map to the UNIX epoch.
            ("0.0", "1970-01-01 00:00:00 UTC"),
            // Negative zero should be the same as positive zero.
            ("-0.0", "1970-01-01 00:00:00 UTC"),
            // Values without fractional components should work like integers.
            // (Assuming the timestamp is within the limits of f64 precision.)
            ("1115154970.0", "2005-05-03 21:16:10 UTC"),
            // We expect some loss of precision in the fractional component
            // when parsing arbitrary floating-point values.
            ("1115154970.123456789", "2005-05-03 21:16:10.123456716 UTC"),
            // But representable f64 values should parse losslessly.
            ("1115154970.123456716", "2005-05-03 21:16:10.123456716 UTC"),
            // Negative fractional components are subtracted from the epoch.
            ("-1.333", "1969-12-31 23:59:58.667 UTC"),
        ];

        for (input, expected) in test_cases {
            let res = parse_float_timestamp(input).unwrap().to_string();
            assert_eq!(res, expected);
        }
    }

    fn escape_extra(bytes: &[u8]) -> Vec<u8> {
        let mut output = Vec::with_capacity(bytes.len());

        for c in bytes.iter().copied() {
            output.extend_from_slice(match c {
                b'\0' => &b"\\0"[..],
                b'\\' => &b"\\\\"[..],
                b'\n' => &b"\\n"[..],
                b'\r' => &b"\\r"[..],
                _ => {
                    output.push(c);
                    continue;
                }
            });
        }

        output
    }

    fn encode_extra<K, V>(pairs: impl IntoIterator<Item = (K, V)>) -> Vec<u8>
    where
        K: AsRef<[u8]>,
        V: AsRef<[u8]>,
    {
        let extras = pairs.into_iter().map(|(k, v)| {
            escape_extra(&[k.as_ref(), b":", v.as_ref()].concat())
        });
        // Use fully-qualified syntax to avoid a future naming conflict with
        // the standard library: https://github.com/rust-lang/rust/issues/79524
        Itertools::intersperse(extras, b"\0".to_vec()).concat()
    }

    #[test]
    fn test_decode_extra() {
        let extra = [
            ("branch".into(), b"default".to_vec()),
            ("key-with-hyphens".into(), b"value1".to_vec()),
            ("key_with_underscores".into(), b"value2".to_vec()),
            ("empty-value".into(), b"".to_vec()),
            ("binary-value".into(), (0u8..=255).collect::<Vec<_>>()),
        ]
        .into_iter()
        .collect::<BTreeMap<String, Vec<u8>>>();

        let encoded = encode_extra(&extra);
        let decoded = decode_extra(&encoded).unwrap();

        assert_eq!(extra, decoded);
    }

    #[test]
    fn test_corrupt_extra() {
        let test_cases = [
            (&b""[..], "empty input"),
            (&b"\0"[..], "unexpected null byte"),
            (&b":empty-key"[..], "empty key"),
            (&b"\0leading-null:"[..], "leading null"),
            (&b"trailing-null:\0"[..], "trailing null"),
            (&b"missing-value"[..], "missing value"),
            (&b"$!@# non-alphanum-key:"[..], "non-alphanumeric key"),
            (&b"\xF0\x9F\xA6\x80 non-ascii-key:"[..], "non-ASCII key"),
        ];

        for (extra, msg) in test_cases {
            assert!(
                decode_extra(extra).is_err(),
                "corrupt extra should have failed to parse: {}",
                msg
            );
        }
    }

    #[test]
    fn test_parse_timestamp_line() {
        let extra = [
            ("branch".into(), b"default".to_vec()),
            ("key-with-hyphens".into(), b"value1".to_vec()),
            ("key_with_underscores".into(), b"value2".to_vec()),
            ("empty-value".into(), b"".to_vec()),
            ("binary-value".into(), (0u8..=255).collect::<Vec<_>>()),
        ]
        .into_iter()
        .collect::<BTreeMap<String, Vec<u8>>>();

        let mut line: Vec<u8> = b"1115154970 28800 ".to_vec();
        line.extend_from_slice(&encode_extra(&extra));

        let timestamp = parse_timestamp(&line).unwrap();
        assert_eq!(&timestamp.to_rfc3339(), "2005-05-03T13:16:10-08:00");

        let parsed_extra = parse_timestamp_line_extra(&line).unwrap();
        assert_eq!(extra, parsed_extra);
    }
}
