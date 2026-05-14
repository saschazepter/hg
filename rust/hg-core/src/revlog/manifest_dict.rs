//! Data structures for accessing and manipulating manifests.

// TODO: Consolidate with similar manifest parsing code in manifest.rs.
// For now it's separate because it started out as a port of
// mercurial/cext/manifest.c, and is currently only used from Python.

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;
use std::ops::Deref;
use std::sync::Arc;

use memchr::memchr_iter;

use crate::Node;
use crate::dyn_bytes::DynBytes;
use crate::revlog::RevlogError;
use crate::revlog::manifest::DecodedManifestEntry;
use crate::revlog::manifest::ManifestEntry;
use crate::revlog::manifest::ManifestFlags;
use crate::revlog::node::HEX_NODE_LENGTH;
use crate::revlog::node::NODE_BYTES_LENGTH;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
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
    /// In-memory edits on top of [`Self::lines`], keyed by path.
    edits: BTreeMap<HgPathBuf, Edit>,
    /// Net change in the number of entries caused by [`Self::edits`].
    count_delta: isize,
}

/// An edit to a manifest.
#[derive(Copy, Clone)]
struct Edit {
    /// Index in [`LazyManifest::lines`] that the operation applies to.
    index: usize,
    /// What the edit does at [`Self::index`].
    operation: Operation,
}

/// What an [`Edit`] does at its index.
#[derive(Copy, Clone)]
enum Operation {
    /// Insert a new entry before the line at the index.
    Insert(FileState),
    /// Replace the line at the index.
    Update(FileState),
    /// Remove the line at the index.
    Remove,
}

/// A manifest entry without the path.
#[derive(Copy, Clone)]
struct FileState {
    /// Path's filelog node.
    node: Node,
    /// Path's flags.
    flags: ManifestFlags,
}

impl FileState {
    fn entry<'a>(&self, path: &'a HgPath) -> DecodedManifestEntry<'a> {
        DecodedManifestEntry { path, node: self.node, flags: self.flags }
    }
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
        Ok(Self {
            data: Arc::new(data),
            lines: Arc::new(lines),
            edits: BTreeMap::new(),
            count_delta: 0,
        })
    }

    /// Returns the number of entries in the manifest.
    pub fn len(&self) -> usize {
        self.lines
            .len()
            .checked_add_signed(self.count_delta)
            .expect("cannot be negative")
    }

    /// Returns true if the manifest is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns an iterator over manifest entries.
    pub fn iter(&self) -> LazyManifestIter<'_> {
        let mut iter_edits = self.edits.iter();
        let next_edit = iter_edits.next().map(|t| (t.0.as_ref(), *t.1));
        LazyManifestIter { inner: self, index: 0, iter_edits, next_edit }
    }

    /// Returns true if the manifest contains the given path.
    pub fn contains(&self, path: &HgPath) -> bool {
        match self.edits.get(path).map(|edit| edit.operation) {
            Some(Operation::Insert(_) | Operation::Update(_)) => true,
            Some(Operation::Remove) => false,
            None => Self::binary_search(&self.lines, &self.data, path).is_ok(),
        }
    }

    /// Looks up a path in the manifest.
    pub fn get(
        &self,
        path: &HgPath,
    ) -> Result<Option<DecodedManifestEntry<'_>>, RevlogError> {
        // Use get_key_value to make the lifetime attached to the path in the
        // LazyManifest, not the lifetime of the path parameter.
        if let Some((path, edit)) = self.edits.get_key_value(path) {
            return Ok(match &edit.operation {
                Operation::Insert(state) | Operation::Update(state) => {
                    Some(state.entry(path))
                }
                Operation::Remove => None,
            });
        }
        let Ok(index) = Self::binary_search(&self.lines, &self.data, path)
        else {
            return Ok(None);
        };
        Ok(Some(self.lines[index].read(&self.data).decode()?))
    }

    /// Maps `path` to `(node, flags)` in the manifest.
    /// Returns true if it overwrote an existing path.
    pub fn set(
        &mut self,
        path: &HgPath,
        node: Node,
        flags: ManifestFlags,
    ) -> bool {
        let state = FileState { node, flags };
        let found = match self.edits.entry(path.to_owned()) {
            Entry::Vacant(entry) => {
                match Self::binary_search(&self.lines, &self.data, path) {
                    Ok(index) => {
                        let operation = Operation::Update(state);
                        entry.insert(Edit { index, operation });
                        true
                    }
                    Err(index) => {
                        let operation = Operation::Insert(state);
                        entry.insert(Edit { index, operation });
                        false
                    }
                }
            }
            Entry::Occupied(mut entry) => {
                let operation = &mut entry.get_mut().operation;
                match operation {
                    Operation::Insert(s) | Operation::Update(s) => {
                        *s = state;
                        true
                    }
                    Operation::Remove => {
                        *operation = Operation::Update(state);
                        false
                    }
                }
            }
        };
        if !found {
            self.add_to_count_delta(1);
        }
        found
    }

    /// Removes `path` from the manifest. Returns true if it was found.
    pub fn remove(&mut self, path: &HgPath) -> bool {
        let found = match self.edits.entry(path.to_owned()) {
            Entry::Vacant(entry) => {
                match Self::binary_search(&self.lines, &self.data, path) {
                    Ok(index) => {
                        let operation = Operation::Remove;
                        entry.insert(Edit { index, operation });
                        true
                    }
                    Err(_) => false,
                }
            }
            Entry::Occupied(mut entry) => {
                let operation = &mut entry.get_mut().operation;
                match operation {
                    // Path was inserted in memory. Undo that.
                    Operation::Insert(_) => {
                        entry.remove();
                        true
                    }
                    // Path was updated in memory. Turn it into a removal.
                    Operation::Update(_) => {
                        *operation = Operation::Remove;
                        true
                    }
                    // Path is already removed.
                    Operation::Remove => false,
                }
            }
        };
        if found {
            self.add_to_count_delta(-1);
        }
        found
    }

    /// Adds `value` to [`Self::count_delta`].
    /// In tests, this also does a consistency check.
    fn add_to_count_delta(&mut self, value: isize) {
        self.count_delta += value;
        #[cfg(test)]
        {
            let expected: isize = self
                .edits
                .values()
                .map(|edit| match edit.operation {
                    Operation::Insert(_) => 1,
                    Operation::Update(_) => 0,
                    Operation::Remove => -1,
                })
                .sum();
            assert_eq!(self.count_delta, expected);
        }
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

    /// Binary searches `lines` for `path`, returning `Ok(index)` if found.
    /// Returns `Err(insertion_index)` if not found. Takes the fields rather
    /// than `&self` so it can be called while `edits` is mutably borrowed.
    fn binary_search(
        lines: &[Line],
        data: &[u8],
        path: &HgPath,
    ) -> Result<usize, usize> {
        lines.binary_search_by(|e| e.read(data).path.cmp(path))
    }
}

/// An iterator over manifest entries.
pub struct LazyManifestIter<'a> {
    inner: &'a LazyManifest,
    index: usize,
    iter_edits: std::collections::btree_map::Iter<'a, HgPathBuf, Edit>,
    next_edit: Option<(&'a HgPath, Edit)>,
}

impl<'a> Iterator for LazyManifestIter<'a> {
    type Item = Result<DecodedManifestEntry<'a>, RevlogError>;

    fn next(&mut self) -> Option<Self::Item> {
        let len = self.inner.lines.len();
        loop {
            let i = self.index;
            if let Some((path, Edit { index, operation })) = self.next_edit
                && i == index
            {
                self.next_edit =
                    self.iter_edits.next().map(|t| (t.0.as_ref(), *t.1));
                match operation {
                    Operation::Insert(state) => {
                        return Some(Ok(state.entry(path)));
                    }
                    Operation::Update(state) => {
                        self.index += 1;
                        return Some(Ok(state.entry(path)));
                    }
                    Operation::Remove => {
                        self.index += 1;
                        continue;
                    }
                }
            }
            if i == len {
                break;
            }
            self.index += 1;
            let line = self.inner.lines[i];
            return Some(line.read(&self.inner.data).decode());
        }
        None
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

    #[test]
    fn test_remove_empty() {
        let mut manifest = new(b"");

        assert!(!manifest.remove(path(b"file.txt")));
        assert_eq!(collect(&manifest).unwrap(), &[]);
    }

    #[test]
    fn test_remove_one() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let mut manifest = new(text);

        assert!(manifest.remove(path(b"file.txt")));

        assert_eq!(collect(&manifest).unwrap(), &[]);
        assert_eq!(manifest.len(), 0);
        assert!(manifest.is_empty());
        assert!(!manifest.contains(path(b"file.txt")));
        assert!(!manifest.remove(path(b"file.txt")));
    }

    #[test]
    fn test_remove_two() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            subdir/other.py\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n";
        let mut manifest = new(text);

        assert!(manifest.remove(path(b"file.txt")));

        let entry_2 = DecodedManifestEntry {
            path: path(b"subdir/other.py"),
            node: node(b"e14fa8304bb04039a7e7e7ffa170715fa2136e47"),
            flags: ManifestFlags::EXEC,
        };

        assert_eq!(collect(&manifest).unwrap(), &[entry_2]);
        assert_eq!(manifest.len(), 1);
        assert!(!manifest.is_empty());
        assert!(!manifest.contains(path(b"file.txt")));
        assert!(!manifest.remove(path(b"file.txt")));
        assert!(manifest.contains(path(b"subdir/other.py")));

        assert!(manifest.remove(path(b"subdir/other.py")));

        assert_eq!(collect(&manifest).unwrap(), &[]);
        assert_eq!(manifest.len(), 0);
        assert!(manifest.is_empty());
    }

    #[test]
    fn test_set_empty() {
        let mut manifest = new(b"");

        let entry = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };

        let overwrote = manifest.set(entry.path, entry.node, entry.flags);
        assert!(!overwrote);
        assert_eq!(collect(&manifest).unwrap(), &[entry]);
        assert_eq!(manifest.len(), 1);
        assert!(!manifest.is_empty());
        assert!(manifest.contains(entry.path));
        assert_eq!(manifest.get(entry.path).unwrap(), Some(entry));
    }

    #[test]
    fn test_set_one() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let mut manifest = new(text);

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

        let overwrote = manifest.set(entry_2.path, entry_2.node, entry_2.flags);
        assert!(!overwrote);
        assert_eq!(collect(&manifest).unwrap(), &[entry_1, entry_2]);
        assert_eq!(manifest.len(), 2);
        assert!(!manifest.is_empty());
        assert!(manifest.contains(entry_1.path));
        assert_eq!(manifest.get(entry_1.path).unwrap(), Some(entry_1));
        assert!(manifest.contains(entry_2.path));
        assert_eq!(manifest.get(entry_2.path).unwrap(), Some(entry_2));
    }

    #[test]
    fn test_set_overwrite() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let mut manifest = new(text);

        let entry = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"cccccccccccccccccccccccccccccccccccccccc"),
            flags: ManifestFlags::LINK,
        };

        let overwrote = manifest.set(entry.path, entry.node, entry.flags);
        assert!(overwrote);
        assert_eq!(collect(&manifest).unwrap(), &[entry]);
        assert_eq!(manifest.get(entry.path).unwrap(), Some(entry));
    }

    #[test]
    fn test_set_remove() {
        let mut manifest = new(b"");

        let entry = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };

        let overwrote = manifest.set(entry.path, entry.node, entry.flags);
        assert!(!overwrote);
        assert!(manifest.remove(entry.path));
        assert_eq!(collect(&manifest).unwrap(), &[]);
        assert_eq!(manifest.len(), 0);
        assert!(manifest.is_empty());
        assert_eq!(manifest.get(entry.path).unwrap(), None);
    }

    #[test]
    fn test_remove_set() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let mut manifest = new(text);

        let entry = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };

        assert!(manifest.remove(entry.path));
        let overwrote = manifest.set(entry.path, entry.node, entry.flags);
        assert!(!overwrote);
        assert_eq!(collect(&manifest).unwrap(), &[entry]);
        assert_eq!(manifest.len(), 1);
        assert!(!manifest.is_empty());
        assert_eq!(manifest.get(entry.path).unwrap(), Some(entry));
    }
}
