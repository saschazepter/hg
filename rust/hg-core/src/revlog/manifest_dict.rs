//! Data structures for accessing and manipulating manifests.

// TODO: Consolidate with similar manifest parsing code in manifest.rs.
// For now it's separate because it started out as a port of
// mercurial/cext/manifest.c, and is currently only used from Python.

use std::ops::Deref;
use std::sync::Arc;

use memchr::memchr_iter;

use crate::dyn_bytes::DynBytes;
use crate::revlog::RevlogError;
use crate::revlog::manifest::DecodedManifestEntry;
use crate::revlog::manifest::ManifestEntry;
use crate::revlog::manifest::ManifestFlags;
use crate::revlog::node::HEX_NODE_LENGTH;
use crate::revlog::node::NODE_BYTES_LENGTH;
use crate::utils::hg_path::HgPath;
use crate::utils::u_u16;
use crate::utils::u_u32;
use crate::utils::u16_u;
use crate::utils::u32_u;

/// Minimum length of a manifest line, excluding the newline.
/// This represents 1 byte path, 1 NUL, and hex node.
const MINIMUM_LINE_LENGTH: usize = 2 + HEX_NODE_LENGTH;

/// A guess at the average length of a line in a manifest. We divide the text
/// size by this to choose a capacity for [`LazyManifest::lines`].
const AVG_LINE_LENGTH_GUESS: usize = 30 + 1 + HEX_NODE_LENGTH;

/// Errors for corrupt manifests.
#[derive(Debug, PartialEq, Eq)]
pub enum ManifestError {
    /// The `nodelen` value is not [`NODE_BYTES_LENGTH`].
    UnsupportedNodeLength(usize),
    /// Manifest does not end with a newline.
    NoTrailingNewline,
    /// Manifest has a line with an empty path.
    EmptyPath,
    /// Manifest has a line whose length (excluding newline) is too short to be
    /// valid.
    LineTooShort(usize),
    /// The paths in the manifest are not in ascending order.
    NotSorted,
    /// A line in the manifest is invalid for some other reason.
    InvalidLine,
}

/// Information about a line in the manifest full text.
#[derive(Copy, Clone)]
struct Line {
    /// Offset of the start of the line.
    offset: u32,
    /// Length of the line, excluding the newline.
    /// This must be at least [`MINIMUM_LINE_LENGTH`].
    len: u16,
    /// Flags after the node, or empty.
    flags: ManifestFlags,
}

impl Line {
    /// Returns the length of the path, in bytes.
    fn path_len(&self) -> usize {
        let flag_size = if self.flags.is_empty() { 0 } else { 1 };
        let null_size = 1;
        // This cannot overflow since `self.len >= MINIMUM_LINE_LENGTH`.
        u16_u(self.len) - flag_size - HEX_NODE_LENGTH - null_size
    }

    /// Reads this line from the manifest's full text.
    fn read<'manifest>(
        &self,
        data: &'manifest [u8],
    ) -> ManifestEntry<'manifest> {
        let i = u32_u(self.offset);
        let n = self.path_len();
        let path = HgPath::new(&data[i..][..n]);
        let hex_node_id = &data[i + n + 1..][..HEX_NODE_LENGTH];
        ManifestEntry { path, hex_node_id, flags: self.flags }
    }
}

/// A manifest backed by the full text that keeps track of modifications.
#[derive(Clone)]
pub struct LazyManifest {
    /// The full text of the manifest.
    ///
    /// TODO: Consider extracting [`crate::segmented_bytes::CachedExtent`] and
    /// reusing it here since it's exactly what we need. `DynBytes` uses `Box`
    /// instead of `Arc`, so we have to wrap the whole thing again in `Arc`.
    data: Arc<DynBytes<'static>>,
    /// Lines parsed from [`Self::data`].
    lines: Arc<Vec<Line>>,
}

impl LazyManifest {
    /// Creates a new `LazyManifest`. Returns an error if `nodelen` is not
    /// `NODE_BYTES_LENGTH`, or if the manifest data is invalid.
    pub fn new(
        nodelen: usize,
        data: impl Deref<Target = [u8]> + Send + Sync + 'static,
    ) -> Result<Self, ManifestError> {
        let data = DynBytes::new(Box::new(data));
        let lines = Self::parse_lines(nodelen, &data)?;
        Ok(Self { data: Arc::new(data), lines: Arc::new(lines) })
    }

    /// Returns the number of entries in the manifest.
    pub fn len(&self) -> usize {
        self.lines.len()
    }

    /// Returns true if the manifest is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns an iterator over manifest entries.
    pub fn iter(&self) -> LazyManifestIter<'_> {
        LazyManifestIter { inner: self, index: 0 }
    }

    /// Returns true if the manifest contains the given path.
    pub fn contains(&self, path: &HgPath) -> bool {
        self.binary_search(path).is_ok()
    }

    /// Looks up a path in the manifest.
    pub fn get(
        &self,
        path: &HgPath,
    ) -> Result<Option<DecodedManifestEntry<'_>>, RevlogError> {
        let Ok(index) = self.binary_search(path) else {
            return Ok(None);
        };
        Ok(Some(self.lines[index].read(&self.data).decode()?))
    }

    /// Parses all lines of a manifest.
    fn parse_lines(
        nodelen: usize,
        data: &[u8],
    ) -> Result<Vec<Line>, ManifestError> {
        if nodelen != NODE_BYTES_LENGTH {
            return Err(ManifestError::UnsupportedNodeLength(nodelen));
        }
        match data.last() {
            None | Some(&b'\n') => {}
            _ => return Err(ManifestError::NoTrailingNewline),
        }
        let mut lines = Vec::with_capacity(data.len() / AVG_LINE_LENGTH_GUESS);
        let mut start = 0;
        let mut prev_path = HgPath::new(b"");
        for end in memchr_iter(b'\n', data) {
            let line = Self::parse_one_line(start, &data[start..end])?;
            let path = line.read(data).path;
            if path <= prev_path {
                return Err(ManifestError::NotSorted);
            }
            prev_path = path;
            lines.push(line);
            start = end + 1;
        }
        Ok(lines)
    }

    /// Parses one line of a manifest (excluding the newline).
    fn parse_one_line(
        offset: usize,
        str: &[u8],
    ) -> Result<Line, ManifestError> {
        if str.first() == Some(&b'\0') {
            return Err(ManifestError::EmptyPath);
        }
        if str.len() < MINIMUM_LINE_LENGTH {
            return Err(ManifestError::LineTooShort(str.len()));
        }
        let last = str.last().expect("already checked minimum length");
        let flags =
            ManifestFlags::from_byte(*last).unwrap_or(ManifestFlags::EMPTY);
        let line = Line { offset: u_u32(offset), len: u_u16(str.len()), flags };
        if str[line.path_len()] != b'\0' {
            return Err(ManifestError::InvalidLine);
        }
        Ok(line)
    }

    /// Binary searches for `path`, returning `Ok(index)` if found.
    /// Returns `Err(insertion_index)` if not found.
    fn binary_search(&self, path: &HgPath) -> Result<usize, usize> {
        self.lines.binary_search_by(|e| e.read(&self.data).path.cmp(path))
    }
}

/// An iterator over manifest entries.
pub struct LazyManifestIter<'a> {
    inner: &'a LazyManifest,
    index: usize,
}

impl<'a> Iterator for LazyManifestIter<'a> {
    type Item = Result<DecodedManifestEntry<'a>, RevlogError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.index == self.inner.lines.len() {
            return None;
        }
        let line = self.inner.lines[self.index];
        self.index += 1;
        Some(line.read(&self.inner.data).decode())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Node;
    use crate::revlog::manifest::ManifestFlags;

    fn path(path: &[u8]) -> &HgPath {
        HgPath::new(path)
    }

    fn node(hex: &[u8]) -> Node {
        Node::from_hex(hex).unwrap()
    }

    fn new(data: &[u8]) -> LazyManifest {
        LazyManifest::new(NODE_BYTES_LENGTH, data.to_vec()).unwrap()
    }

    fn collect(
        manifest: &LazyManifest,
    ) -> Result<Vec<DecodedManifestEntry<'_>>, RevlogError> {
        manifest.iter().collect()
    }

    #[test]
    fn test_empty() {
        let manifest = new(b"");

        assert!(manifest.is_empty());
        assert_eq!(manifest.len(), 0);

        assert!(!manifest.contains(path(b"")));
        assert!(!manifest.contains(path(b"file.txt")));

        assert_eq!(manifest.get(path(b"")).unwrap(), None);
        assert_eq!(manifest.get(path(b"file.txt")).unwrap(), None);

        assert_eq!(collect(&manifest).unwrap(), &[]);
    }

    #[test]
    fn test_one() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let entry = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };

        let manifest = new(text);

        assert!(!manifest.is_empty());
        assert_eq!(manifest.len(), 1);

        assert!(!manifest.contains(path(b"")));
        assert!(manifest.contains(path(b"file.txt")));
        assert!(!manifest.contains(path(b"subdir/other.py")));

        assert_eq!(manifest.get(path(b"")).unwrap(), None);
        assert_eq!(manifest.get(path(b"file.txt")).unwrap(), Some(entry));
        assert_eq!(manifest.get(path(b"subdir/other.py")).unwrap(), None);

        assert_eq!(collect(&manifest).unwrap(), &[entry]);
    }

    #[test]
    fn test_two() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            subdir/other.py\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n";
        let entry_1 = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };
        let entry_2 = DecodedManifestEntry {
            path: path(b"subdir/other.py"),
            node: node(b"e14fa8304bb04039a7e7e7ffa170715fa2136e47"),
            flags: ManifestFlags::EXEC,
        };

        let manifest = new(text);

        assert!(!manifest.is_empty());
        assert_eq!(manifest.len(), 2);

        assert!(!manifest.contains(path(b"")));
        assert!(manifest.contains(path(b"file.txt")));
        assert!(manifest.contains(path(b"subdir/other.py")));

        assert_eq!(manifest.get(path(b"")).unwrap(), None);
        assert_eq!(manifest.get(path(b"file.txt")).unwrap(), Some(entry_1));
        assert_eq!(
            manifest.get(path(b"subdir/other.py")).unwrap(),
            Some(entry_2)
        );

        assert_eq!(collect(&manifest).unwrap(), &[entry_1, entry_2]);
    }

    #[test]
    fn test_invalid() {
        let text = b"\n";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH, text.to_vec());
        assert_eq!(manifest.err(), Some(ManifestError::LineTooShort(0)));

        let text = b"\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH, text.to_vec());
        assert_eq!(manifest.err(), Some(ManifestError::EmptyPath));

        let text = b"file.txt 1cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH, text.to_vec());
        assert_eq!(manifest.err(), Some(ManifestError::InvalidLine));

        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH, text.to_vec());
        assert_eq!(manifest.err(), Some(ManifestError::NoTrailingNewline));

        let text =
            b"subdir/other.py\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n\
            file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH, text.to_vec());
        assert_eq!(manifest.err(), Some(ManifestError::NotSorted));
    }

    #[test]
    fn test_unsupported_node_length() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let manifest = LazyManifest::new(NODE_BYTES_LENGTH + 1, text.to_vec());
        assert_eq!(
            manifest.err(),
            Some(ManifestError::UnsupportedNodeLength(NODE_BYTES_LENGTH + 1))
        );
    }
}
