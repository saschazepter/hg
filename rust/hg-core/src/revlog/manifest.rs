use std::num::NonZeroU8;
use std::ops::Deref;

use super::diff::lines_prefix_size_low;
use super::diff::CMP_BLK_SIZE;
use super::RevlogType;
use crate::errors::HgError;
use crate::revlog::diff::DeltaCursor;
use crate::revlog::options::RevlogOpenOptions;
use crate::revlog::Node;
use crate::revlog::NodePrefix;
use crate::revlog::Revlog;
use crate::revlog::RevlogError;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::SliceExt;
use crate::vfs::VfsImpl;
use crate::Graph;
use crate::GraphError;
use crate::Revision;
use crate::UncheckedRevision;
use crate::NULL_REVISION;

/// A specialized `Revlog` to work with `manifest` data format.
pub struct Manifestlog {
    /// The generic `revlog` format.
    pub(crate) revlog: Revlog,
}

impl Graph for Manifestlog {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        self.revlog.parents(rev)
    }
}

impl Manifestlog {
    /// Open the `manifest` of a repository given by its root.
    pub fn open(
        store_vfs: &VfsImpl,
        options: RevlogOpenOptions,
    ) -> Result<Self, HgError> {
        let revlog = Revlog::open(
            store_vfs,
            "00manifest.i",
            None,
            options,
            RevlogType::Manifestlog,
        )?;
        Ok(Self { revlog })
    }

    /// Return the `Manifest` for the given node ID.
    ///
    /// Note: this is a node ID in the manifestlog, typically found through
    /// `ChangelogEntry::manifest_node`. It is *not* the node ID of any
    /// changeset.
    ///
    /// See also `Repo::manifest_for_node`
    pub fn data_for_node(
        &self,
        node: NodePrefix,
    ) -> Result<Manifest, RevlogError> {
        let rev = self.revlog.rev_from_node(node)?;
        self.data(rev)
    }

    /// Return the `Manifest` of a given revision number.
    ///
    /// Note: this is a revision number in the manifestlog, *not* of any
    /// changeset.
    ///
    /// See also `Repo::manifest_for_rev`
    pub fn data_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<Manifest, RevlogError> {
        let bytes = self.revlog.get_data_for_unchecked_rev(rev)?.into_owned();
        Ok(Manifest { bytes: Box::new(bytes) })
    }

    /// Same as [`Self::data_for_unchecked_rev`] for a checked [`Revision`]
    pub fn data(&self, rev: Revision) -> Result<Manifest, RevlogError> {
        let bytes = self.revlog.get_data(rev)?.into_owned();
        Ok(Manifest { bytes: Box::new(bytes) })
    }

    /// Returns a manifest containing entries for `rev` that are not in its
    /// parents. It is inexact because it might return a superset of this.
    /// Equivalent to `manifestctx.read_delta_parents(exact=False)` in Python.
    pub fn inexact_data_delta_parents(
        &self,
        rev: Revision,
    ) -> Result<Manifest, RevlogError> {
        let delta_parent = self.revlog.delta_parent(rev);
        let parents = self.parents(rev).map_err(|err| {
            RevlogError::corrupted(format!("rev {rev}: {err}"))
        })?;
        if delta_parent == NULL_REVISION || !parents.contains(&delta_parent) {
            return self.data(rev);
        }
        let mut bytes = vec![];
        for chunk in self.revlog.get_data_incr(rev)?.as_patch_list()?.chunks {
            bytes.extend_from_slice(chunk.data);
        }
        Ok(Manifest { bytes: Box::new(bytes) })
    }
}

/// `Manifestlog` entry which knows how to interpret the `manifest` data bytes.
pub struct Manifest {
    /// Format for a manifest: flat sequence of variable-size entries,
    /// sorted by path, each as:
    ///
    /// ```text
    /// <path> \0 <hex_node_id> <flags> \n
    /// ```
    ///
    /// The last entry is also terminated by a newline character.
    /// Flags is one of `b""` (the empty string), `b"x"`, `b"l"`, or `b"t"`.
    bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
}

impl Manifest {
    /// Return a new empty manifest
    pub fn empty() -> Self {
        Self { bytes: Box::new(vec![]) }
    }

    pub fn from_bytes(
        bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    ) -> Self {
        Self { bytes }
    }

    pub fn iter(&self) -> impl Iterator<Item = Result<ManifestEntry, HgError>> {
        self.bytes
            .split(|b| b == &b'\n')
            .filter(|line| !line.is_empty())
            .map(ManifestEntry::from_raw)
    }

    /// If the given path is in this manifest, return its filelog node ID
    pub fn find_by_path(
        &self,
        path: &HgPath,
    ) -> Result<Option<ManifestEntry>, HgError> {
        use std::cmp::Ordering::*;
        let path = path.as_bytes();
        // Both boundaries of this `&[u8]` slice are always at the boundary of
        // an entry
        let mut bytes: &[u8] = &self.bytes;

        // Binary search algorithm derived from `[T]::binary_search_by`
        // <https://github.com/rust-lang/rust/blob/1.57.0/library/core/src/slice/mod.rs#L2221>
        // except we don’t have a slice of entries. Instead we jump to the
        // middle of the byte slice and look around for entry delimiters
        // (newlines).
        while let Some(entry_range) = Self::find_entry_near_middle_of(bytes)? {
            let (entry_path, rest) =
                ManifestEntry::split_path(&bytes[entry_range.clone()])?;
            let cmp = entry_path.cmp(path);
            if cmp == Less {
                let after_newline = entry_range.end + 1;
                bytes = &bytes[after_newline..];
            } else if cmp == Greater {
                bytes = &bytes[..entry_range.start];
            } else {
                return Ok(Some(ManifestEntry::from_path_and_rest(
                    entry_path, rest,
                )));
            }
        }
        Ok(None)
    }

    /// If there is at least one, return the byte range of an entry *excluding*
    /// the final newline.
    fn find_entry_near_middle_of(
        bytes: &[u8],
    ) -> Result<Option<std::ops::Range<usize>>, HgError> {
        let len = bytes.len();
        if len > 0 {
            let middle = bytes.len() / 2;
            // Integer division rounds down, so `middle < len`.
            let (before, after) = bytes.split_at(middle);
            let entry_start = match memchr::memrchr(b'\n', before) {
                Some(i) => i + 1,
                None => 0, // We choose the first entry in `bytes`
            };
            let entry_end = match memchr::memchr(b'\n', after) {
                Some(i) => {
                    // No `+ 1` here to exclude this newline from the range
                    middle + i
                }
                None => {
                    // In a well-formed manifest:
                    //
                    // * Since `len > 0`, `bytes` contains at least one entry
                    // * Every entry ends with a newline
                    // * Since `middle < len`, `after` contains at least the
                    //   newline at the end of the last entry of `bytes`.
                    //
                    // We didn’t find a newline, so this manifest is not
                    // well-formed.
                    return Err(HgError::corrupted(
                        "manifest entry without \\n delimiter",
                    ));
                }
            };
            Ok(Some(entry_start..entry_end))
        } else {
            // len == 0
            Ok(None)
        }
    }

    #[tracing::instrument(level = "trace", skip_all)]
    pub fn diff<'m1: 'm_any, 'm2: 'm_any, 'm_any>(
        &'m1 self,
        other: &'m2 Manifest,
    ) -> Result<ManifestDiff<'m_any>, HgError> {
        let mut res = Vec::new();
        for lines in SyncLineIterator::new(&self.bytes, &other.bytes) {
            match lines {
                (Some(l), None) => res.push((Some(l.into_entry()?), None)),
                (None, Some(l)) => res.push((None, Some(l.into_entry()?))),
                (Some(l1), Some(l2)) => {
                    if l1.data() != l2.data() {
                        res.push((
                            Some(l1.into_entry()?),
                            Some(l2.into_entry()?),
                        ))
                    }
                }
                (None, None) => unreachable!(
                    "iteration continue despite no remaining lines."
                ),
            };
        }

        Ok(res)
    }
}

pub type ManifestDiff<'a> =
    Vec<(Option<ManifestEntry<'a>>, Option<ManifestEntry<'a>>)>;

/// Represents the flags of a given [`ManifestEntry`].
#[derive(Copy, Clone, Debug, PartialEq)]
pub struct ManifestFlags(Option<NonZeroU8>);

impl ManifestFlags {
    pub fn new_empty() -> Self {
        Self(None)
    }

    pub fn new_link() -> Self {
        Self(Some(b'l'.try_into().unwrap()))
    }

    pub fn new_exec() -> Self {
        Self(Some(b'x'.try_into().unwrap()))
    }

    pub fn new_tree() -> Self {
        Self(Some(b't'.try_into().unwrap()))
    }

    /// Whether this path is a symlink
    pub fn is_link(&self) -> bool {
        self.is_flag(b'l')
    }

    /// Whether this path has the executable permission set
    pub fn is_exec(&self) -> bool {
        self.is_flag(b'x')
    }

    /// Whether this path is a tree in the context of treemanifest
    pub fn is_tree(&self) -> bool {
        self.is_flag(b't')
    }

    fn is_flag(&self, flag: u8) -> bool {
        self.0.map(|f| f == NonZeroU8::new(flag).unwrap()).unwrap_or(false)
    }
}

/// A manifest line is a Lazy ManifestEntry used during comparison
#[derive(Copy, Clone)]
struct ManifestLine<'a> {
    /// The size of that manifest line
    line: &'a [u8],
    /// An optional length of the filename in case it was already computed
    ///
    /// A value < 0 means the value is not initialized.
    filename_len: i32,
}

impl<'a> ManifestLine<'a> {
    /// Grabs the next line from a byte slice and returns the line if any,
    /// with the remainder of the byte slice
    fn grab_next(data: &'a [u8]) -> (Option<ManifestLine<'a>>, &'a [u8]) {
        if !data.is_empty() {
            match memchr::memchr(b'\n', data) {
                None => (None, data),
                Some(pos) => (
                    Some(Self { line: &data[0..pos + 1], filename_len: -1 }),
                    &data[pos + 1..],
                ),
            }
        } else {
            (None, data)
        }
    }

    /// Size of the line in bytes
    fn size(&self) -> u32 {
        self.line.len().try_into().expect("manifest line larger than 4GB?")
    }

    /// The filename part of that line
    ///
    /// When accessing this, the `filename_len` is cached to speedup future
    /// access to the "data" part.
    fn filename(&mut self) -> &'a [u8] {
        if self.filename_len < 0 {
            self.filename_len = match memchr::memchr(b'\0', self.line) {
                None => 0, // no file name should not happen treat it as empty
                Some(pos) => pos.try_into().expect("manifest larger than 2GB?"),
            };
        }
        debug_assert!(self.filename_len > 0);
        &self.line[0..self.filename_len as usize]
    }

    /// The non-filename part of this manifest line
    pub(self) fn data(self) -> &'a [u8] {
        debug_assert!(self.filename_len > 0);
        &self.line[self.filename_len as usize..self.line.len() - 1]
    }

    fn into_entry(self) -> Result<ManifestEntry<'a>, HgError> {
        if self.line.is_empty() {
            Err(HgError::corrupted("empty manifest line"))
        } else if self.line[self.line.len() - 1] != b'\n' {
            Err(HgError::corrupted("manifest line not terminated by '\\n'"))
        } else if self.filename_len == 0 {
            if self.line[0] == b'\0' {
                Err(HgError::corrupted("manifest entry with empty filename"))
            } else {
                Err(HgError::corrupted("manifest entry without \\0 delimiter"))
            }
        } else if self.filename_len < 0 {
            ManifestEntry::from_raw(&self.line[..self.line.len() - 1])
        } else {
            let path = &self.line[0..self.filename_len as usize];
            let (_, rest) = self
                .data()
                .split_first()
                .expect("previously seen \\0 has vanished");
            Ok(ManifestEntry::from_path_and_rest(path, rest))
        }
    }
}

/// Iterate over two manifests and yield the pair of line associated with each
/// filename.
///
/// If the manifest are not sorted, this is expected to misbehave
struct SyncLineIterator<'a> {
    m1_data: &'a [u8],
    m1_line: Option<ManifestLine<'a>>,
    m2_data: &'a [u8],
    m2_line: Option<ManifestLine<'a>>,
}

impl<'a> SyncLineIterator<'a> {
    fn new(m1: &'a [u8], m2: &'a [u8]) -> Self {
        let (m1_line, m1_data) = ManifestLine::grab_next(m1);
        let (m2_line, m2_data) = ManifestLine::grab_next(m2);
        Self { m1_data, m1_line, m2_data, m2_line }
    }
}

impl<'a> Iterator for SyncLineIterator<'a> {
    type Item = (Option<ManifestLine<'a>>, Option<ManifestLine<'a>>);

    fn next(&mut self) -> Option<Self::Item> {
        let result = match (&mut self.m1_line, &mut self.m2_line) {
            (None, None) => (None, None),
            (Some(line), None) => (Some(*line), None),
            (None, Some(line)) => (None, Some(*line)),
            (Some(l1), Some(l2)) => match l1.filename().cmp(l2.filename()) {
                std::cmp::Ordering::Less => (Some(*l1), None),
                std::cmp::Ordering::Equal => (Some(*l1), Some(*l2)),
                std::cmp::Ordering::Greater => (None, Some(*l2)),
            },
        };
        if result.0.is_some() {
            (self.m1_line, self.m1_data) =
                ManifestLine::grab_next(self.m1_data);
        }
        if result.1.is_some() {
            (self.m2_line, self.m2_data) =
                ManifestLine::grab_next(self.m2_data);
        }
        match result {
            (None, None) => None,
            r => Some(r),
        }
    }
}

/// Result of binary diffing some part of two manifests
enum Section {
    /// Content is the same on both side (size of both)
    Same(u32),
    /// Content is different on each side, (size of m1, size of m2)
    Changed(u32, u32),
}

/// detect the section that are similar or different in two manifest we compare
fn changed_sections<'a>(
    m1: &'a [u8],
    m2: &'a [u8],
) -> impl Iterator<Item = Section> + 'a {
    let mut m1 = m1;
    let mut m2 = m2;
    let mut same_streak = 0;

    let mut current_iter = None;

    std::iter::from_fn(move || {
        match (m1, m2) {
            ([], []) => return None,
            (tail, []) => {
                let size = tail.len();
                m1 = &m1[size..];
                debug_assert!(m1.is_empty());
                debug_assert!(m2.is_empty());
                return Some(Section::Changed(
                    size.try_into().expect("patch data bigger than 2GB"),
                    0,
                ));
            }
            ([], tail) => {
                let size = tail.len();
                m2 = &m2[size..];
                debug_assert!(m1.is_empty());
                debug_assert!(m2.is_empty());
                return Some(Section::Changed(
                    0,
                    size.try_into().expect("patch data bigger than 2GB"),
                ));
            }
            (_, _) => (),
        }
        // if we have seen enough "same" content from the iterator, lets try
        // some SIMD comparison first
        if same_streak > CMP_BLK_SIZE {
            current_iter.take();
        }
        if current_iter.is_none() {
            let size = lines_prefix_size_low(m1, m2);
            if size > 0 {
                m1 = &m1[size..];
                m2 = &m2[size..];
            }
            // we always create an iterator from there as we should not run
            // prefix matching again until the difference have been
            // processed
            current_iter = Some(SyncLineIterator::new(m1, m2));
            same_streak = 0;
            if size > 0 {
                return Some(Section::Same(size as u32));
            }
        }
        Some(
            match current_iter
                .as_mut()
                .expect("programming error, iterator missing")
                .next()
                .expect("attempted iteration on empty manifest")
            {
                (Some(l), None) => {
                    let size = l.size();
                    m1 = &m1[size as usize..];
                    Section::Changed(size, 0)
                }
                (None, Some(l)) => {
                    let size = l.size();
                    m2 = &m2[size as usize..];
                    Section::Changed(0, size)
                }
                (Some(l1), Some(l2)) => {
                    let l1_size = l1.size();
                    let l2_size = l2.size();
                    m1 = &m1[l1_size as usize..];
                    m2 = &m2[l2_size as usize..];
                    if l1.data() == l2.data() {
                        same_streak += l1_size as usize;
                        debug_assert!(l1_size == l2_size);
                        Section::Same(l1_size)
                    } else {
                        Section::Changed(l1_size, l2_size)
                    }
                }
                (None, None) => unreachable!(
                    "iteration continue despite no remaining lines."
                ),
            },
        )
    })
}

/// Compute a binary delta between two flat manifest texts
pub fn manifest_delta(m1: &[u8], m2: &[u8]) -> Vec<u8> {
    let mut delta = vec![];
    // our current work position in the two manifest
    let mut m1_offset = 0u32;
    let mut m2_offset = 0u32;

    let mut cursor: Option<DeltaCursor> = None;

    for section in changed_sections(m1, m2) {
        match section {
            Section::Same(size) => {
                m1_offset += size;
                m2_offset += size;
                // We have a common block so any existing cursor need flushing
                if let Some(change) = cursor.take() {
                    change.into_chunk().write(&mut delta);
                }
            }
            Section::Changed(size_1, size_2) => {
                // If a hunk is still around, we must be able to merge with it.
                if let Some(c) = cursor.as_mut() {
                    c.extend(size_1, size_2)
                } else {
                    cursor = Some(DeltaCursor::new(
                        m1_offset,
                        m1_offset + size_1,
                        m2_offset,
                        m2_offset + size_2,
                        m2,
                    ));
                }
                m1_offset += size_1;
                m2_offset += size_2;
            }
        }
    }
    if let Some(change) = cursor.take() {
        change.into_chunk().write(&mut delta);
    };
    delta
}

/// `Manifestlog` entry which knows how to interpret the `manifest` data bytes.
#[derive(PartialEq)]
pub struct ManifestEntry<'manifest> {
    pub path: &'manifest HgPath,
    pub hex_node_id: &'manifest [u8],
    pub flags: ManifestFlags,
}

impl std::fmt::Debug for ManifestEntry<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "ManifestEntry({:x}:{:?}:'{}')",
            self.node_id().unwrap(),
            &self.flags,
            self.path,
        )
    }
}

impl<'a> ManifestEntry<'a> {
    fn split_path(bytes: &[u8]) -> Result<(&[u8], &[u8]), HgError> {
        bytes.split_2(b'\0').ok_or_else(|| {
            HgError::corrupted("manifest entry without \\0 delimiter")
        })
    }

    fn from_path_and_rest(path: &'a [u8], rest: &'a [u8]) -> Self {
        let (hex_node_id, flags) = match rest.split_last() {
            Some((&b'x', rest)) => (rest, Some(b'x')),
            Some((&b'l', rest)) => (rest, Some(b'l')),
            Some((&b't', rest)) => (rest, Some(b't')),
            _ => (rest, None),
        };
        Self {
            path: HgPath::new(path),
            hex_node_id,
            flags: ManifestFlags(
                flags.map(|f| f.try_into().expect("invalid flag")),
            ),
        }
    }

    fn from_raw(bytes: &'a [u8]) -> Result<Self, HgError> {
        let (path, rest) = Self::split_path(bytes)?;
        Ok(Self::from_path_and_rest(path, rest))
    }

    pub fn node_id(&self) -> Result<Node, HgError> {
        Node::from_hex_for_repo(self.hex_node_id)
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::revlog::inner_revlog::CoreRevisionBuffer;
    use crate::revlog::inner_revlog::RevisionBuffer;
    use crate::revlog::Revlog;

    /// Check that applying the diff from m1 to m2 is the same as m2
    fn identity_check(m1: &[u8], m2: &[u8], delta: &[u8]) {
        let mut computed_m2 = CoreRevisionBuffer::new();
        Revlog::build_data_from_deltas(&mut computed_m2, m1, &[delta]).unwrap();
        assert_eq!(
            String::from_utf8_lossy(&computed_m2.finish()),
            String::from_utf8_lossy(m2)
        );
    }

    fn test_roundtrip(m1: &[u8], m2: &[u8]) {
        let delta = manifest_delta(m1, m2);
        identity_check(m1, m2, &delta)
    }

    #[test]
    fn test_manifest_diff_simple() {
        let m1 =
            b"contrib/perf.py\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            contrib/phab-clean.py\0e14fa8304bb04039a7e7e7ffa170715fa2136e47x\n";
        let m2 =
            b"contrib/perf.py\x001cba44d2ee7e7f148329f51923e71a319168e2e5\n\
            contrib/phab-clean.py\0e14fa8304bb04039a70ccdcfa170715fa2136e47\n";

        // delete all
        test_roundtrip(&m1[..], &[]);

        // add all content
        test_roundtrip(&[], &m1[..]);
        // identical
        test_roundtrip(&m1[..], &m1[..]);
        assert_eq!(manifest_delta(&m1[..], &m1[..]).len(), 0);
        test_roundtrip(&m2[..], &m2[..]);
        assert_eq!(manifest_delta(&m2[..], &m2[..]).len(), 0);

        // changing a line
        test_roundtrip(&m1[..], &m2[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);

        // changing a line
        test_roundtrip(&m2[..], &m1[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);
    }

    #[test]
    fn test_manifest_diff_complex() {
        let m1 = b"a\0abc\nb\0abc\nc\0abc\n";

        // Identical, diff should be empty
        test_roundtrip(&m1[..], &m1[..]);
        assert_eq!(manifest_delta(&m1[..], &m1[..]).len(), 0);

        // Removed a path at the start
        let m2 = b"b\0abc\nc\0abc\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_eq!(manifest_delta(&m1[..], &m2[..]).len(), 12);

        // Removed a path in the middle
        let m2 = b"a\0abc\nc\0abc\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_eq!(manifest_delta(&m1[..], &m2[..]).len(), 12);

        // Added a path in the middle
        test_roundtrip(&m2[..], &m1[..]);
        assert_ne!(manifest_delta(&m2[..], &m1[..]).len(), 0);

        // Changed a node/flag in the middle, should replace
        let m2 = b"a\0abc\nb\0bcd\nc\0abc\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);
    }

    #[test]
    fn test_manifest_diff_actual_cases() {
        // Removed two paths in the middle
        let m1 = b"a.txt\x00b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3\n\
        aa.txt\x00a4bdc161c8fbb523c9a60409603f8710ff49a571\n\
        b.txt\x001e88685f5ddec574a34c70af492f95b6debc8741\n\
        c.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        cc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        ccc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        d.txt\x001e88685f5ddec574a34c70af492f95b6debc8741\n\
        e.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n";
        let m2 = b"a.txt\x00b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3\n\
        aa.txt\x00a4bdc161c8fbb523c9a60409603f8710ff49a571\n\
        c.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        cc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        ccc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        e.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);

        // Removed two paths and added one
        let m2 = b"a.txt\x00b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3\n\
        aa.txt\x00a4bdc161c8fbb523c9a60409603f8710ff49a571\n\
        bb.txt\x0004c6faf8a9fdd848a5304dfc1704749a374dff44\n\
        c.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        cc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        ccc.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n\
        e.txt\x00149da44f2a4e14f488b7bd4157945a9837408c00\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);

        // Updated the last path
        let m1 = b"bar\x00b004912a8510032a0350a74daa2803dadfb00e12\n\
        baz\x00354ae8da6e890359ef49ade27b68bbc361f3ca88\n\
        foo\x0022fb50216c01fd6a604494be1bcb05c8d2d07641\n";

        let m2 = b"bar\x00b004912a8510032a0350a74daa2803dadfb00e12\n\
        baz\x00354ae8da6e890359ef49ade27b68bbc361f3ca88\n\
        foo\x00263143458f3c42bd4b185a2dc56c5f1593c17c3f\n";
        test_roundtrip(&m1[..], &m2[..]);
        assert_ne!(manifest_delta(&m1[..], &m2[..]).len(), 0);
    }
}
