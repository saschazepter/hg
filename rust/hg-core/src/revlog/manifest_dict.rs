//! Data structures for accessing and manipulating manifests.

// TODO: Consolidate with similar manifest parsing code in manifest.rs.
// For now it's separate because it started out as a port of
// mercurial/cext/manifest.c, and is currently only used from Python.

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;
use std::io::Write;
use std::ops::Deref;
use std::ops::Range;
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

    /// Returns true if the manifest has been modified in memory.
    ///
    /// This does not necessarily mean that [`Self::compact`] will be different
    /// from the original manifest, since overwriting a path with the same
    /// `(node, flags)` as it had before still makes it dirty.
    fn is_dirty(&self) -> bool {
        !self.edits.is_empty()
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

    /// If necessary, rewrites the manifest with changes applied.
    /// Returns the full text.
    pub fn compact(&mut self) -> &[u8] {
        if !self.is_dirty() {
            return &self.data;
        }
        let old_lines_len = self.lines.len();
        let new_lines_len = self.len();
        let new_text_size = self.compute_text_size();
        let mut new_data = Vec::with_capacity(new_text_size);
        let mut new_lines = Vec::with_capacity(new_lines_len);
        let mut old_line_cursor = 0;
        // Edits are sorted by path. Where several share an index, the inserts
        // come first (because their paths sort before the existing line) and at
        // most one update or remove follows.
        for (path, &Edit { index, operation }) in &self.edits {
            if old_line_cursor < index {
                // Copy untouched lines before the edit.
                self.copy_lines(
                    old_line_cursor..index,
                    &mut new_data,
                    &mut new_lines,
                );
                old_line_cursor = index;
            }
            match operation {
                Operation::Insert(state) | Operation::Update(state) => {
                    write_line(path, state, &mut new_data, &mut new_lines);
                }
                Operation::Remove => {}
            }
            match operation {
                Operation::Insert(_) => {}
                Operation::Update(_) | Operation::Remove => {
                    // There can be at most one Update or Remove per line.
                    debug_assert_eq!(old_line_cursor, index);
                    // Prevent the old line from being copied.
                    old_line_cursor += 1;
                }
            }
        }
        if old_line_cursor < old_lines_len {
            // Copy the rest of the untouched lines.
            self.copy_lines(
                old_line_cursor..old_lines_len,
                &mut new_data,
                &mut new_lines,
            );
        }
        debug_assert_eq!(new_data.len(), new_text_size);
        self.data = Arc::new(DynBytes::new(Box::new(new_data)));
        self.lines = Arc::new(new_lines);
        self.edits.clear();
        self.count_delta = 0;
        &self.data
    }

    /// Computes the size of the manifest text with [`Self::edits`] applied.
    fn compute_text_size(&self) -> usize {
        let mut delta: isize = 0;
        for (path, &Edit { index, operation }) in &self.edits {
            match operation {
                Operation::Insert(state) => {
                    delta += (line_size(path, state.flags) + 1) as isize;
                }
                Operation::Update(state) => {
                    delta += (line_size(path, state.flags) + 1) as isize;
                    delta -= (u16_u(self.lines[index].len) + 1) as isize;
                }
                Operation::Remove => {
                    delta -= (u16_u(self.lines[index].len) + 1) as isize;
                }
            }
        }
        self.data.len().checked_add_signed(delta).expect("cannot be negative")
    }

    /// Copies the lines in `range` (must be nonempty) from [`Self::data`] to
    /// `new_data`, and appends their new positions to `new_lines`.
    fn copy_lines(
        &self,
        range: Range<usize>,
        new_data: &mut Vec<u8>,
        new_lines: &mut Vec<Line>,
    ) {
        debug_assert!(!range.is_empty());
        let first = self.lines[range.start];
        let last = self.lines[range.end - 1];
        let start = u32_u(first.offset);
        // Include the newline at the end of the last line.
        let end = u32_u(last.offset) + u16_u(last.len) + 1;
        for &line in &self.lines[range] {
            let offset = new_data.len() + u32_u(line.offset) - start;
            new_lines.push(Line { offset: u_u32(offset), ..line });
        }
        new_data.extend_from_slice(&self.data[start..end]);
    }
}

/// The size of the line that [`write_line`] writes, excluding the newline.
fn line_size(path: &HgPath, flags: ManifestFlags) -> usize {
    let flag_size = if flags.is_empty() { 0 } else { 1 };
    let null_size = 1;
    path.len() + null_size + HEX_NODE_LENGTH + flag_size
}

/// Appends a line to `new_data` and appends its position to `new_lines`.
fn write_line(
    path: &HgPath,
    state: FileState,
    new_data: &mut Vec<u8>,
    new_lines: &mut Vec<Line>,
) {
    let offset = new_data.len();
    let flags = state.flags;
    new_data.extend_from_slice(path.as_bytes());
    new_data.push(b'\0');
    write!(new_data, "{:x}", state.node).expect("writing to a Vec never fails");
    if let Some(byte) = flags.as_byte() {
        new_data.push(byte);
    }
    new_data.push(b'\n');
    // Exclude the newline from the length.
    let len = new_data.len() - offset - 1;
    new_lines.push(Line { offset: u_u32(offset), len: u_u16(len), flags });
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
    use rand::SeedableRng;
    use rand::prelude::*;

    use super::*;
    use crate::Node;
    use crate::revlog::manifest::ManifestFlags;

    const FLAGS: [ManifestFlags; 4] = [
        ManifestFlags::EMPTY,
        ManifestFlags::EXEC,
        ManifestFlags::LINK,
        ManifestFlags::TREE,
    ];

    fn path(path: &[u8]) -> &HgPath {
        HgPath::new(path)
    }

    fn node(hex: &[u8]) -> Node {
        Node::from_hex(hex).unwrap()
    }

    fn node_n(n: u64) -> Node {
        node(format!("{n:040x}").as_bytes())
    }

    /// The path of entry `i` in a manifest from [`Model::new`].
    fn path_n(i: u64) -> Vec<u8> {
        format!("dir{:02}/file{i:03}.txt", i / 10).into_bytes()
    }

    fn new(data: &[u8]) -> LazyManifest {
        LazyManifest::new(NODE_BYTES_LENGTH, data.to_vec()).unwrap()
    }

    fn collect(
        manifest: &LazyManifest,
    ) -> Result<Vec<DecodedManifestEntry<'_>>, RevlogError> {
        manifest.iter().collect()
    }

    /// A reference manifest represented as a `BTreeMap`.
    struct Model(BTreeMap<Vec<u8>, (Node, ManifestFlags)>);

    impl Model {
        fn from_entries(
            entries: impl IntoIterator<Item = (Vec<u8>, Node, ManifestFlags)>,
        ) -> Self {
            let entries = entries.into_iter();
            Self(entries.map(|(p, node, flags)| (p, (node, flags))).collect())
        }

        /// Creates a manifest of `count` entries in `count / 10` directories.
        fn new(count: u64) -> Self {
            Self::from_entries(
                (0..count)
                    .map(|i| (path_n(i), node_n(i), FLAGS[(i % 4) as usize])),
            )
        }

        fn len(&self) -> usize {
            self.0.len()
        }

        fn paths(&self) -> Vec<Vec<u8>> {
            self.0.keys().cloned().collect()
        }

        fn text(&self) -> Vec<u8> {
            let mut text = Vec::new();
            for (path, &(node, flags)) in &self.0 {
                text.extend_from_slice(path);
                text.push(b'\0');
                write!(text, "{node:x}").expect("Vec write never fails");
                if let Some(byte) = flags.as_byte() {
                    text.push(byte);
                }
                text.push(b'\n');
            }
            text
        }

        fn entries(&self) -> Vec<DecodedManifestEntry<'_>> {
            self.0
                .iter()
                .map(|(p, &(node, flags))| DecodedManifestEntry {
                    path: path(p),
                    node,
                    flags,
                })
                .collect()
        }

        fn get(&self, p: &[u8]) -> Option<DecodedManifestEntry<'_>> {
            self.0.get_key_value(p).map(|(p, &(node, flags))| {
                DecodedManifestEntry { path: path(p), node, flags }
            })
        }

        /// Returns true if it overwrote an existing path.
        fn set(&mut self, p: &[u8], node: Node, flags: ManifestFlags) -> bool {
            self.0.insert(p.to_vec(), (node, flags)).is_some()
        }

        /// Returns true if the path was found.
        fn remove(&mut self, p: &[u8]) -> bool {
            self.0.remove(p).is_some()
        }
    }

    /// A [`LazyManifest`] paired with a [`Model`].
    /// Every edit is applied to both and asserts that they match.
    struct TestManifest {
        manifest: LazyManifest,
        model: Model,
    }

    impl TestManifest {
        fn new(count: u64) -> Self {
            Self::from_model(Model::new(count))
        }

        fn from_model(model: Model) -> Self {
            Self { manifest: new(&model.text()), model }
        }

        fn set(&mut self, p: &[u8], node: Node, flags: ManifestFlags) {
            let overwrote = self.manifest.set(path(p), node, flags);
            assert_eq!(overwrote, self.model.set(p, node, flags));
        }

        fn remove(&mut self, p: &[u8]) {
            let found = self.manifest.remove(path(p));
            assert_eq!(found, self.model.remove(p));
        }

        fn paths(&self) -> Vec<Vec<u8>> {
            self.model.paths()
        }

        /// Asserts that `contains` and `get` agree with the model for each of
        /// `paths`, which may include paths that aren't in the manifest.
        fn check_lookups(&self, paths: &[Vec<u8>]) {
            assert_eq!(self.manifest.len(), self.model.len());
            for p in paths {
                let expected = self.model.get(p);
                assert_eq!(self.manifest.contains(path(p)), expected.is_some());
                assert_eq!(self.manifest.get(path(p)).unwrap(), expected);
            }
        }

        /// Asserts the manifest matches the model before and after compacting,
        /// and that the compacted text parses back to the same entries.
        fn check(&mut self) {
            let Self { manifest, model } = self;
            let expected = model.entries();
            let check_entries = |manifest: &LazyManifest| {
                assert_eq!(manifest.len(), expected.len());
                assert_eq!(manifest.is_empty(), expected.is_empty());
                assert_eq!(collect(manifest).unwrap(), expected);
                for entry in &expected {
                    assert!(manifest.contains(entry.path));
                    assert_eq!(manifest.get(entry.path).unwrap(), Some(*entry));
                }
            };

            check_entries(manifest);
            let text = model.text();
            assert_eq!(manifest.compact(), text);
            check_entries(manifest);
            check_entries(&new(&text));
        }
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

        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            file.txt\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47\n";
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

    #[test]
    fn test_compact() {
        let text = b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n";
        let mut manifest = new(text);

        assert_eq!(manifest.compact(), text);

        let entry_1 = DecodedManifestEntry {
            path: path(b"file.txt"),
            node: node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            flags: ManifestFlags::EMPTY,
        };
        let entry_1_changed =
            DecodedManifestEntry { flags: ManifestFlags::LINK, ..entry_1 };
        let entry_2 = DecodedManifestEntry {
            path: path(b"subdir/other.py"),
            node: node(b"e14fa8304bb04039a7e7e7ffa170715fa2136e47"),
            flags: ManifestFlags::EXEC,
        };

        let overwrote =
            manifest.set(entry_1.path, entry_1.node, entry_1_changed.flags);
        assert!(overwrote);
        assert_eq!(
            manifest.compact(),
            b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5l\n"
        );

        let overwrote = manifest.set(entry_2.path, entry_2.node, entry_2.flags);
        assert!(!overwrote);
        assert_eq!(
            manifest.compact(),
            b"file.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5l\n\
            subdir/other.py\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n"
        );
        assert_eq!(manifest.len(), 2);
        assert!(manifest.contains(entry_1.path));
        assert!(manifest.contains(entry_2.path));
        assert_eq!(manifest.get(entry_1.path).unwrap(), Some(entry_1_changed));
        assert_eq!(manifest.get(entry_2.path).unwrap(), Some(entry_2));
        assert_eq!(collect(&manifest).unwrap(), &[entry_1_changed, entry_2]);

        assert!(manifest.remove(entry_1.path));
        assert_eq!(
            manifest.compact(),
            b"subdir/other.py\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n"
        );
        assert_eq!(manifest.len(), 1);
        assert!(!manifest.contains(entry_1.path));
        assert!(manifest.contains(entry_2.path));
        assert_eq!(manifest.get(entry_1.path).unwrap(), None);
        assert_eq!(manifest.get(entry_2.path).unwrap(), Some(entry_2));
        assert_eq!(collect(&manifest).unwrap(), &[entry_2]);
    }

    #[test]
    fn test_compact_from_empty() {
        let mut manifest = new(b"");

        assert_eq!(manifest.compact(), b"");

        manifest.set(
            path(b"b.txt"),
            node(b"e14fa8304bb04039a7e7e7ffa170715fa2136e47"),
            ManifestFlags::EXEC,
        );
        manifest.set(
            path(b"a.txt"),
            node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            ManifestFlags::EMPTY,
        );

        let expected = b"a.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            b.txt\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n";
        assert_eq!(manifest.compact(), expected);
        assert_eq!(manifest.len(), 2);
        assert_eq!(
            collect(&manifest).unwrap(),
            collect(&new(expected)).unwrap()
        );

        assert!(manifest.remove(path(b"a.txt")));
        assert!(manifest.remove(path(b"b.txt")));

        assert_eq!(manifest.compact(), b"");
        assert_eq!(manifest.len(), 0);
        assert!(manifest.is_empty());
        assert_eq!(collect(&manifest).unwrap(), &[]);
    }

    #[test]
    fn test_compact_edge_cases() {
        let text = b"a.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            c.txt\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n\
            e.txt\x0057b886b07d3f850247a6d7ebf514b60d080f6041l\n";
        let mut manifest = new(text);

        // An insert before the first line, an insert between two lines, an
        // overwrite, a removal, and an insert after the last line.
        manifest.set(
            path(b"0.txt"),
            node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            ManifestFlags::EMPTY,
        );
        manifest.set(
            path(b"b.txt"),
            node(b"e14fa8304bb04039a7e7e7ffa170715fa2136e47"),
            ManifestFlags::EMPTY,
        );
        assert!(manifest.set(
            path(b"c.txt"),
            node(b"57b886b07d3f850247a6d7ebf514b60d080f6041"),
            ManifestFlags::EXEC
        ));
        assert!(manifest.remove(path(b"e.txt")));
        manifest.set(
            path(b"f.txt"),
            node(b"1cba44d2ee7e7f148329f51923e71a319168e2e5"),
            ManifestFlags::LINK,
        );

        let expected = b"0.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            a.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            b.txt\x00e14fa8304bb04039a7e7e7ffa170715fa2136e47\n\
            c.txt\x0057b886b07d3f850247a6d7ebf514b60d080f6041x\n\
            f.txt\x001cba44d2ee7e7f148329f51923e71a319168e2e5l\n";
        assert_eq!(manifest.compact(), expected);
        assert_eq!(
            collect(&manifest).unwrap(),
            collect(&new(expected)).unwrap()
        );
    }

    #[test]
    fn test_compact_runs_of_lines() {
        let mut manifest = TestManifest::new(100);

        // A run of adjacent updates.
        for i in 10..15 {
            manifest.set(&path_n(i), node_n(900 + i), ManifestFlags::TREE);
        }
        // A run of adjacent removals.
        for i in 30..40 {
            manifest.remove(&path_n(i));
        }
        // An update immediately after the removals.
        manifest.set(&path_n(40), node_n(940), ManifestFlags::EXEC);

        manifest.check();
    }

    #[test]
    fn test_compact_consecutive_inserts() {
        let mut manifest = TestManifest::new(20);

        // Several inserts before the first line.
        for i in 0..5u64 {
            let p = format!("aaa{i}.txt").into_bytes();
            manifest.set(&p, node_n(i), ManifestFlags::EMPTY);
        }
        // Several inserts between two existing lines.
        for i in 0..5u64 {
            let letter = char::from(b'a' + i as u8);
            let p = format!("dir00/file000{letter}.txt").into_bytes();
            manifest.set(&p, node_n(i), ManifestFlags::LINK);
        }
        // An update right after the inserts.
        manifest.set(&path_n(1), node_n(901), ManifestFlags::TREE);
        // Several inserts after the last line.
        for i in 0..5u64 {
            let p = format!("zzz{i}.txt").into_bytes();
            manifest.set(&p, node_n(i), ManifestFlags::EXEC);
        }

        manifest.check();
    }

    #[test]
    fn test_compact_remove_all() {
        let mut manifest = TestManifest::new(50);
        for p in manifest.paths() {
            manifest.remove(&p);
        }
        manifest.check();
    }

    #[test]
    fn test_compact_repeatedly() {
        let mut manifest = TestManifest::new(50);

        for round in 0..5u64 {
            for i in 0..3u64 {
                let inserted = format!("new{round}{i}.txt").into_bytes();
                manifest.set(&inserted, node_n(i), ManifestFlags::TREE);
                let updated = path_n(i * 10 + round);
                manifest.set(
                    &updated,
                    node_n(900 + round),
                    ManifestFlags::EXEC,
                );
            }
            manifest.remove(&path_n(round * 10 + 9));

            manifest.check();
        }
    }

    #[test]
    fn test_path_ordering() {
        let names: [&[u8]; 6] =
            [b"a", b"a.txt", b"a/b", b"a/b/c", b"a0", b"ab"];
        let model = Model::from_entries(
            names
                .iter()
                .enumerate()
                .map(|(i, &p)| (p.to_vec(), node_n(i as u64), FLAGS[i % 4])),
        );
        let mut manifest = TestManifest::from_model(model);

        manifest.check();

        // Add new paths by prefixing and suffixing each existing one.
        for (i, name) in names.iter().enumerate() {
            let mut p = name.to_vec();
            p.insert(0, b'.');
            manifest.set(&p, node_n(100 + i as u64), ManifestFlags::EXEC);
            let mut p = name.to_vec();
            p.push(b'.');
            manifest.set(&p, node_n(200 + i as u64), ManifestFlags::EXEC);
        }

        manifest.check();
    }

    #[test]
    fn test_long_paths() {
        let lengths = [1usize, 2, 200, 1000, 5000];
        let model = Model::from_entries(lengths.into_iter().enumerate().map(
            |(i, len)| {
                (vec![b'a' + i as u8; len], node_n(i as u64), FLAGS[i % 4])
            },
        ));
        let mut manifest = TestManifest::from_model(model);

        manifest.check();
        manifest.set(&[b'z'; 2000], node_n(99), ManifestFlags::LINK);
        manifest.remove(&[b'c'; 200]);
        manifest.check();
    }

    #[test]
    fn test_random_operations() {
        let mut pool: Vec<Vec<u8>> = vec![
            b"a".to_vec(),
            b"a.txt".to_vec(),
            b"a/b".to_vec(),
            b"a/b/c".to_vec(),
            b"a0".to_vec(),
            b"z".to_vec(),
            vec![b'x'; 300],
        ];
        pool.extend((0..20).map(path_n));

        for seed in 0..64 {
            let mut rng = rand::rngs::StdRng::seed_from_u64(seed);

            let model = Model::from_entries(pool.iter().filter_map(|p| {
                if !rng.random_bool(0.3) {
                    return None;
                }
                let node = node_n(rng.random_range(0..100));
                let flags = FLAGS[rng.random_range(0..FLAGS.len())];
                Some((p.clone(), node, flags))
            }));
            let mut manifest = TestManifest::from_model(model);

            for _ in 0..30 {
                let p = &pool[rng.random_range(0..pool.len())];
                if rng.random_bool(0.25) {
                    manifest.remove(p);
                } else {
                    let node = node_n(rng.random_range(0..100));
                    let flags = FLAGS[rng.random_range(0..FLAGS.len())];
                    manifest.set(p, node, flags);
                }

                manifest.check_lookups(&pool);

                // Compact from a partially edited state, then keep editing.
                if rng.random_bool(0.2) {
                    manifest.check();
                }
            }

            manifest.check();
        }
    }
}
