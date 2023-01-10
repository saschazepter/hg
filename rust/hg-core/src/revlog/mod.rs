// Copyright 2018-2023 Georges Racinet <georges.racinet@octobus.net>
//           and Mercurial contributors
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Mercurial concepts for handling revision history

pub mod node;
pub mod nodemap;
mod nodemap_docket;
pub mod path_encode;
pub use node::{FromHexError, Node, NodePrefix};
pub mod changelog;
pub mod filelog;
pub mod index;
pub mod manifest;
pub mod patch;

use std::borrow::Cow;
use std::io::Read;
use std::ops::Deref;
use std::path::Path;

use flate2::read::ZlibDecoder;
use sha1::{Digest, Sha1};
use zstd;

use self::node::{NODE_BYTES_LENGTH, NULL_NODE};
use self::nodemap_docket::NodeMapDocket;
use super::index::Index;
use super::nodemap::{NodeMap, NodeMapError};
use crate::errors::HgError;
use crate::vfs::Vfs;

/// Mercurial revision numbers
///
/// As noted in revlog.c, revision numbers are actually encoded in
/// 4 bytes, and are liberally converted to ints, whence the i32
pub type Revision = i32;

/// Marker expressing the absence of a parent
///
/// Independently of the actual representation, `NULL_REVISION` is guaranteed
/// to be smaller than all existing revisions.
pub const NULL_REVISION: Revision = -1;

/// Same as `mercurial.node.wdirrev`
///
/// This is also equal to `i32::max_value()`, but it's better to spell
/// it out explicitely, same as in `mercurial.node`
#[allow(clippy::unreadable_literal)]
pub const WORKING_DIRECTORY_REVISION: Revision = 0x7fffffff;

pub const WORKING_DIRECTORY_HEX: &str =
    "ffffffffffffffffffffffffffffffffffffffff";

/// The simplest expression of what we need of Mercurial DAGs.
pub trait Graph {
    /// Return the two parents of the given `Revision`.
    ///
    /// Each of the parents can be independently `NULL_REVISION`
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError>;
}

#[derive(Clone, Debug, PartialEq)]
pub enum GraphError {
    ParentOutOfRange(Revision),
    WorkingDirectoryUnsupported,
}

/// The Mercurial Revlog Index
///
/// This is currently limited to the minimal interface that is needed for
/// the [`nodemap`](nodemap/index.html) module
pub trait RevlogIndex {
    /// Total number of Revisions referenced in this index
    fn len(&self) -> usize;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Return a reference to the Node or `None` if rev is out of bounds
    ///
    /// `NULL_REVISION` is not considered to be out of bounds.
    fn node(&self, rev: Revision) -> Option<&Node>;
}

const REVISION_FLAG_CENSORED: u16 = 1 << 15;
const REVISION_FLAG_ELLIPSIS: u16 = 1 << 14;
const REVISION_FLAG_EXTSTORED: u16 = 1 << 13;
const REVISION_FLAG_HASCOPIESINFO: u16 = 1 << 12;

// Keep this in sync with REVIDX_KNOWN_FLAGS in
// mercurial/revlogutils/flagutil.py
const REVIDX_KNOWN_FLAGS: u16 = REVISION_FLAG_CENSORED
    | REVISION_FLAG_ELLIPSIS
    | REVISION_FLAG_EXTSTORED
    | REVISION_FLAG_HASCOPIESINFO;

const NULL_REVLOG_ENTRY_FLAGS: u16 = 0;

#[derive(Debug, derive_more::From)]
pub enum RevlogError {
    InvalidRevision,
    /// Working directory is not supported
    WDirUnsupported,
    /// Found more than one entry whose ID match the requested prefix
    AmbiguousPrefix,
    #[from]
    Other(HgError),
}

impl From<NodeMapError> for RevlogError {
    fn from(error: NodeMapError) -> Self {
        match error {
            NodeMapError::MultipleResults => RevlogError::AmbiguousPrefix,
            NodeMapError::RevisionNotInIndex(rev) => RevlogError::corrupted(
                format!("nodemap point to revision {} not in index", rev),
            ),
        }
    }
}

fn corrupted<S: AsRef<str>>(context: S) -> HgError {
    HgError::corrupted(format!("corrupted revlog, {}", context.as_ref()))
}

impl RevlogError {
    fn corrupted<S: AsRef<str>>(context: S) -> Self {
        RevlogError::Other(corrupted(context))
    }
}

/// Read only implementation of revlog.
pub struct Revlog {
    /// When index and data are not interleaved: bytes of the revlog index.
    /// When index and data are interleaved: bytes of the revlog index and
    /// data.
    index: Index,
    /// When index and data are not interleaved: bytes of the revlog data
    data_bytes: Option<Box<dyn Deref<Target = [u8]> + Send>>,
    /// When present on disk: the persistent nodemap for this revlog
    nodemap: Option<nodemap::NodeTree>,
}

impl Revlog {
    /// Open a revlog index file.
    ///
    /// It will also open the associated data file if index and data are not
    /// interleaved.
    pub fn open(
        store_vfs: &Vfs,
        index_path: impl AsRef<Path>,
        data_path: Option<&Path>,
        use_nodemap: bool,
    ) -> Result<Self, HgError> {
        let index_path = index_path.as_ref();
        let index = {
            match store_vfs.mmap_open_opt(&index_path)? {
                None => Index::new(Box::new(vec![])),
                Some(index_mmap) => {
                    let index = Index::new(Box::new(index_mmap))?;
                    Ok(index)
                }
            }
        }?;

        let default_data_path = index_path.with_extension("d");

        // type annotation required
        // won't recognize Mmap as Deref<Target = [u8]>
        let data_bytes: Option<Box<dyn Deref<Target = [u8]> + Send>> =
            if index.is_inline() {
                None
            } else {
                let data_path = data_path.unwrap_or(&default_data_path);
                let data_mmap = store_vfs.mmap_open(data_path)?;
                Some(Box::new(data_mmap))
            };

        let nodemap = if index.is_inline() || !use_nodemap {
            None
        } else {
            NodeMapDocket::read_from_file(store_vfs, index_path)?.map(
                |(docket, data)| {
                    nodemap::NodeTree::load_bytes(
                        Box::new(data),
                        docket.data_length,
                    )
                },
            )
        };

        Ok(Revlog {
            index,
            data_bytes,
            nodemap,
        })
    }

    /// Return number of entries of the `Revlog`.
    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Returns `true` if the `Revlog` has zero `entries`.
    pub fn is_empty(&self) -> bool {
        self.index.is_empty()
    }

    /// Returns the node ID for the given revision number, if it exists in this
    /// revlog
    pub fn node_from_rev(&self, rev: Revision) -> Option<&Node> {
        if rev == NULL_REVISION {
            return Some(&NULL_NODE);
        }
        Some(self.index.get_entry(rev)?.hash())
    }

    /// Return the revision number for the given node ID, if it exists in this
    /// revlog
    pub fn rev_from_node(
        &self,
        node: NodePrefix,
    ) -> Result<Revision, RevlogError> {
        if node.is_prefix_of(&NULL_NODE) {
            return Ok(NULL_REVISION);
        }

        if let Some(nodemap) = &self.nodemap {
            return nodemap
                .find_bin(&self.index, node)?
                .ok_or(RevlogError::InvalidRevision);
        }

        // Fallback to linear scan when a persistent nodemap is not present.
        // This happens when the persistent-nodemap experimental feature is not
        // enabled, or for small revlogs.
        //
        // TODO: consider building a non-persistent nodemap in memory to
        // optimize these cases.
        let mut found_by_prefix = None;
        for rev in (0..self.len() as Revision).rev() {
            let index_entry = self.index.get_entry(rev).ok_or_else(|| {
                HgError::corrupted(
                    "revlog references a revision not in the index",
                )
            })?;
            if node == *index_entry.hash() {
                return Ok(rev);
            }
            if node.is_prefix_of(index_entry.hash()) {
                if found_by_prefix.is_some() {
                    return Err(RevlogError::AmbiguousPrefix);
                }
                found_by_prefix = Some(rev)
            }
        }
        found_by_prefix.ok_or(RevlogError::InvalidRevision)
    }

    /// Returns whether the given revision exists in this revlog.
    pub fn has_rev(&self, rev: Revision) -> bool {
        self.index.get_entry(rev).is_some()
    }

    /// Return the full data associated to a revision.
    ///
    /// All entries required to build the final data out of deltas will be
    /// retrieved as needed, and the deltas will be applied to the inital
    /// snapshot to rebuild the final data.
    pub fn get_rev_data(
        &self,
        rev: Revision,
    ) -> Result<Cow<[u8]>, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(Cow::Borrowed(&[]));
        };
        Ok(self.get_entry(rev)?.data()?)
    }

    /// Check the hash of some given data against the recorded hash.
    pub fn check_hash(
        &self,
        p1: Revision,
        p2: Revision,
        expected: &[u8],
        data: &[u8],
    ) -> bool {
        let e1 = self.index.get_entry(p1);
        let h1 = match e1 {
            Some(ref entry) => entry.hash(),
            None => &NULL_NODE,
        };
        let e2 = self.index.get_entry(p2);
        let h2 = match e2 {
            Some(ref entry) => entry.hash(),
            None => &NULL_NODE,
        };

        hash(data, h1.as_bytes(), h2.as_bytes()) == expected
    }

    /// Build the full data of a revision out its snapshot
    /// and its deltas.
    fn build_data_from_deltas(
        snapshot: RevlogEntry,
        deltas: &[RevlogEntry],
    ) -> Result<Vec<u8>, HgError> {
        let snapshot = snapshot.data_chunk()?;
        let deltas = deltas
            .iter()
            .rev()
            .map(RevlogEntry::data_chunk)
            .collect::<Result<Vec<_>, _>>()?;
        let patches: Vec<_> =
            deltas.iter().map(|d| patch::PatchList::new(d)).collect();
        let patch = patch::fold_patch_lists(&patches);
        Ok(patch.apply(&snapshot))
    }

    /// Return the revlog data.
    fn data(&self) -> &[u8] {
        match &self.data_bytes {
            Some(data_bytes) => data_bytes,
            None => panic!(
                "forgot to load the data or trying to access inline data"
            ),
        }
    }

    pub fn make_null_entry(&self) -> RevlogEntry {
        RevlogEntry {
            revlog: self,
            rev: NULL_REVISION,
            bytes: b"",
            compressed_len: 0,
            uncompressed_len: 0,
            base_rev_or_base_of_delta_chain: None,
            p1: NULL_REVISION,
            p2: NULL_REVISION,
            flags: NULL_REVLOG_ENTRY_FLAGS,
            hash: NULL_NODE,
        }
    }

    /// Get an entry of the revlog.
    pub fn get_entry(
        &self,
        rev: Revision,
    ) -> Result<RevlogEntry, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(self.make_null_entry());
        }
        let index_entry = self
            .index
            .get_entry(rev)
            .ok_or(RevlogError::InvalidRevision)?;
        let start = index_entry.offset();
        let end = start + index_entry.compressed_len() as usize;
        let data = if self.index.is_inline() {
            self.index.data(start, end)
        } else {
            &self.data()[start..end]
        };
        let entry = RevlogEntry {
            revlog: self,
            rev,
            bytes: data,
            compressed_len: index_entry.compressed_len(),
            uncompressed_len: index_entry.uncompressed_len(),
            base_rev_or_base_of_delta_chain: if index_entry
                .base_revision_or_base_of_delta_chain()
                == rev
            {
                None
            } else {
                Some(index_entry.base_revision_or_base_of_delta_chain())
            },
            p1: index_entry.p1(),
            p2: index_entry.p2(),
            flags: index_entry.flags(),
            hash: *index_entry.hash(),
        };
        Ok(entry)
    }

    /// when resolving internal references within revlog, any errors
    /// should be reported as corruption, instead of e.g. "invalid revision"
    fn get_entry_internal(
        &self,
        rev: Revision,
    ) -> Result<RevlogEntry, HgError> {
        self.get_entry(rev)
            .map_err(|_| corrupted(format!("revision {} out of range", rev)))
    }
}

/// The revlog entry's bytes and the necessary informations to extract
/// the entry's data.
#[derive(Clone)]
pub struct RevlogEntry<'a> {
    revlog: &'a Revlog,
    rev: Revision,
    bytes: &'a [u8],
    compressed_len: u32,
    uncompressed_len: i32,
    base_rev_or_base_of_delta_chain: Option<Revision>,
    p1: Revision,
    p2: Revision,
    flags: u16,
    hash: Node,
}

impl<'a> RevlogEntry<'a> {
    pub fn revision(&self) -> Revision {
        self.rev
    }

    pub fn node(&self) -> &Node {
        &self.hash
    }

    pub fn uncompressed_len(&self) -> Option<u32> {
        u32::try_from(self.uncompressed_len).ok()
    }

    pub fn has_p1(&self) -> bool {
        self.p1 != NULL_REVISION
    }

    pub fn p1_entry(&self) -> Result<Option<RevlogEntry>, RevlogError> {
        if self.p1 == NULL_REVISION {
            Ok(None)
        } else {
            Ok(Some(self.revlog.get_entry(self.p1)?))
        }
    }

    pub fn p2_entry(&self) -> Result<Option<RevlogEntry>, RevlogError> {
        if self.p2 == NULL_REVISION {
            Ok(None)
        } else {
            Ok(Some(self.revlog.get_entry(self.p2)?))
        }
    }

    pub fn p1(&self) -> Option<Revision> {
        if self.p1 == NULL_REVISION {
            None
        } else {
            Some(self.p1)
        }
    }

    pub fn p2(&self) -> Option<Revision> {
        if self.p2 == NULL_REVISION {
            None
        } else {
            Some(self.p2)
        }
    }

    pub fn is_censored(&self) -> bool {
        (self.flags & REVISION_FLAG_CENSORED) != 0
    }

    pub fn has_length_affecting_flag_processor(&self) -> bool {
        // Relevant Python code: revlog.size()
        // note: ELLIPSIS is known to not change the content
        (self.flags & (REVIDX_KNOWN_FLAGS ^ REVISION_FLAG_ELLIPSIS)) != 0
    }

    /// The data for this entry, after resolving deltas if any.
    pub fn rawdata(&self) -> Result<Cow<'a, [u8]>, HgError> {
        let mut entry = self.clone();
        let mut delta_chain = vec![];

        // The meaning of `base_rev_or_base_of_delta_chain` depends on
        // generaldelta. See the doc on `ENTRY_DELTA_BASE` in
        // `mercurial/revlogutils/constants.py` and the code in
        // [_chaininfo] and in [index_deltachain].
        let uses_generaldelta = self.revlog.index.uses_generaldelta();
        while let Some(base_rev) = entry.base_rev_or_base_of_delta_chain {
            let base_rev = if uses_generaldelta {
                base_rev
            } else {
                entry.rev - 1
            };
            delta_chain.push(entry);
            entry = self.revlog.get_entry_internal(base_rev)?;
        }

        let data = if delta_chain.is_empty() {
            entry.data_chunk()?
        } else {
            Revlog::build_data_from_deltas(entry, &delta_chain)?.into()
        };

        Ok(data)
    }

    fn check_data(
        &self,
        data: Cow<'a, [u8]>,
    ) -> Result<Cow<'a, [u8]>, HgError> {
        if self.revlog.check_hash(
            self.p1,
            self.p2,
            self.hash.as_bytes(),
            &data,
        ) {
            Ok(data)
        } else {
            if (self.flags & REVISION_FLAG_ELLIPSIS) != 0 {
                return Err(HgError::unsupported(
                    "ellipsis revisions are not supported by rhg",
                ));
            }
            Err(corrupted(format!(
                "hash check failed for revision {}",
                self.rev
            )))
        }
    }

    pub fn data(&self) -> Result<Cow<'a, [u8]>, HgError> {
        let data = self.rawdata()?;
        if self.is_censored() {
            return Err(HgError::CensoredNodeError);
        }
        self.check_data(data)
    }

    /// Extract the data contained in the entry.
    /// This may be a delta. (See `is_delta`.)
    fn data_chunk(&self) -> Result<Cow<'a, [u8]>, HgError> {
        if self.bytes.is_empty() {
            return Ok(Cow::Borrowed(&[]));
        }
        match self.bytes[0] {
            // Revision data is the entirety of the entry, including this
            // header.
            b'\0' => Ok(Cow::Borrowed(self.bytes)),
            // Raw revision data follows.
            b'u' => Ok(Cow::Borrowed(&self.bytes[1..])),
            // zlib (RFC 1950) data.
            b'x' => Ok(Cow::Owned(self.uncompressed_zlib_data()?)),
            // zstd data.
            b'\x28' => Ok(Cow::Owned(self.uncompressed_zstd_data()?)),
            // A proper new format should have had a repo/store requirement.
            format_type => Err(corrupted(format!(
                "unknown compression header '{}'",
                format_type
            ))),
        }
    }

    fn uncompressed_zlib_data(&self) -> Result<Vec<u8>, HgError> {
        let mut decoder = ZlibDecoder::new(self.bytes);
        if self.is_delta() {
            let mut buf = Vec::with_capacity(self.compressed_len as usize);
            decoder
                .read_to_end(&mut buf)
                .map_err(|e| corrupted(e.to_string()))?;
            Ok(buf)
        } else {
            let cap = self.uncompressed_len.max(0) as usize;
            let mut buf = vec![0; cap];
            decoder
                .read_exact(&mut buf)
                .map_err(|e| corrupted(e.to_string()))?;
            Ok(buf)
        }
    }

    fn uncompressed_zstd_data(&self) -> Result<Vec<u8>, HgError> {
        if self.is_delta() {
            let mut buf = Vec::with_capacity(self.compressed_len as usize);
            zstd::stream::copy_decode(self.bytes, &mut buf)
                .map_err(|e| corrupted(e.to_string()))?;
            Ok(buf)
        } else {
            let cap = self.uncompressed_len.max(0) as usize;
            let mut buf = vec![0; cap];
            let len = zstd::bulk::decompress_to_buffer(self.bytes, &mut buf)
                .map_err(|e| corrupted(e.to_string()))?;
            if len != self.uncompressed_len as usize {
                Err(corrupted("uncompressed length does not match"))
            } else {
                Ok(buf)
            }
        }
    }

    /// Tell if the entry is a snapshot or a delta
    /// (influences on decompression).
    fn is_delta(&self) -> bool {
        self.base_rev_or_base_of_delta_chain.is_some()
    }
}

/// Calculate the hash of a revision given its data and its parents.
fn hash(
    data: &[u8],
    p1_hash: &[u8],
    p2_hash: &[u8],
) -> [u8; NODE_BYTES_LENGTH] {
    let mut hasher = Sha1::new();
    let (a, b) = (p1_hash, p2_hash);
    if a > b {
        hasher.update(b);
        hasher.update(a);
    } else {
        hasher.update(a);
        hasher.update(b);
    }
    hasher.update(data);
    *hasher.finalize().as_ref()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{IndexEntryBuilder, INDEX_ENTRY_SIZE};
    use itertools::Itertools;

    #[test]
    fn test_empty() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = Vfs { base: temp.path() };
        std::fs::write(temp.path().join("foo.i"), b"").unwrap();
        let revlog = Revlog::open(&vfs, "foo.i", None, false).unwrap();
        assert!(revlog.is_empty());
        assert_eq!(revlog.len(), 0);
        assert!(revlog.get_entry(0).is_err());
        assert!(!revlog.has_rev(0));
    }

    #[test]
    fn test_inline() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = Vfs { base: temp.path() };
        let node0 = Node::from_hex("2ed2a3912a0b24502043eae84ee4b279c18b90dd")
            .unwrap();
        let node1 = Node::from_hex("b004912a8510032a0350a74daa2803dadfb00e12")
            .unwrap();
        let node2 = Node::from_hex("dd6ad206e907be60927b5a3117b97dffb2590582")
            .unwrap();
        let entry0_bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_version(1)
            .with_inline(true)
            .with_offset(INDEX_ENTRY_SIZE)
            .with_node(node0)
            .build();
        let entry1_bytes = IndexEntryBuilder::new()
            .with_offset(INDEX_ENTRY_SIZE)
            .with_node(node1)
            .build();
        let entry2_bytes = IndexEntryBuilder::new()
            .with_offset(INDEX_ENTRY_SIZE)
            .with_p1(0)
            .with_p2(1)
            .with_node(node2)
            .build();
        let contents = vec![entry0_bytes, entry1_bytes, entry2_bytes]
            .into_iter()
            .flatten()
            .collect_vec();
        std::fs::write(temp.path().join("foo.i"), contents).unwrap();
        let revlog = Revlog::open(&vfs, "foo.i", None, false).unwrap();

        let entry0 = revlog.get_entry(0).ok().unwrap();
        assert_eq!(entry0.revision(), 0);
        assert_eq!(*entry0.node(), node0);
        assert!(!entry0.has_p1());
        assert_eq!(entry0.p1(), None);
        assert_eq!(entry0.p2(), None);
        let p1_entry = entry0.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry0.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry1 = revlog.get_entry(1).ok().unwrap();
        assert_eq!(entry1.revision(), 1);
        assert_eq!(*entry1.node(), node1);
        assert!(!entry1.has_p1());
        assert_eq!(entry1.p1(), None);
        assert_eq!(entry1.p2(), None);
        let p1_entry = entry1.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry1.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry2 = revlog.get_entry(2).ok().unwrap();
        assert_eq!(entry2.revision(), 2);
        assert_eq!(*entry2.node(), node2);
        assert!(entry2.has_p1());
        assert_eq!(entry2.p1(), Some(0));
        assert_eq!(entry2.p2(), Some(1));
        let p1_entry = entry2.p1_entry().unwrap();
        assert!(p1_entry.is_some());
        assert_eq!(p1_entry.unwrap().revision(), 0);
        let p2_entry = entry2.p2_entry().unwrap();
        assert!(p2_entry.is_some());
        assert_eq!(p2_entry.unwrap().revision(), 1);
    }
}
