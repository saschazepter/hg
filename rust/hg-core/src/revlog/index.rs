use std::fmt::Debug;
use std::ops::Deref;
use std::sync::{RwLock, RwLockReadGuard, RwLockWriteGuard};

use byteorder::{BigEndian, ByteOrder};
use bytes_cast::{unaligned, BytesCast};

use super::REVIDX_KNOWN_FLAGS;
use crate::errors::HgError;
use crate::node::{NODE_BYTES_LENGTH, STORED_NODE_ID_BYTES};
use crate::revlog::node::Node;
use crate::revlog::{Revision, NULL_REVISION};
use crate::{Graph, GraphError, RevlogError, RevlogIndex, UncheckedRevision};

pub const INDEX_ENTRY_SIZE: usize = 64;
pub const COMPRESSION_MODE_INLINE: u8 = 2;

pub struct IndexHeader {
    pub(super) header_bytes: [u8; 4],
}

#[derive(Copy, Clone)]
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

    pub fn parse(index_bytes: &[u8]) -> Result<Option<IndexHeader>, HgError> {
        if index_bytes.is_empty() {
            return Ok(None);
        }
        if index_bytes.len() < 4 {
            return Err(HgError::corrupted(
                "corrupted revlog: can't read the index format header",
            ));
        }
        Ok(Some(IndexHeader {
            header_bytes: {
                let bytes: [u8; 4] =
                    index_bytes[0..4].try_into().expect("impossible");
                bytes
            },
        }))
    }
}

/// Abstracts the access to the index bytes since they can be spread between
/// the immutable (bytes) part and the mutable (added) part if any appends
/// happened. This makes it transparent for the callers.
struct IndexData {
    /// Immutable bytes, most likely taken from disk
    bytes: Box<dyn Deref<Target = [u8]> + Send>,
    /// Used when stripping index contents, keeps track of the start of the
    /// first stripped revision, which is used to give a slice of the
    /// `bytes` field.
    truncation: Option<usize>,
    /// Bytes that were added after reading the index
    added: Vec<u8>,
}

impl IndexData {
    pub fn new(bytes: Box<dyn Deref<Target = [u8]> + Send>) -> Self {
        Self {
            bytes,
            truncation: None,
            added: vec![],
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

impl Index {
    /// Create an index from bytes.
    /// Calculate the start of each entry when is_inline is true.
    pub fn new(
        bytes: Box<dyn Deref<Target = [u8]> + Send>,
        default_header: IndexHeader,
    ) -> Result<Self, HgError> {
        let header =
            IndexHeader::parse(bytes.as_ref())?.unwrap_or(default_header);

        if header.format_version() != IndexHeader::REVLOGV1 {
            // A proper new version should have had a repo/store
            // requirement.
            return Err(HgError::corrupted("unsupported revlog version"));
        }

        // This is only correct because we know version is REVLOGV1.
        // In v2 we always use generaldelta, while in v0 we never use
        // generaldelta. Similar for [is_inline] (it's only used in v1).
        let uses_generaldelta = header.format_flags().uses_generaldelta();

        if header.format_flags().is_inline() {
            let mut offset: usize = 0;
            let mut offsets = Vec::new();

            while offset + INDEX_ENTRY_SIZE <= bytes.len() {
                offsets.push(offset);
                let end = offset + INDEX_ENTRY_SIZE;
                let entry = IndexEntry {
                    bytes: &bytes[offset..end],
                    offset_override: None,
                };

                offset += INDEX_ENTRY_SIZE + entry.compressed_len() as usize;
            }

            if offset == bytes.len() {
                Ok(Self {
                    bytes: IndexData::new(bytes),
                    offsets: RwLock::new(Some(offsets)),
                    uses_generaldelta,
                    is_inline: true,
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
        if let Some(offsets) = &*self.get_offsets() {
            offsets.len()
        } else {
            self.bytes.len() / INDEX_ENTRY_SIZE
        }
    }

    pub fn get_offsets(&self) -> RwLockReadGuard<Option<Vec<usize>>> {
        if self.is_inline() {
            {
                // Wrap in a block to drop the read guard
                // TODO perf?
                let mut offsets = self.offsets.write().unwrap();
                if offsets.is_none() {
                    offsets.replace(inline_scan(&self.bytes.bytes).1);
                }
            }
        }
        self.offsets.read().unwrap()
    }

    pub fn get_offsets_mut(&mut self) -> RwLockWriteGuard<Option<Vec<usize>>> {
        let mut offsets = self.offsets.write().unwrap();
        if self.is_inline() && offsets.is_none() {
            offsets.replace(inline_scan(&self.bytes.bytes).1);
        }
        offsets
    }

    /// Returns `true` if the `Index` has zero `entries`.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Return the index entry corresponding to the given revision if it
    /// exists.
    pub fn get_entry(&self, rev: Revision) -> Option<IndexEntry> {
        if rev == NULL_REVISION {
            return None;
        }
        Some(if let Some(offsets) = &*self.get_offsets() {
            self.get_entry_inline(rev, offsets.as_ref())
        } else {
            self.get_entry_separated(rev)
        })
    }

    fn get_entry_inline(
        &self,
        rev: Revision,
        offsets: &[usize],
    ) -> IndexEntry {
        let start = offsets[rev.0 as usize];
        let end = start + INDEX_ENTRY_SIZE;
        let bytes = &self.bytes[start..end];

        // See IndexEntry for an explanation of this override.
        let offset_override = Some(end);

        IndexEntry {
            bytes,
            offset_override,
        }
    }

    fn get_entry_separated(&self, rev: Revision) -> IndexEntry {
        let start = rev.0 as usize * INDEX_ENTRY_SIZE;
        let end = start + INDEX_ENTRY_SIZE;
        let bytes = &self.bytes[start..end];

        // Override the offset of the first revision as its bytes are used
        // for the index's metadata (saving space because it is always 0)
        let offset_override = if rev == Revision(0) { Some(0) } else { None };

        IndexEntry {
            bytes,
            offset_override,
        }
    }

    /// TODO move this to the trait probably, along with other things
    pub fn append(
        &mut self,
        revision_data: RevisionDataParams,
    ) -> Result<(), RevlogError> {
        revision_data.validate()?;
        let new_offset = self.bytes.len();
        if let Some(offsets) = &mut *self.get_offsets_mut() {
            offsets.push(new_offset)
        }
        self.bytes.added.extend(revision_data.into_v1().as_bytes());
        Ok(())
    }

    pub fn remove(&mut self, rev: Revision) -> Result<(), RevlogError> {
        let offsets = self.get_offsets().clone();
        self.bytes.remove(rev, offsets.as_deref())?;
        if let Some(offsets) = &mut *self.get_offsets_mut() {
            offsets.truncate(rev.0 as usize)
        }
        Ok(())
    }

    pub fn clear_caches(&mut self) {
        // We need to get the 'inline' value from Python at init and use this
        // instead of offsets to determine whether we're inline since we might
        // clear caches. This implies re-populating the offsets on-demand.
        self.offsets = RwLock::new(None);
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
            offset_override: None,
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
        self.get_entry(rev).map(|entry| entry.hash())
    }
}

#[derive(Debug)]
pub struct IndexEntry<'a> {
    bytes: &'a [u8],
    /// Allows to override the offset value of the entry.
    ///
    /// For interleaved index and data, the offset stored in the index
    /// corresponds to the separated data offset.
    /// It has to be overridden with the actual offset in the interleaved
    /// index which is just after the index block.
    ///
    /// For separated index and data, the offset stored in the first index
    /// entry is mixed with the index headers.
    /// It has to be overridden with 0.
    offset_override: Option<usize>,
}

impl<'a> IndexEntry<'a> {
    /// Return the offset of the data.
    pub fn offset(&self) -> usize {
        if let Some(offset_override) = self.offset_override {
            offset_override
        } else {
            let mut bytes = [0; 8];
            bytes[2..8].copy_from_slice(&self.bytes[0..=5]);
            BigEndian::read_u64(&bytes[..]) as usize
        }
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::node::NULL_NODE;

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
                bytes.extend(&match (self.is_general_delta, self.is_inline) {
                    (false, false) => [0u8, 0],
                    (false, true) => [0u8, 1],
                    (true, false) => [0u8, 2],
                    (true, true) => [0u8, 3],
                });
                bytes.extend(&self.version.to_be_bytes());
                // Remaining offset bytes.
                bytes.extend(&[0u8; 2]);
            } else {
                // Offset stored on 48 bits (6 bytes)
                bytes.extend(&(self.offset as u64).to_be_bytes()[2..]);
            }
            bytes.extend(&[0u8; 2]); // Revision flags.
            bytes.extend(&(self.compressed_len as u32).to_be_bytes());
            bytes.extend(&(self.uncompressed_len as u32).to_be_bytes());
            bytes.extend(
                &self.base_revision_or_base_of_delta_chain.0.to_be_bytes(),
            );
            bytes.extend(&self.link_revision.0.to_be_bytes());
            bytes.extend(&self.p1.0.to_be_bytes());
            bytes.extend(&self.p2.0.to_be_bytes());
            bytes.extend(self.node.as_bytes());
            bytes.extend(vec![0u8; 12]);
            bytes
        }
    }

    pub fn is_inline(index_bytes: &[u8]) -> bool {
        IndexHeader::parse(index_bytes)
            .expect("too short")
            .unwrap()
            .format_flags()
            .is_inline()
    }

    pub fn uses_generaldelta(index_bytes: &[u8]) -> bool {
        IndexHeader::parse(index_bytes)
            .expect("too short")
            .unwrap()
            .format_flags()
            .uses_generaldelta()
    }

    pub fn get_version(index_bytes: &[u8]) -> u16 {
        IndexHeader::parse(index_bytes)
            .expect("too short")
            .unwrap()
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
        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.offset(), 1)
    }

    #[test]
    fn test_with_overridden_offset() {
        let bytes = IndexEntryBuilder::new().with_offset(1).build();
        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: Some(2),
        };

        assert_eq!(entry.offset(), 2)
    }

    #[test]
    fn test_compressed_len() {
        let bytes = IndexEntryBuilder::new().with_compressed_len(1).build();
        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.compressed_len(), 1)
    }

    #[test]
    fn test_uncompressed_len() {
        let bytes = IndexEntryBuilder::new().with_uncompressed_len(1).build();
        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.uncompressed_len(), 1)
    }

    #[test]
    fn test_base_revision_or_base_of_delta_chain() {
        let bytes = IndexEntryBuilder::new()
            .with_base_revision_or_base_of_delta_chain(Revision(1))
            .build();
        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.base_revision_or_base_of_delta_chain(), 1.into())
    }

    #[test]
    fn link_revision_test() {
        let bytes = IndexEntryBuilder::new()
            .with_link_revision(Revision(123))
            .build();

        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.link_revision(), 123.into());
    }

    #[test]
    fn p1_test() {
        let bytes = IndexEntryBuilder::new().with_p1(Revision(123)).build();

        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.p1(), 123.into());
    }

    #[test]
    fn p2_test() {
        let bytes = IndexEntryBuilder::new().with_p2(Revision(123)).build();

        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

        assert_eq!(entry.p2(), 123.into());
    }

    #[test]
    fn node_test() {
        let node = Node::from_hex("0123456789012345678901234567890123456789")
            .unwrap();
        let bytes = IndexEntryBuilder::new().with_node(node).build();

        let entry = IndexEntry {
            bytes: &bytes,
            offset_override: None,
        };

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

#[cfg(test)]
pub use tests::IndexEntryBuilder;
