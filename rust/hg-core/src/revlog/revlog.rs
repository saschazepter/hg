use std::borrow::Cow;
use std::io::Read;
use std::ops::Deref;
use std::path::Path;

use byteorder::{BigEndian, ByteOrder};
use flate2::read::ZlibDecoder;
use micro_timer::timed;
use sha1::{Digest, Sha1};
use zstd;

use super::index::Index;
use super::node::{NodePrefix, NODE_BYTES_LENGTH, NULL_NODE};
use super::nodemap;
use super::nodemap::{NodeMap, NodeMapError};
use super::nodemap_docket::NodeMapDocket;
use super::patch;
use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::Revision;
use crate::{Node, NULL_REVISION};

#[derive(derive_more::From)]
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
            NodeMapError::RevisionNotInIndex(_) => RevlogError::corrupted(),
        }
    }
}

impl RevlogError {
    fn corrupted() -> Self {
        RevlogError::Other(HgError::corrupted("corrupted revlog"))
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
    #[timed]
    pub fn open(
        repo: &Repo,
        index_path: impl AsRef<Path>,
        data_path: Option<&Path>,
    ) -> Result<Self, HgError> {
        let index_path = index_path.as_ref();
        let index = {
            match repo.store_vfs().mmap_open_opt(&index_path)? {
                None => Index::new(Box::new(vec![])),
                Some(index_mmap) => {
                    let version = get_version(&index_mmap)?;
                    if version != 1 {
                        // A proper new version should have had a repo/store
                        // requirement.
                        return Err(HgError::corrupted("corrupted revlog"));
                    }

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
                let data_mmap = repo.store_vfs().mmap_open(data_path)?;
                Some(Box::new(data_mmap))
            };

        let nodemap = if index.is_inline() {
            None
        } else {
            NodeMapDocket::read_from_file(repo, index_path)?.map(
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
    #[timed]
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
            let index_entry =
                self.index.get_entry(rev).ok_or(HgError::corrupted(
                    "revlog references a revision not in the index",
                ))?;
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
    #[timed]
    pub fn get_rev_data(&self, rev: Revision) -> Result<Vec<u8>, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(vec![]);
        };
        // Todo return -> Cow
        let mut entry = self.get_entry(rev)?;
        let mut delta_chain = vec![];
        while let Some(base_rev) = entry.base_rev {
            delta_chain.push(entry);
            entry = self
                .get_entry(base_rev)
                .map_err(|_| RevlogError::corrupted())?;
        }

        // TODO do not look twice in the index
        let index_entry = self
            .index
            .get_entry(rev)
            .ok_or(RevlogError::InvalidRevision)?;

        let data: Vec<u8> = if delta_chain.is_empty() {
            entry.data()?.into()
        } else {
            Revlog::build_data_from_deltas(entry, &delta_chain)?
        };

        if self.check_hash(
            index_entry.p1(),
            index_entry.p2(),
            index_entry.hash().as_bytes(),
            &data,
        ) {
            Ok(data)
        } else {
            Err(RevlogError::corrupted())
        }
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

        &hash(data, h1.as_bytes(), h2.as_bytes()) == expected
    }

    /// Build the full data of a revision out its snapshot
    /// and its deltas.
    #[timed]
    fn build_data_from_deltas(
        snapshot: RevlogEntry,
        deltas: &[RevlogEntry],
    ) -> Result<Vec<u8>, RevlogError> {
        let snapshot = snapshot.data()?;
        let deltas = deltas
            .iter()
            .rev()
            .map(RevlogEntry::data)
            .collect::<Result<Vec<Cow<'_, [u8]>>, RevlogError>>()?;
        let patches: Vec<_> =
            deltas.iter().map(|d| patch::PatchList::new(d)).collect();
        let patch = patch::fold_patch_lists(&patches);
        Ok(patch.apply(&snapshot))
    }

    /// Return the revlog data.
    fn data(&self) -> &[u8] {
        match self.data_bytes {
            Some(ref data_bytes) => &data_bytes,
            None => panic!(
                "forgot to load the data or trying to access inline data"
            ),
        }
    }

    /// Get an entry of the revlog.
    fn get_entry(&self, rev: Revision) -> Result<RevlogEntry, RevlogError> {
        let index_entry = self
            .index
            .get_entry(rev)
            .ok_or(RevlogError::InvalidRevision)?;
        let start = index_entry.offset();
        let end = start + index_entry.compressed_len();
        let data = if self.index.is_inline() {
            self.index.data(start, end)
        } else {
            &self.data()[start..end]
        };
        let entry = RevlogEntry {
            rev,
            bytes: data,
            compressed_len: index_entry.compressed_len(),
            uncompressed_len: index_entry.uncompressed_len(),
            base_rev: if index_entry.base_revision() == rev {
                None
            } else {
                Some(index_entry.base_revision())
            },
        };
        Ok(entry)
    }
}

/// The revlog entry's bytes and the necessary informations to extract
/// the entry's data.
#[derive(Debug)]
pub struct RevlogEntry<'a> {
    rev: Revision,
    bytes: &'a [u8],
    compressed_len: usize,
    uncompressed_len: usize,
    base_rev: Option<Revision>,
}

impl<'a> RevlogEntry<'a> {
    pub fn revision(&self) -> Revision {
        self.rev
    }

    /// Extract the data contained in the entry.
    pub fn data(&self) -> Result<Cow<'_, [u8]>, RevlogError> {
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
            _format_type => Err(RevlogError::corrupted()),
        }
    }

    fn uncompressed_zlib_data(&self) -> Result<Vec<u8>, RevlogError> {
        let mut decoder = ZlibDecoder::new(self.bytes);
        if self.is_delta() {
            let mut buf = Vec::with_capacity(self.compressed_len);
            decoder
                .read_to_end(&mut buf)
                .map_err(|_| RevlogError::corrupted())?;
            Ok(buf)
        } else {
            let mut buf = vec![0; self.uncompressed_len];
            decoder
                .read_exact(&mut buf)
                .map_err(|_| RevlogError::corrupted())?;
            Ok(buf)
        }
    }

    fn uncompressed_zstd_data(&self) -> Result<Vec<u8>, RevlogError> {
        if self.is_delta() {
            let mut buf = Vec::with_capacity(self.compressed_len);
            zstd::stream::copy_decode(self.bytes, &mut buf)
                .map_err(|_| RevlogError::corrupted())?;
            Ok(buf)
        } else {
            let mut buf = vec![0; self.uncompressed_len];
            let len = zstd::block::decompress_to_buffer(self.bytes, &mut buf)
                .map_err(|_| RevlogError::corrupted())?;
            if len != self.uncompressed_len {
                Err(RevlogError::corrupted())
            } else {
                Ok(buf)
            }
        }
    }

    /// Tell if the entry is a snapshot or a delta
    /// (influences on decompression).
    fn is_delta(&self) -> bool {
        self.base_rev.is_some()
    }
}

/// Format version of the revlog.
pub fn get_version(index_bytes: &[u8]) -> Result<u16, HgError> {
    if index_bytes.len() == 0 {
        return Ok(1);
    };
    if index_bytes.len() < 4 {
        return Err(HgError::corrupted(
            "corrupted revlog: can't read the index format header",
        ));
    };
    Ok(BigEndian::read_u16(&index_bytes[2..=3]))
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

    use super::super::index::IndexEntryBuilder;

    #[test]
    fn version_test() {
        let bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_version(1)
            .build();

        assert_eq!(get_version(&bytes).map_err(|_err| ()), Ok(1))
    }
}
