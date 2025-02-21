use std::collections::{HashMap, HashSet};
use std::fmt::Debug;
use std::ops::Deref;
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use bitvec::prelude::*;
use byteorder::{BigEndian, ByteOrder};
use bytes_cast::{unaligned, BytesCast};

use super::{NodePrefix, RevlogError, RevlogIndex, REVIDX_KNOWN_FLAGS};
use crate::errors::HgError;
use crate::revlog::node::{
    Node, NODE_BYTES_LENGTH, NULL_NODE, STORED_NODE_ID_BYTES,
};
use crate::revlog::{Revision, NULL_REVISION};
use crate::{
    dagops, BaseRevision, FastHashMap, Graph, GraphError, UncheckedRevision,
};

pub const INDEX_ENTRY_SIZE: usize = 64;
pub const INDEX_HEADER_SIZE: usize = 4;
pub const COMPRESSION_MODE_INLINE: u8 = 2;

#[derive(Debug)]
pub struct IndexHeader {
    pub(super) header_bytes: [u8; INDEX_HEADER_SIZE],
}

#[derive(Copy, Clone, Debug)]
pub struct IndexHeaderFlags {
    flags: u16,
}

/// Corresponds to the high bits of `_format_flags` in python
impl IndexHeaderFlags {
    /// Corresponds to FLAG_INLINE_DATA in python
    pub fn is_inline(self) -> bool {
        self.flags & 1 != 0
    }
    /// Corresponds to FLAG_GENERALDELTA in python
    pub fn uses_generaldelta(self) -> bool {
        self.flags & 2 != 0
    }
}

/// Corresponds to the INDEX_HEADER structure,
/// which is parsed as a `header` variable in `_loadindex` in `revlog.py`
impl IndexHeader {
    fn format_flags(&self) -> IndexHeaderFlags {
        // No "unknown flags" check here, unlike in python. Maybe there should
        // be.
        IndexHeaderFlags {
            flags: BigEndian::read_u16(&self.header_bytes[0..2]),
        }
    }

    /// The only revlog version currently supported by rhg.
    const REVLOGV1: u16 = 1;

    /// Corresponds to `_format_version` in Python.
    fn format_version(&self) -> u16 {
        BigEndian::read_u16(&self.header_bytes[2..4])
    }

    pub fn parse(index_bytes: &[u8]) -> Result<IndexHeader, HgError> {
        if index_bytes.len() < 4 {
            return Err(HgError::corrupted(
                "corrupted revlog: can't read the index format header",
            ));
        }
        Ok(IndexHeader {
            header_bytes: {
                let bytes: [u8; 4] =
                    index_bytes[0..4].try_into().expect("impossible");
                bytes
            },
        })
    }
}

/// Abstracts the access to the index bytes since they can be spread between
/// the immutable (bytes) part and the mutable (added) part if any appends
/// happened. This makes it transparent for the callers.
struct IndexData {
    /// Immutable bytes, most likely taken from disk
    bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    /// Used when stripping index contents, keeps track of the start of the
    /// first stripped revision, which is used to give a slice of the
    /// `bytes` field.
    truncation: Option<usize>,
    /// Bytes that were added after reading the index
    added: Vec<u8>,
    first_entry: [u8; INDEX_ENTRY_SIZE],
}

impl IndexData {
    pub fn new(bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>) -> Self {
        let mut first_entry = [0; INDEX_ENTRY_SIZE];
        if bytes.len() >= INDEX_ENTRY_SIZE {
            first_entry[INDEX_HEADER_SIZE..]
                .copy_from_slice(&bytes[INDEX_HEADER_SIZE..INDEX_ENTRY_SIZE])
        }
        Self {
            bytes,
            truncation: None,
            added: vec![],
            first_entry,
        }
    }

    pub fn len(&self) -> usize {
        match self.truncation {
            Some(truncation) => truncation + self.added.len(),
            None => self.bytes.len() + self.added.len(),
        }
    }

    fn remove(
        &mut self,
        rev: Revision,
        offsets: Option<&[usize]>,
    ) -> Result<(), RevlogError> {
        let rev = rev.0 as usize;
        let truncation = if let Some(offsets) = offsets {
            offsets[rev]
        } else {
            rev * INDEX_ENTRY_SIZE
        };
        if truncation < self.bytes.len() {
            self.truncation = Some(truncation);
            self.added.clear();
        } else {
            self.added.truncate(truncation - self.bytes.len());
        }
        Ok(())
    }

    fn is_new(&self) -> bool {
        self.bytes.is_empty()
    }
}

impl std::ops::Index<std::ops::Range<usize>> for IndexData {
    type Output = [u8];

    fn index(&self, index: std::ops::Range<usize>) -> &Self::Output {
        let start = index.start;
        let end = index.end;
        let immutable_len = match self.truncation {
            Some(truncation) => truncation,
            None => self.bytes.len(),
        };
        if start < immutable_len {
            if end > immutable_len {
                panic!("index data cannot span existing and added ranges");
            }
            &self.bytes[index]
        } else {
            &self.added[start - immutable_len..end - immutable_len]
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct RevisionDataParams {
    pub flags: u16,
    pub data_offset: u64,
    pub data_compressed_length: i32,
    pub data_uncompressed_length: i32,
    pub data_delta_base: i32,
    pub link_rev: i32,
    pub parent_rev_1: i32,
    pub parent_rev_2: i32,
    pub node_id: [u8; NODE_BYTES_LENGTH],
    pub _sidedata_offset: u64,
    pub _sidedata_compressed_length: i32,
    pub data_compression_mode: u8,
    pub _sidedata_compression_mode: u8,
    pub _rank: i32,
}

impl Default for RevisionDataParams {
    fn default() -> Self {
        Self {
            flags: 0,
            data_offset: 0,
            data_compressed_length: 0,
            data_uncompressed_length: 0,
            data_delta_base: -1,
            link_rev: -1,
            parent_rev_1: -1,
            parent_rev_2: -1,
            node_id: [0; NODE_BYTES_LENGTH],
            _sidedata_offset: 0,
            _sidedata_compressed_length: 0,
            data_compression_mode: COMPRESSION_MODE_INLINE,
            _sidedata_compression_mode: COMPRESSION_MODE_INLINE,
            _rank: -1,
        }
    }
}

#[derive(BytesCast)]
#[repr(C)]
pub struct RevisionDataV1 {
    data_offset_or_flags: unaligned::U64Be,
    data_compressed_length: unaligned::I32Be,
    data_uncompressed_length: unaligned::I32Be,
    data_delta_base: unaligned::I32Be,
    link_rev: unaligned::I32Be,
    parent_rev_1: unaligned::I32Be,
    parent_rev_2: unaligned::I32Be,
    node_id: [u8; STORED_NODE_ID_BYTES],
}

fn _static_assert_size_of_revision_data_v1() {
    let _ = std::mem::transmute::<RevisionDataV1, [u8; 64]>;
}

impl RevisionDataParams {
    pub fn validate(&self) -> Result<(), RevlogError> {
        if self.flags & !REVIDX_KNOWN_FLAGS != 0 {
            return Err(RevlogError::corrupted(format!(
                "unknown revlog index flags: {}",
                self.flags
            )));
        }
        if self.data_compression_mode != COMPRESSION_MODE_INLINE {
            return Err(RevlogError::corrupted(format!(
                "invalid data compression mode: {}",
                self.data_compression_mode
            )));
        }
        // FIXME isn't this only for v2 or changelog v2?
        if self._sidedata_compression_mode != COMPRESSION_MODE_INLINE {
            return Err(RevlogError::corrupted(format!(
                "invalid sidedata compression mode: {}",
                self._sidedata_compression_mode
            )));
        }
        Ok(())
    }

    pub fn into_v1(self) -> RevisionDataV1 {
        let data_offset_or_flags = self.data_offset << 16 | self.flags as u64;
        let mut node_id = [0; STORED_NODE_ID_BYTES];
        node_id[..NODE_BYTES_LENGTH].copy_from_slice(&self.node_id);
        RevisionDataV1 {
            data_offset_or_flags: data_offset_or_flags.into(),
            data_compressed_length: self.data_compressed_length.into(),
            data_uncompressed_length: self.data_uncompressed_length.into(),
            data_delta_base: self.data_delta_base.into(),
            link_rev: self.link_rev.into(),
            parent_rev_1: self.parent_rev_1.into(),
            parent_rev_2: self.parent_rev_2.into(),
            node_id,
        }
    }
}

/// A Revlog index
pub struct Index {
    bytes: IndexData,
    /// Offsets of starts of index blocks.
    /// Only needed when the index is interleaved with data.
    offsets: RwLock<Option<Vec<usize>>>,
    uses_generaldelta: bool,
    is_inline: bool,
    /// Cache of (head_revisions, filtered_revisions)
    ///
    /// The head revisions in this index, kept in sync. Should
    /// be accessed via the [`Self::head_revs`] method.
    /// The last filtered revisions in this index, used to make sure
    /// we haven't changed filters when returning the cached `head_revs`.
    pub(super) head_revs: RwLock<(Vec<Revision>, HashSet<Revision>)>,
}

impl Debug for Index {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Index")
            .field("offsets", &self.offsets)
            .field("uses_generaldelta", &self.uses_generaldelta)
            .finish()
    }
}

impl Graph for Index {
    #[inline(always)]
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        let err = || GraphError::ParentOutOfRange(rev);
        match self.get_entry(rev) {
            Some(entry) => {
                // The C implementation checks that the parents are valid
                // before returning
                Ok([
                    self.check_revision(entry.p1()).ok_or_else(err)?,
                    self.check_revision(entry.p2()).ok_or_else(err)?,
                ])
            }
            None => Ok([NULL_REVISION, NULL_REVISION]),
        }
    }
}

/// A cache suitable for find_snapshots
///
/// Logically equivalent to a mapping whose keys are [`BaseRevision`] and
/// values sets of [`BaseRevision`]
///
/// TODO the dubious part is insisting that errors must be RevlogError
/// we would probably need to sprinkle some magic here, such as an associated
/// type that would be `Into<RevlogError>` but even that would not be
/// satisfactory, as errors potentially have nothing to do with the revlog.
pub trait SnapshotsCache {
    fn insert_for(
        &mut self,
        rev: BaseRevision,
        value: BaseRevision,
    ) -> Result<(), RevlogError>;
}

impl SnapshotsCache for FastHashMap<BaseRevision, HashSet<BaseRevision>> {
    fn insert_for(
        &mut self,
        rev: BaseRevision,
        value: BaseRevision,
    ) -> Result<(), RevlogError> {
        let all_values = self.entry(rev).or_default();
        all_values.insert(value);
        Ok(())
    }
}

impl Index {
    /// Create an index from bytes.
    /// Calculate the start of each entry when is_inline is true.
    pub fn new(
        bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
        default_header: IndexHeader,
    ) -> Result<Self, HgError> {
        let header = if bytes.len() < INDEX_ENTRY_SIZE {
            default_header
        } else {
            IndexHeader::parse(bytes.as_ref())?
        };

        if header.format_version() != IndexHeader::REVLOGV1 {
            // A proper new version should have had a repo/store
            // requirement.
            return Err(HgError::corrupted("unsupported revlog version"));
        }

        let uses_generaldelta = header.format_flags().uses_generaldelta();

        if header.format_flags().is_inline() {
            let mut offset: usize = 0;
            let mut offsets = Vec::new();

            while offset + INDEX_ENTRY_SIZE <= bytes.len() {
                offsets.push(offset);
                let end = offset + INDEX_ENTRY_SIZE;
                let entry = IndexEntry {
                    bytes: &bytes[offset..end],
                };

                offset += INDEX_ENTRY_SIZE + entry.compressed_len() as usize;
            }

            if offset == bytes.len() {
                Ok(Self {
                    bytes: IndexData::new(bytes),
                    offsets: RwLock::new(Some(offsets)),
                    uses_generaldelta,
                    is_inline: true,
                    head_revs: RwLock::new((vec![], HashSet::new())),
                })
            } else {
                Err(HgError::corrupted("unexpected inline revlog length"))
            }
        } else {
            Ok(Self {
                bytes: IndexData::new(bytes),
                offsets: RwLock::new(None),
                uses_generaldelta,
                is_inline: false,
                head_revs: RwLock::new((vec![], HashSet::new())),
            })
        }
    }

    pub fn uses_generaldelta(&self) -> bool {
        self.uses_generaldelta
    }

    /// Value of the inline flag.
    pub fn is_inline(&self) -> bool {
        self.is_inline
    }

    /// Return a slice of bytes if `revlog` is inline. Panic if not.
    pub fn data(&self, start: usize, end: usize) -> &[u8] {
        if !self.is_inline() {
            panic!("tried to access data in the index of a revlog that is not inline");
        }
        &self.bytes[start..end]
    }

    /// Return number of entries of the revlog index.
    pub fn len(&self) -> usize {
        if self.is_inline() {
            (*self.get_offsets())
                .as_ref()
                .expect("inline should have offsets")
                .len()
        } else {
            self.bytes.len() / INDEX_ENTRY_SIZE
        }
    }

    /// Same as `rev_from_node`, without using a persistent nodemap
    ///
    /// This is used as fallback when a persistent nodemap is not present.
    /// This happens when the persistent-nodemap experimental feature is not
    /// enabled, or for small revlogs.
    pub fn rev_from_node_no_persistent_nodemap(
        &self,
        node: NodePrefix,
    ) -> Result<Revision, RevlogError> {
        // Linear scan of the revlog
        // TODO: consider building a non-persistent nodemap in memory to
        // optimize these cases.
        let mut found_by_prefix = None;
        for rev in (-1..self.len() as BaseRevision).rev() {
            let rev = Revision(rev as BaseRevision);
            let candidate_node = if rev == Revision(-1) {
                NULL_NODE
            } else {
                let index_entry = self.get_entry(rev).ok_or_else(|| {
                    HgError::corrupted(
                        "revlog references a revision not in the index",
                    )
                })?;
                *index_entry.hash()
            };
            if node == candidate_node {
                return Ok(rev);
            }
            if node.is_prefix_of(&candidate_node) {
                if found_by_prefix.is_some() {
                    return Err(RevlogError::AmbiguousPrefix(format!(
                        "{:x}",
                        node
                    )));
                }
                found_by_prefix = Some(rev)
            }
        }
        found_by_prefix
            .ok_or_else(|| RevlogError::InvalidRevision(format!("{:x}", node)))
    }

    pub fn get_offsets(&self) -> RwLockReadGuard<Option<Vec<usize>>> {
        assert!(self.is_inline());
        {
            // Wrap in a block to drop the read guard
            let mut offsets = self.offsets.write().unwrap();
            if offsets.is_none() {
                offsets.replace(inline_scan(&self.bytes.bytes).1);
            }
        }
        self.offsets.read().unwrap()
    }

    pub fn get_offsets_mut(&mut self) -> RwLockWriteGuard<Option<Vec<usize>>> {
        assert!(self.is_inline());
        let mut offsets = self.offsets.write().unwrap();
        if offsets.is_none() {
            offsets.replace(inline_scan(&self.bytes.bytes).1);
        }
        offsets
    }

    /// Returns `true` if the `Index` has zero `entries`.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Return the index entry corresponding to the given revision or `None`
    /// for [`NULL_REVISION`]
    ///
    /// The specified revision being of the checked type, it always exists
    /// if it was validated by this index.
    #[inline(always)]
    pub fn get_entry(&self, rev: Revision) -> Option<IndexEntry> {
        if rev == NULL_REVISION {
            return None;
        }
        if rev.0 == 0 {
            Some(IndexEntry {
                bytes: &self.bytes.first_entry[..],
            })
        } else {
            Some(if self.is_inline() {
                self.get_entry_inline(rev)
            } else {
                self.get_entry_separated(rev)
            })
        }
    }

    /// Return the binary content of the index entry for the given revision
    ///
    /// See [`Self::get_entry`] for cases when `None` is returned.
    pub fn entry_binary(&self, rev: Revision) -> Option<&[u8]> {
        self.get_entry(rev).map(|e| {
            let bytes = e.as_bytes();
            if rev.0 == 0 {
                &bytes[4..]
            } else {
                bytes
            }
        })
    }

    pub fn entry_as_params(
        &self,
        rev: UncheckedRevision,
    ) -> Option<RevisionDataParams> {
        let rev = self.check_revision(rev)?;
        self.get_entry(rev).map(|e| RevisionDataParams {
            flags: e.flags(),
            data_offset: if rev.0 == 0 && !self.bytes.is_new() {
                e.flags() as u64
            } else {
                e.raw_offset()
            },
            data_compressed_length: e
                .compressed_len()
                .try_into()
                .unwrap_or_else(|_| {
                    // Python's `unionrepo` sets the compressed length to
                    // be `-1` (or `u32::MAX` if
                    // transmuted to `u32`) because it
                    // cannot know the correct compressed length of a given
                    // revision. I'm not sure if this is true, but having
                    // this edge case won't hurt
                    // other use cases, let's handle it.
                    assert_eq!(e.compressed_len(), u32::MAX);
                    NULL_REVISION.0
                }),
            data_uncompressed_length: e.uncompressed_len(),
            data_delta_base: e.base_revision_or_base_of_delta_chain().0,
            link_rev: e.link_revision().0,
            parent_rev_1: e.p1().0,
            parent_rev_2: e.p2().0,
            node_id: e.hash().as_bytes().try_into().unwrap(),
            ..Default::default()
        })
    }

    fn get_entry_inline(&self, rev: Revision) -> IndexEntry {
        let offsets = &self.get_offsets();
        let offsets = offsets.as_ref().expect("inline should have offsets");
        let start = offsets[rev.0 as usize];
        let end = start + INDEX_ENTRY_SIZE;
        let bytes = &self.bytes[start..end];

        IndexEntry { bytes }
    }

    fn get_entry_separated(&self, rev: Revision) -> IndexEntry {
        let start = rev.0 as usize * INDEX_ENTRY_SIZE;
        let end = start + INDEX_ENTRY_SIZE;
        let bytes = &self.bytes[start..end];

        IndexEntry { bytes }
    }

    fn null_entry(&self) -> IndexEntry {
        IndexEntry {
            bytes: &[0; INDEX_ENTRY_SIZE],
        }
    }

    /// Return the head revisions of this index
    pub fn head_revs(&self) -> Result<Vec<Revision>, GraphError> {
        self.head_revs_advanced(&HashSet::new(), None, false)
            .map(|h| h.unwrap())
    }

    /// Return the head revisions of this index
    pub fn head_revs_advanced(
        &self,
        filtered_revs: &HashSet<Revision>,
        stop_rev: Option<Revision>,
        py_shortcut: bool,
    ) -> Result<Option<Vec<Revision>>, GraphError> {
        {
            let guard = self
                .head_revs
                .read()
                .expect("RwLock on Index.head_revs should not be poisoned");
            let self_head_revs = &guard.0;
            let self_filtered_revs = &guard.1;
            if !self_head_revs.is_empty()
                && filtered_revs == self_filtered_revs
                && stop_rev.is_none()
            {
                if py_shortcut {
                    // Don't copy the revs since we've already cached them
                    // on the Python side.
                    return Ok(None);
                } else {
                    return Ok(Some(self_head_revs.to_owned()));
                }
            }
        }

        let (as_vec, cachable) = if self.is_empty() {
            (vec![NULL_REVISION], true)
        } else {
            let length: usize = match stop_rev {
                Some(r) => r.0 as usize,
                None => self.len(),
            };
            let cachable = self.len() == length;
            let mut not_heads = bitvec![0; length];
            dagops::retain_heads_fast(
                self,
                not_heads.as_mut_bitslice(),
                filtered_revs,
            )?;
            (
                not_heads
                    .into_iter()
                    .enumerate()
                    .filter_map(|(idx, is_not_head)| {
                        if is_not_head {
                            None
                        } else {
                            Some(Revision(idx as BaseRevision))
                        }
                    })
                    .collect(),
                cachable,
            )
        };
        if cachable {
            *self
                .head_revs
                .write()
                .expect("RwLock on Index.head_revs should not be poisoned") =
                (as_vec.to_owned(), filtered_revs.to_owned());
        }
        Ok(Some(as_vec))
    }

    /// Python-specific shortcut to save on PyList creation
    pub fn head_revs_shortcut(
        &self,
    ) -> Result<Option<Vec<Revision>>, GraphError> {
        self.head_revs_advanced(&HashSet::new(), None, true)
    }

    /// Return the heads removed and added by advancing from `begin` to `end`.
    /// In revset language, we compute:
    /// - `heads(:begin)-heads(:end)`
    /// - `heads(:end)-heads(:begin)`
    pub fn head_revs_diff(
        &self,
        begin: Revision,
        end: Revision,
    ) -> Result<(Vec<Revision>, Vec<Revision>), GraphError> {
        let mut heads_added = vec![];
        let mut heads_removed = vec![];

        let mut acc = HashSet::new();
        let Revision(begin) = begin;
        let Revision(end) = end;
        let mut i = end;

        while i > begin {
            // acc invariant:
            // `j` is in the set iff `j <= i` and it has children
            // among `i+1..end` (inclusive)
            if !acc.remove(&i) {
                heads_added.push(Revision(i));
            }
            for Revision(parent) in self.parents(Revision(i))? {
                acc.insert(parent);
            }
            i -= 1;
        }

        // At this point `acc` contains old revisions that gained new children.
        // We need to check if they had any children before. If not, those
        // revisions are the removed heads.
        while !acc.is_empty() {
            // acc invariant:
            // `j` is in the set iff `j <= i` and it has children
            // among `begin+1..end`, but not among `i+1..begin` (inclusive)

            assert!(i >= -1); // yes, `-1` can also be a head if the repo is empty
            if acc.remove(&i) {
                heads_removed.push(Revision(i));
            }
            for Revision(parent) in self.parents(Revision(i))? {
                acc.remove(&parent);
            }
            i -= 1;
        }

        Ok((heads_removed, heads_added))
    }

    /// Obtain the delta chain for a revision.
    ///
    /// `stop_rev` specifies a revision to stop at. If not specified, we
    /// stop at the base of the chain.
    ///
    /// Returns a 2-tuple of (chain, stopped) where `chain` is a vec of
    /// revs in ascending order and `stopped` is a bool indicating whether
    /// `stoprev` was hit.
    pub fn delta_chain(
        &self,
        rev: Revision,
        stop_rev: Option<Revision>,
    ) -> Result<(Vec<Revision>, bool), HgError> {
        let mut current_rev = rev;
        let mut entry = self.get_entry(rev).unwrap();
        let mut chain = vec![];
        let using_general_delta = self.uses_generaldelta();
        while current_rev.0 != entry.base_revision_or_base_of_delta_chain().0
            && stop_rev.map(|r| r != current_rev).unwrap_or(true)
        {
            chain.push(current_rev);
            let new_rev = if using_general_delta {
                entry.base_revision_or_base_of_delta_chain()
            } else {
                UncheckedRevision(current_rev.0 - 1)
            };
            current_rev = self.check_revision(new_rev).ok_or_else(|| {
                HgError::corrupted(format!("Revision {new_rev} out of range"))
            })?;
            if current_rev.0 == NULL_REVISION.0 {
                break;
            }
            entry = self.get_entry(current_rev).unwrap()
        }

        let stopped = if stop_rev.map(|r| current_rev == r).unwrap_or(false) {
            true
        } else {
            chain.push(current_rev);
            false
        };
        chain.reverse();
        Ok((chain, stopped))
    }

    pub fn find_snapshots(
        &self,
        start_rev: UncheckedRevision,
        end_rev: UncheckedRevision,
        cache: &mut impl SnapshotsCache,
    ) -> Result<(), RevlogError> {
        let mut start_rev = start_rev.0;
        let mut end_rev = end_rev.0;
        end_rev += 1;
        let len = self.len().try_into().unwrap();
        if end_rev > len {
            end_rev = len;
        }
        if start_rev < 0 {
            start_rev = 0;
        }
        for rev in start_rev..end_rev {
            if !self.is_snapshot_unchecked(Revision(rev))? {
                continue;
            }
            let mut base = self
                .get_entry(Revision(rev))
                .unwrap()
                .base_revision_or_base_of_delta_chain();
            if base.0 == rev {
                base = NULL_REVISION.into();
            }
            cache.insert_for(base.0, rev)?;
        }
        Ok(())
    }

    fn clear_head_revs(&self) {
        self.head_revs
            .write()
            .expect("RwLock on Index.head_revs should not be poisoined")
            .0
            .clear()
    }

    /// TODO move this to the trait probably, along with other things
    pub fn append(
        &mut self,
        revision_data: RevisionDataParams,
    ) -> Result<(), RevlogError> {
        revision_data.validate()?;
        let entry_v1 = revision_data.into_v1();
        let entry_bytes = entry_v1.as_bytes();
        if self.bytes.len() == 0 {
            self.bytes.first_entry[INDEX_HEADER_SIZE..].copy_from_slice(
                &entry_bytes[INDEX_HEADER_SIZE..INDEX_ENTRY_SIZE],
            )
        }
        if self.is_inline() {
            let new_offset = self.bytes.len();
            if let Some(offsets) = &mut *self.get_offsets_mut() {
                offsets.push(new_offset)
            }
        }
        self.bytes.added.extend(entry_bytes);
        self.clear_head_revs();
        Ok(())
    }

    pub fn pack_header(&self, header: i32) -> [u8; 4] {
        header.to_be_bytes()
    }

    pub fn remove(&mut self, rev: Revision) -> Result<(), RevlogError> {
        let offsets = if self.is_inline() {
            self.get_offsets().clone()
        } else {
            None
        };
        self.bytes.remove(rev, offsets.as_deref())?;
        if self.is_inline() {
            if let Some(offsets) = &mut *self.get_offsets_mut() {
                offsets.truncate(rev.0 as usize)
            }
        }
        self.clear_head_revs();
        Ok(())
    }

    pub fn clear_caches(&self) {
        // We need to get the 'inline' value from Python at init and use this
        // instead of offsets to determine whether we're inline since we might
        // clear caches. This implies re-populating the offsets on-demand.
        *self
            .offsets
            .write()
            .expect("RwLock on Index.offsets should not be poisoed") = None;
        self.clear_head_revs();
    }

    /// Unchecked version of `is_snapshot`.
    /// Assumes the caller checked that `rev` is within a valid revision range.
    pub fn is_snapshot_unchecked(
        &self,
        mut rev: Revision,
    ) -> Result<bool, RevlogError> {
        while rev.0 >= 0 {
            let entry = self.get_entry(rev).unwrap();
            let mut base = entry.base_revision_or_base_of_delta_chain().0;
            if base == rev.0 {
                base = NULL_REVISION.0;
            }
            if base == NULL_REVISION.0 {
                return Ok(true);
            }
            let [mut p1, mut p2] = self
                .parents(rev)
                .map_err(|e| RevlogError::InvalidRevision(e.to_string()))?;
            while let Some(p1_entry) = self.get_entry(p1) {
                if p1_entry.compressed_len() != 0 || p1.0 == 0 {
                    break;
                }
                let parent_base =
                    p1_entry.base_revision_or_base_of_delta_chain();
                if parent_base.0 == p1.0 {
                    break;
                }
                p1 = self.check_revision(parent_base).ok_or_else(|| {
                    RevlogError::InvalidRevision(parent_base.to_string())
                })?;
            }
            while let Some(p2_entry) = self.get_entry(p2) {
                if p2_entry.compressed_len() != 0 || p2.0 == 0 {
                    break;
                }
                let parent_base =
                    p2_entry.base_revision_or_base_of_delta_chain();
                if parent_base.0 == p2.0 {
                    break;
                }
                p2 = self.check_revision(parent_base).ok_or_else(|| {
                    RevlogError::InvalidRevision(parent_base.to_string())
                })?;
            }
            if base == p1.0 || base == p2.0 {
                return Ok(false);
            }
            rev = self.check_revision(base.into()).ok_or_else(|| {
                RevlogError::InvalidRevision(base.to_string())
            })?;
        }
        Ok(rev == NULL_REVISION)
    }

    /// Return whether the given revision is a snapshot. Returns an error if
    /// `rev` is not within a valid revision range.
    pub fn is_snapshot(
        &self,
        rev: UncheckedRevision,
    ) -> Result<bool, RevlogError> {
        let rev = self
            .check_revision(rev)
            .ok_or_else(|| RevlogError::corrupted("test"))?;
        self.is_snapshot_unchecked(rev)
    }

    /// Slice revs to reduce the amount of unrelated data to be read from disk.
    ///
    /// The index is sliced into groups that should be read in one time.
    ///
    /// The initial chunk is sliced until the overall density
    /// (payload/chunks-span ratio) is above `target_density`.
    /// No gap smaller than `min_gap_size` is skipped.
    pub fn slice_chunk_to_density(
        &self,
        revs: &[Revision],
        target_density: f64,
        min_gap_size: usize,
    ) -> Vec<Vec<Revision>> {
        if revs.is_empty() {
            return vec![];
        }
        if revs.len() == 1 {
            return vec![revs.to_owned()];
        }
        let delta_chain_span = self.segment_span(revs);
        if delta_chain_span < min_gap_size {
            return vec![revs.to_owned()];
        }
        let entries: Vec<_> = revs
            .iter()
            .map(|r| {
                (*r, self.get_entry(*r).unwrap_or_else(|| self.null_entry()))
            })
            .collect();

        let mut read_data = delta_chain_span;
        let chain_payload: u32 =
            entries.iter().map(|(_r, e)| e.compressed_len()).sum();
        let mut density = if delta_chain_span > 0 {
            chain_payload as f64 / delta_chain_span as f64
        } else {
            1.0
        };

        if density >= target_density {
            return vec![revs.to_owned()];
        }

        // Store the gaps in a heap to have them sorted by decreasing size
        let mut gaps = Vec::new();
        let mut previous_end = None;

        for (i, (rev, entry)) in entries.iter().enumerate() {
            let start = self.start(*rev, entry);
            let length = entry.compressed_len();

            // Skip empty revisions to form larger holes
            if length == 0 {
                continue;
            }

            if let Some(end) = previous_end {
                let gap_size = start - end;
                // Only consider holes that are large enough
                if gap_size > min_gap_size {
                    gaps.push((gap_size, i));
                }
            }
            previous_end = Some(start + length as usize);
        }
        if gaps.is_empty() {
            return vec![revs.to_owned()];
        }
        // sort the gaps to pop them from largest to small
        gaps.sort_unstable();

        // Collect the indices of the largest holes until
        // the density is acceptable
        let mut selected = vec![];
        while let Some((gap_size, gap_id)) = gaps.pop() {
            if density >= target_density {
                break;
            }
            selected.push(gap_id);

            // The gap sizes are stored as negatives to be sorted decreasingly
            // by the heap
            read_data -= gap_size;
            density = if read_data > 0 {
                chain_payload as f64 / read_data as f64
            } else {
                1.0
            };
            if density >= target_density {
                break;
            }
        }
        selected.sort_unstable();
        selected.push(revs.len());

        // Cut the revs at collected indices
        let mut previous_idx = 0;
        let mut chunks = vec![];
        for idx in selected {
            let chunk = self.trim_chunk(&entries, previous_idx, idx);
            if !chunk.is_empty() {
                chunks.push(chunk.iter().map(|(rev, _entry)| *rev).collect());
            }
            previous_idx = idx;
        }
        let chunk = self.trim_chunk(&entries, previous_idx, entries.len());
        if !chunk.is_empty() {
            chunks.push(chunk.iter().map(|(rev, _entry)| *rev).collect());
        }

        chunks
    }

    /// Get the byte span of a segment of sorted revisions.
    ///
    /// Occurrences of [`NULL_REVISION`] are ignored at the beginning of
    /// the `revs` segment.
    ///
    /// panics:
    ///  - if `revs` is empty or only made of `NULL_REVISION`
    ///  - if cannot retrieve entry for the last or first not null element of
    ///    `revs`.
    fn segment_span(&self, revs: &[Revision]) -> usize {
        if revs.is_empty() {
            return 0;
        }
        let last_rev = revs[revs.len() - 1];
        let last_entry = &self.get_entry(last_rev).unwrap();
        let end = last_entry.offset() + last_entry.compressed_len() as usize;
        let first_rev = revs.iter().find(|r| r.0 != NULL_REVISION.0).unwrap();
        let first_entry = self.get_entry(*first_rev).unwrap();
        let start = first_entry.offset();
        end - start
    }

    /// Returns `&revs[startidx..endidx]` without empty trailing revs
    fn trim_chunk<'a>(
        &'a self,
        revs: &'a [(Revision, IndexEntry)],
        start: usize,
        mut end: usize,
    ) -> &'a [(Revision, IndexEntry)] {
        // Trim empty revs at the end, except the very first rev of a chain
        let last_rev = revs[end - 1].0;
        if last_rev.0 < self.len() as BaseRevision {
            while end > 1
                && end > start
                && revs[end - 1].1.compressed_len() == 0
            {
                end -= 1
            }
        }
        &revs[start..end]
    }

    /// Computes the set of revisions for each non-public phase from `roots`,
    /// which are the last known roots for each non-public phase.
    pub fn compute_phases_map_sets(
        &self,
        roots: HashMap<Phase, Vec<Revision>>,
    ) -> Result<(usize, RootsPerPhase), GraphError> {
        let mut phases = vec![Phase::Public; self.len()];
        let mut min_phase_rev = NULL_REVISION;

        for phase in Phase::non_public_phases() {
            if let Some(phase_roots) = roots.get(phase) {
                let min_rev =
                    self.add_roots_get_min(phase_roots, &mut phases, *phase);
                if min_rev != NULL_REVISION
                    && (min_phase_rev == NULL_REVISION
                        || min_rev < min_phase_rev)
                {
                    min_phase_rev = min_rev;
                }
            } else {
                continue;
            };
        }
        let mut phase_sets: RootsPerPhase = Default::default();

        if min_phase_rev == NULL_REVISION {
            min_phase_rev = Revision(self.len() as BaseRevision);
        }

        for rev in min_phase_rev.0..self.len() as BaseRevision {
            let rev = Revision(rev);
            let [p1, p2] = self.parents(rev)?;

            if p1.0 >= 0 && phases[p1.0 as usize] > phases[rev.0 as usize] {
                phases[rev.0 as usize] = phases[p1.0 as usize];
            }
            if p2.0 >= 0 && phases[p2.0 as usize] > phases[rev.0 as usize] {
                phases[rev.0 as usize] = phases[p2.0 as usize];
            }
            let set = match phases[rev.0 as usize] {
                Phase::Public => continue,
                phase => &mut phase_sets[phase as usize - 1],
            };
            set.push(rev);
        }

        Ok((self.len(), phase_sets))
    }

    fn add_roots_get_min(
        &self,
        phase_roots: &[Revision],
        phases: &mut [Phase],
        phase: Phase,
    ) -> Revision {
        let mut min_rev = NULL_REVISION;

        for root in phase_roots {
            phases[root.0 as usize] = phase;
            if min_rev == NULL_REVISION || min_rev > *root {
                min_rev = *root;
            }
        }
        min_rev
    }

    /// Return `(heads(::(<roots> and <roots>::<heads>)))`
    /// If `include_path` is `true`, return `(<roots>::<heads>)`."""
    ///
    /// `min_root` and `roots` are unchecked since they are just used as
    /// a bound or for comparison and don't need to represent a valid revision.
    /// In practice, the only invalid revision passed is the working directory
    /// revision ([`i32::MAX`]).
    pub fn reachable_roots(
        &self,
        min_root: UncheckedRevision,
        mut heads: Vec<Revision>,
        roots: HashSet<UncheckedRevision>,
        include_path: bool,
    ) -> Result<HashSet<Revision>, GraphError> {
        if roots.is_empty() {
            return Ok(HashSet::new());
        }
        let mut reachable = HashSet::new();
        let mut seen = HashMap::new();

        while let Some(rev) = heads.pop() {
            if roots.contains(&rev.into()) {
                reachable.insert(rev);
                if !include_path {
                    continue;
                }
            }
            let parents = self.parents(rev)?;
            seen.insert(rev, parents);
            for parent in parents {
                if parent.0 >= min_root.0 && !seen.contains_key(&parent) {
                    heads.push(parent);
                }
            }
        }
        if !include_path {
            return Ok(reachable);
        }
        let mut revs: Vec<_> = seen.keys().collect();
        revs.sort_unstable();
        for rev in revs {
            for parent in seen[rev] {
                if reachable.contains(&parent) {
                    reachable.insert(*rev);
                }
            }
        }
        Ok(reachable)
    }

    /// Given a (possibly overlapping) set of revs, return all the
    /// common ancestors heads: `heads(::args[0] and ::a[1] and ...)`
    pub fn common_ancestor_heads(
        &self,
        revisions: &[Revision],
    ) -> Result<Vec<Revision>, GraphError> {
        // given that revisions is expected to be small, we find this shortcut
        // potentially acceptable, especially given that `hg-cpython` could
        // very much bypass this, constructing a vector of unique values from
        // the onset.
        let as_set: HashSet<Revision> = revisions.iter().copied().collect();
        // Besides deduplicating, the C version also implements the shortcut
        // for `NULL_REVISION`:
        if as_set.contains(&NULL_REVISION) {
            return Ok(vec![]);
        }

        let revisions: Vec<Revision> = as_set.into_iter().collect();

        if revisions.len() < 8 {
            self.find_gca_candidates::<u8>(&revisions)
        } else if revisions.len() < 64 {
            self.find_gca_candidates::<u64>(&revisions)
        } else {
            self.find_gca_candidates::<NonStaticPoisonableBitSet>(&revisions)
        }
    }

    pub fn ancestors(
        &self,
        revisions: &[Revision],
    ) -> Result<Vec<Revision>, GraphError> {
        self.find_deepest_revs(&self.common_ancestor_heads(revisions)?)
    }

    /// Given a disjoint set of revs, return all candidates for the
    /// greatest common ancestor. In revset notation, this is the set
    /// `heads(::a and ::b and ...)`
    fn find_gca_candidates<BS: PoisonableBitSet + Clone>(
        &self,
        revs: &[Revision],
    ) -> Result<Vec<Revision>, GraphError> {
        if revs.is_empty() {
            return Ok(vec![]);
        }
        let revcount = revs.len();
        let mut candidates = vec![];
        let max_rev = revs.iter().max().unwrap();

        let mut seen = BS::vec_of_empty(revs.len(), (max_rev.0 + 1) as usize);

        for (idx, rev) in revs.iter().enumerate() {
            seen[rev.0 as usize].add(idx);
        }
        let mut current_rev = *max_rev;
        // Number of revisions whose inspection in the main loop
        // will give a result or trigger inspection of other revisions
        let mut interesting = revcount;

        // The algorithm works on a vector of bit sets, indexed by revision
        // numbers and iterated on reverse order.
        // An entry in this vector is poisoned if and only if the corresponding
        // revision is a common, yet not maximal ancestor.

        // The principle of the algorithm is as follows:
        // For a revision `r`, when entering the loop, `seen[r]` is either
        // poisoned or the sub set of `revs` of which `r` is an ancestor.
        // In this sub set is full, then `r` is a solution and its parents
        // have to be poisoned.
        //
        // At each iteration, the bit sets of the parents are updated by
        // union with `seen[r]`.
        // As we walk the index from the end, we are sure we have encountered
        // all children of `r` before `r`, hence we know that `seen[r]` is
        // fully computed.
        //
        // On top of that there are several optimizations that make reading
        // less obvious than the comment above:
        // - The `interesting` counter allows to break early
        // - The loop starts from `max(revs)`
        // - Early return in case it is detected that one of the incoming revs
        //   is a common ancestor of all of them.
        while current_rev.0 >= 0 && interesting > 0 {
            let current_seen = seen[current_rev.0 as usize].clone();

            if current_seen.is_empty() {
                current_rev = Revision(current_rev.0 - 1);
                continue;
            }
            let mut poison = current_seen.is_poisoned();
            if !poison {
                interesting -= 1;
                if current_seen.is_full_range(revcount) {
                    candidates.push(current_rev);
                    poison = true;

                    // Being a common ancestor, if `current_rev` is among
                    // the input revisions, it is *the* answer.
                    for rev in revs {
                        if *rev == current_rev {
                            return Ok(candidates);
                        }
                    }
                }
            }
            for parent in self.parents(current_rev)? {
                if parent == NULL_REVISION {
                    continue;
                }
                let parent_seen = &mut seen[parent.0 as usize];
                if poison {
                    // this block is logically equivalent to poisoning parent
                    // and counting it as non interesting if it
                    // has been seen before (hence counted then as interesting)
                    if !parent_seen.is_empty() && !parent_seen.is_poisoned() {
                        interesting -= 1;
                    }
                    parent_seen.poison();
                } else {
                    if parent_seen.is_empty() {
                        interesting += 1;
                    }
                    parent_seen.union(&current_seen);
                }
            }

            current_rev = Revision(current_rev.0 - 1);
        }

        Ok(candidates)
    }

    /// Given a disjoint set of revs, return the subset with the longest path
    /// to the root.
    fn find_deepest_revs(
        &self,
        revs: &[Revision],
    ) -> Result<Vec<Revision>, GraphError> {
        // TODO replace this all with just comparing rank?
        // Also, the original implementations in C/Python are cryptic, not
        // even sure we actually need this?
        if revs.len() <= 1 {
            return Ok(revs.to_owned());
        }
        let max_rev = revs.iter().max().unwrap().0;
        let mut interesting = HashMap::new();
        let mut seen = vec![0; max_rev as usize + 1];
        let mut depth = vec![0; max_rev as usize + 1];
        let mut mapping = vec![];
        let mut revs = revs.to_owned();
        revs.sort_unstable();

        for (idx, rev) in revs.iter().enumerate() {
            depth[rev.0 as usize] = 1;
            let shift = 1 << idx;
            seen[rev.0 as usize] = shift;
            interesting.insert(shift, 1);
            mapping.push((shift, *rev));
        }

        let mut current_rev = Revision(max_rev);
        while current_rev.0 >= 0 && interesting.len() > 1 {
            let current_depth = depth[current_rev.0 as usize];
            if current_depth == 0 {
                current_rev = Revision(current_rev.0 - 1);
                continue;
            }

            let current_seen = seen[current_rev.0 as usize];
            for parent in self.parents(current_rev)? {
                if parent == NULL_REVISION {
                    continue;
                }
                let parent_seen = seen[parent.0 as usize];
                let parent_depth = depth[parent.0 as usize];
                if parent_depth <= current_depth {
                    depth[parent.0 as usize] = current_depth + 1;
                    if parent_seen != current_seen {
                        *interesting.get_mut(&current_seen).unwrap() += 1;
                        seen[parent.0 as usize] = current_seen;
                        if parent_seen != 0 {
                            let parent_interesting =
                                interesting.get_mut(&parent_seen).unwrap();
                            *parent_interesting -= 1;
                            if *parent_interesting == 0 {
                                interesting.remove(&parent_seen);
                            }
                        }
                    }
                } else if current_depth == parent_depth - 1 {
                    let either_seen = parent_seen | current_seen;
                    if either_seen == parent_seen {
                        continue;
                    }
                    seen[parent.0 as usize] = either_seen;
                    interesting
                        .entry(either_seen)
                        .and_modify(|v| *v += 1)
                        .or_insert(1);
                    *interesting.get_mut(&parent_seen).unwrap() -= 1;
                    if interesting[&parent_seen] == 0 {
                        interesting.remove(&parent_seen);
                    }
                }
            }
            *interesting.get_mut(&current_seen).unwrap() -= 1;
            if interesting[&current_seen] == 0 {
                interesting.remove(&current_seen);
            }

            current_rev = Revision(current_rev.0 - 1);
        }

        if interesting.len() != 1 {
            return Ok(vec![]);
        }
        let mask = interesting.keys().next().unwrap();

        Ok(mapping
            .into_iter()
            .filter_map(|(shift, rev)| {
                if (mask & shift) != 0 {
                    return Some(rev);
                }
                None
            })
            .collect())
    }

    /// Return the offset into the data corresponding to `rev` (in the index
    /// file if inline, in the data file otherwise). `entry` must be the entry
    /// for `rev`: the API is done this way to reduce the number of lookups
    /// since we sometimes already have the entry, and because very few places
    /// actually use this function.
    #[inline(always)]
    pub fn start(&self, rev: Revision, entry: &IndexEntry<'_>) -> usize {
        #[cfg(debug_assertions)]
        {
            assert_eq!(&self.get_entry(rev).unwrap(), entry);
        }
        let offset = entry.offset();
        if self.is_inline() {
            offset + ((rev.0 as usize + 1) * INDEX_ENTRY_SIZE)
        } else {
            offset
        }
    }

    pub(crate) fn make_null_entry(&self) -> IndexEntry<'_> {
        IndexEntry {
            bytes: b"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0 \
            \xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff \
            \0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        }
    }
}

/// The kind of functionality needed by find_gca_candidates
///
/// This is a bit mask which can be declared to be "poisoned", which callers
/// interpret to break out of some loops.
///
/// The maximum capacity of the bit mask is up to the actual implementation
trait PoisonableBitSet: Sized + PartialEq {
    /// Return a vector of exactly n elements, initialized to be empty.
    ///
    /// Optimization can vastly depend on implementation. Those being `Copy`
    /// and having constant capacity typically can have a very simple
    /// implementation.
    fn vec_of_empty(sets_size: usize, vec_len: usize) -> Vec<Self>;

    /// The size of the bit mask in memory
    #[allow(unused)]
    fn size(&self) -> usize;

    /// The number of elements that can be represented in the set.
    ///
    /// Another way to put it is that it is the highest integer `C` such that
    /// the set is guaranteed to always be a subset of the integer range
    /// `[0, C)`
    #[allow(unused)]
    fn capacity(&self) -> usize;

    /// Declare `n` to belong to the set
    fn add(&mut self, n: usize);

    /// Declare `n` not to belong to the set
    #[allow(unused)]
    fn discard(&mut self, n: usize);

    /// Replace this bit set by its union with other
    fn union(&mut self, other: &Self);

    /// Poison the bit set
    ///
    /// Interpretation up to the caller
    fn poison(&mut self);

    /// Is the bit set poisoned?
    ///
    /// Interpretation is up to the caller
    fn is_poisoned(&self) -> bool;

    /// Is the bit set empty?
    fn is_empty(&self) -> bool;

    /// return `true` if and only if the bit is the full range `[0, n)`
    /// of integers
    fn is_full_range(&self, n: usize) -> bool;
}

const U64_POISON: u64 = 1 << 63;
const U8_POISON: u8 = 1 << 7;

impl PoisonableBitSet for u64 {
    fn vec_of_empty(_sets_size: usize, vec_len: usize) -> Vec<Self> {
        vec![0u64; vec_len]
    }

    fn size(&self) -> usize {
        8
    }

    fn capacity(&self) -> usize {
        63
    }

    fn add(&mut self, n: usize) {
        (*self) |= 1u64 << n;
    }

    fn discard(&mut self, n: usize) {
        (*self) &= u64::MAX - (1u64 << n);
    }

    fn union(&mut self, other: &Self) {
        if *self != *other {
            (*self) |= *other;
        }
    }

    fn is_full_range(&self, n: usize) -> bool {
        *self + 1 == (1u64 << n)
    }

    fn is_empty(&self) -> bool {
        *self == 0
    }

    fn poison(&mut self) {
        *self = U64_POISON;
    }

    fn is_poisoned(&self) -> bool {
        // equality comparison would be tempting but would not resist
        // operations after poisoning (even if these should be bogus).
        *self >= U64_POISON
    }
}

impl PoisonableBitSet for u8 {
    fn vec_of_empty(_sets_size: usize, vec_len: usize) -> Vec<Self> {
        vec![0; vec_len]
    }

    fn size(&self) -> usize {
        1
    }

    fn capacity(&self) -> usize {
        7
    }

    fn add(&mut self, n: usize) {
        (*self) |= 1 << n;
    }

    fn discard(&mut self, n: usize) {
        (*self) &= u8::MAX - (1 << n);
    }

    fn union(&mut self, other: &Self) {
        if *self != *other {
            (*self) |= *other;
        }
    }

    fn is_full_range(&self, n: usize) -> bool {
        *self + 1 == (1 << n)
    }

    fn is_empty(&self) -> bool {
        *self == 0
    }

    fn poison(&mut self) {
        *self = U8_POISON;
    }

    fn is_poisoned(&self) -> bool {
        // equality comparison would be tempting but would not resist
        // operations after poisoning (even if these should be bogus).
        *self >= U8_POISON
    }
}

/// A poisonable bit set whose capacity is not known at compile time but
/// is constant after initial construction
///
/// This can be way further optimized if performance assessments (speed
/// and/or RAM) require it.
/// As far as RAM is concerned, for large vectors of these, the main problem
/// would be the repetition of set_size in each item. We would need a trait
/// to abstract over the idea of a vector of such bit sets to do better.
#[derive(Clone, PartialEq)]
struct NonStaticPoisonableBitSet {
    set_size: usize,
    bit_set: Vec<u64>,
}

/// Number of `u64` needed for a [`NonStaticPoisonableBitSet`] of given size
fn non_static_poisonable_inner_len(set_size: usize) -> usize {
    1 + (set_size + 1) / 64
}

impl NonStaticPoisonableBitSet {
    /// The index of the sub-bit set for the given n, and the index inside
    /// the latter
    fn index(&self, n: usize) -> (usize, usize) {
        (n / 64, n % 64)
    }
}

/// Mock implementation to ensure that the trait makes sense
impl PoisonableBitSet for NonStaticPoisonableBitSet {
    fn vec_of_empty(set_size: usize, vec_len: usize) -> Vec<Self> {
        let tmpl = Self {
            set_size,
            bit_set: vec![0u64; non_static_poisonable_inner_len(set_size)],
        };
        vec![tmpl; vec_len]
    }

    fn size(&self) -> usize {
        8 + self.bit_set.len() * 8
    }

    fn capacity(&self) -> usize {
        self.set_size
    }

    fn add(&mut self, n: usize) {
        let (sub_bs, bit_pos) = self.index(n);
        self.bit_set[sub_bs] |= 1 << bit_pos
    }

    fn discard(&mut self, n: usize) {
        let (sub_bs, bit_pos) = self.index(n);
        self.bit_set[sub_bs] |= u64::MAX - (1 << bit_pos)
    }

    fn union(&mut self, other: &Self) {
        assert!(
            self.set_size == other.set_size,
            "Binary operations on bit sets can only be done on same size"
        );
        for i in 0..self.bit_set.len() - 1 {
            self.bit_set[i] |= other.bit_set[i]
        }
    }

    fn is_full_range(&self, n: usize) -> bool {
        let (sub_bs, bit_pos) = self.index(n);
        self.bit_set[..sub_bs].iter().all(|bs| *bs == u64::MAX)
            && self.bit_set[sub_bs] == (1 << (bit_pos + 1)) - 1
    }

    fn is_empty(&self) -> bool {
        self.bit_set.iter().all(|bs| *bs == 0u64)
    }

    fn poison(&mut self) {
        let (sub_bs, bit_pos) = self.index(self.set_size);
        self.bit_set[sub_bs] = 1 << bit_pos;
    }

    fn is_poisoned(&self) -> bool {
        let (sub_bs, bit_pos) = self.index(self.set_size);
        self.bit_set[sub_bs] >= 1 << bit_pos
    }
}

/// Set of roots of all non-public phases
pub type RootsPerPhase = [Vec<Revision>; Phase::non_public_phases().len()];

#[derive(Debug, Copy, Clone, PartialEq, Eq, Ord, PartialOrd, Hash)]
pub enum Phase {
    Public = 0,
    Draft = 1,
    Secret = 2,
    Archived = 3,
    Internal = 4,
}

impl TryFrom<usize> for Phase {
    type Error = RevlogError;

    fn try_from(value: usize) -> Result<Self, Self::Error> {
        Ok(match value {
            0 => Self::Public,
            1 => Self::Draft,
            2 => Self::Secret,
            32 => Self::Archived,
            96 => Self::Internal,
            v => {
                return Err(RevlogError::corrupted(format!(
                    "invalid phase value {}",
                    v
                )))
            }
        })
    }
}

impl Phase {
    pub const fn all_phases() -> &'static [Self] {
        &[
            Self::Public,
            Self::Draft,
            Self::Secret,
            Self::Archived,
            Self::Internal,
        ]
    }
    pub const fn non_public_phases() -> &'static [Self] {
        &[Self::Draft, Self::Secret, Self::Archived, Self::Internal]
    }
}

fn inline_scan(bytes: &[u8]) -> (usize, Vec<usize>) {
    let mut offset: usize = 0;
    let mut offsets = Vec::new();

    while offset + INDEX_ENTRY_SIZE <= bytes.len() {
        offsets.push(offset);
        let end = offset + INDEX_ENTRY_SIZE;
        let entry = IndexEntry {
            bytes: &bytes[offset..end],
        };

        offset += INDEX_ENTRY_SIZE + entry.compressed_len() as usize;
    }
    (offset, offsets)
}

impl super::RevlogIndex for Index {
    fn len(&self) -> usize {
        self.len()
    }

    fn node(&self, rev: Revision) -> Option<&Node> {
        if rev == NULL_REVISION {
            return Some(&NULL_NODE);
        }
        self.get_entry(rev).map(|entry| entry.hash())
    }
}

#[derive(Debug, PartialEq, Eq)]
pub struct IndexEntry<'a> {
    bytes: &'a [u8],
}

impl<'a> IndexEntry<'a> {
    /// Return the offset of the data.
    pub fn offset(&self) -> usize {
        let mut bytes = [0; 8];
        bytes[2..8].copy_from_slice(&self.bytes[0..=5]);
        BigEndian::read_u64(&bytes[..]) as usize
    }
    pub fn raw_offset(&self) -> u64 {
        BigEndian::read_u64(&self.bytes[0..8])
    }

    pub fn flags(&self) -> u16 {
        BigEndian::read_u16(&self.bytes[6..=7])
    }

    /// Return the compressed length of the data.
    pub fn compressed_len(&self) -> u32 {
        BigEndian::read_u32(&self.bytes[8..=11])
    }

    /// Return the uncompressed length of the data.
    pub fn uncompressed_len(&self) -> i32 {
        BigEndian::read_i32(&self.bytes[12..=15])
    }

    /// Return the revision upon which the data has been derived.
    pub fn base_revision_or_base_of_delta_chain(&self) -> UncheckedRevision {
        // TODO Maybe return an Option when base_revision == rev?
        //      Requires to add rev to IndexEntry

        BigEndian::read_i32(&self.bytes[16..]).into()
    }

    pub fn link_revision(&self) -> UncheckedRevision {
        BigEndian::read_i32(&self.bytes[20..]).into()
    }

    pub fn p1(&self) -> UncheckedRevision {
        BigEndian::read_i32(&self.bytes[24..]).into()
    }

    pub fn p2(&self) -> UncheckedRevision {
        BigEndian::read_i32(&self.bytes[28..]).into()
    }

    /// Return the hash of revision's full text.
    ///
    /// Currently, SHA-1 is used and only the first 20 bytes of this field
    /// are used.
    pub fn hash(&self) -> &'a Node {
        (&self.bytes[32..52]).try_into().unwrap()
    }

    pub fn as_bytes(&self) -> &'a [u8] {
        self.bytes
    }
}

#[cfg(test)]
pub use tests::IndexEntryBuilder;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NULL_NODE;

    #[cfg(test)]
    #[derive(Debug, Copy, Clone)]
    pub struct IndexEntryBuilder {
        is_first: bool,
        is_inline: bool,
        is_general_delta: bool,
        version: u16,
        offset: usize,
        compressed_len: usize,
        uncompressed_len: usize,
        base_revision_or_base_of_delta_chain: Revision,
        link_revision: Revision,
        p1: Revision,
        p2: Revision,
        node: Node,
    }

    #[cfg(test)]
    impl IndexEntryBuilder {
        #[allow(clippy::new_without_default)]
        pub fn new() -> Self {
            Self {
                is_first: false,
                is_inline: false,
                is_general_delta: true,
                version: 1,
                offset: 0,
                compressed_len: 0,
                uncompressed_len: 0,
                base_revision_or_base_of_delta_chain: Revision(0),
                link_revision: Revision(0),
                p1: NULL_REVISION,
                p2: NULL_REVISION,
                node: NULL_NODE,
            }
        }

        pub fn is_first(&mut self, value: bool) -> &mut Self {
            self.is_first = value;
            self
        }

        pub fn with_inline(&mut self, value: bool) -> &mut Self {
            self.is_inline = value;
            self
        }

        pub fn with_general_delta(&mut self, value: bool) -> &mut Self {
            self.is_general_delta = value;
            self
        }

        pub fn with_version(&mut self, value: u16) -> &mut Self {
            self.version = value;
            self
        }

        pub fn with_offset(&mut self, value: usize) -> &mut Self {
            self.offset = value;
            self
        }

        pub fn with_compressed_len(&mut self, value: usize) -> &mut Self {
            self.compressed_len = value;
            self
        }

        pub fn with_uncompressed_len(&mut self, value: usize) -> &mut Self {
            self.uncompressed_len = value;
            self
        }

        pub fn with_base_revision_or_base_of_delta_chain(
            &mut self,
            value: Revision,
        ) -> &mut Self {
            self.base_revision_or_base_of_delta_chain = value;
            self
        }

        pub fn with_link_revision(&mut self, value: Revision) -> &mut Self {
            self.link_revision = value;
            self
        }

        pub fn with_p1(&mut self, value: Revision) -> &mut Self {
            self.p1 = value;
            self
        }

        pub fn with_p2(&mut self, value: Revision) -> &mut Self {
            self.p2 = value;
            self
        }

        pub fn with_node(&mut self, value: Node) -> &mut Self {
            self.node = value;
            self
        }

        pub fn build(&self) -> Vec<u8> {
            let mut bytes = Vec::with_capacity(INDEX_ENTRY_SIZE);
            if self.is_first {
                bytes.extend(match (self.is_general_delta, self.is_inline) {
                    (false, false) => [0u8, 0],
                    (false, true) => [0u8, 1],
                    (true, false) => [0u8, 2],
                    (true, true) => [0u8, 3],
                });
                bytes.extend(self.version.to_be_bytes());
                // Remaining offset bytes.
                bytes.extend([0u8; 2]);
            } else {
                // Offset stored on 48 bits (6 bytes)
                bytes.extend(&(self.offset as u64).to_be_bytes()[2..]);
            }
            bytes.extend([0u8; 2]); // Revision flags.
            bytes.extend((self.compressed_len as u32).to_be_bytes());
            bytes.extend((self.uncompressed_len as u32).to_be_bytes());
            bytes.extend(
                self.base_revision_or_base_of_delta_chain.0.to_be_bytes(),
            );
            bytes.extend(self.link_revision.0.to_be_bytes());
            bytes.extend(self.p1.0.to_be_bytes());
            bytes.extend(self.p2.0.to_be_bytes());
            bytes.extend(self.node.as_bytes());
            bytes.extend(vec![0u8; 12]);
            bytes
        }
    }

    pub fn is_inline(index_bytes: &[u8]) -> bool {
        IndexHeader::parse(index_bytes)
            .expect("invalid header")
            .format_flags()
            .is_inline()
    }

    pub fn uses_generaldelta(index_bytes: &[u8]) -> bool {
        IndexHeader::parse(index_bytes)
            .expect("invalid header")
            .format_flags()
            .uses_generaldelta()
    }

    pub fn get_version(index_bytes: &[u8]) -> u16 {
        IndexHeader::parse(index_bytes)
            .expect("invalid header")
            .format_version()
    }

    #[test]
    fn flags_when_no_inline_flag_test() {
        let bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_general_delta(false)
            .with_inline(false)
            .build();

        assert!(!is_inline(&bytes));
        assert!(!uses_generaldelta(&bytes));
    }

    #[test]
    fn flags_when_inline_flag_test() {
        let bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_general_delta(false)
            .with_inline(true)
            .build();

        assert!(is_inline(&bytes));
        assert!(!uses_generaldelta(&bytes));
    }

    #[test]
    fn flags_when_inline_and_generaldelta_flags_test() {
        let bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_general_delta(true)
            .with_inline(true)
            .build();

        assert!(is_inline(&bytes));
        assert!(uses_generaldelta(&bytes));
    }

    #[test]
    fn test_offset() {
        let bytes = IndexEntryBuilder::new().with_offset(1).build();
        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.offset(), 1)
    }

    #[test]
    fn test_compressed_len() {
        let bytes = IndexEntryBuilder::new().with_compressed_len(1).build();
        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.compressed_len(), 1)
    }

    #[test]
    fn test_uncompressed_len() {
        let bytes = IndexEntryBuilder::new().with_uncompressed_len(1).build();
        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.uncompressed_len(), 1)
    }

    #[test]
    fn test_base_revision_or_base_of_delta_chain() {
        let bytes = IndexEntryBuilder::new()
            .with_base_revision_or_base_of_delta_chain(Revision(1))
            .build();
        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.base_revision_or_base_of_delta_chain(), 1.into())
    }

    #[test]
    fn link_revision_test() {
        let bytes = IndexEntryBuilder::new()
            .with_link_revision(Revision(123))
            .build();

        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.link_revision(), 123.into());
    }

    #[test]
    fn p1_test() {
        let bytes = IndexEntryBuilder::new().with_p1(Revision(123)).build();

        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.p1(), 123.into());
    }

    #[test]
    fn p2_test() {
        let bytes = IndexEntryBuilder::new().with_p2(Revision(123)).build();

        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(entry.p2(), 123.into());
    }

    #[test]
    fn node_test() {
        let node = Node::from_hex("0123456789012345678901234567890123456789")
            .unwrap();
        let bytes = IndexEntryBuilder::new().with_node(node).build();

        let entry = IndexEntry { bytes: &bytes };

        assert_eq!(*entry.hash(), node);
    }

    #[test]
    fn version_test() {
        let bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_version(2)
            .build();

        assert_eq!(get_version(&bytes), 2)
    }
}
