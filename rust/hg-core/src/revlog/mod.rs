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
use inner_revlog::CoreRevisionBuffer;
use inner_revlog::InnerRevlog;
use inner_revlog::RevisionBuffer;
use memmap2::MmapOptions;
pub use node::{FromHexError, Node, NodePrefix, NULL_NODE, NULL_NODE_ID};
use options::RevlogOpenOptions;
pub mod changelog;
pub mod compression;
pub mod file_io;
pub mod filelog;
pub mod index;
pub mod inner_revlog;
pub mod manifest;
pub mod options;
pub mod patch;

use std::borrow::Cow;
use std::io::ErrorKind;
use std::io::Read;
use std::ops::Deref;
use std::path::Path;

use self::nodemap_docket::NodeMapDocket;
use crate::errors::HgError;
use crate::errors::IoResultExt;
use crate::exit_codes;
use crate::revlog::index::Index;
use crate::revlog::nodemap::{NodeMap, NodeMapError};
use crate::vfs::Vfs;
use crate::vfs::VfsImpl;

/// As noted in revlog.c, revision numbers are actually encoded in
/// 4 bytes, and are liberally converted to ints, whence the i32
pub type BaseRevision = i32;

/// Mercurial revision numbers
/// In contrast to the more general [`UncheckedRevision`], these are "checked"
/// in the sense that they should only be used for revisions that are
/// valid for a given index (i.e. in bounds).
#[derive(
    Debug,
    derive_more::Display,
    Clone,
    Copy,
    Hash,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
)]
pub struct Revision(pub BaseRevision);

impl format_bytes::DisplayBytes for Revision {
    fn display_bytes(
        &self,
        output: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        self.0.display_bytes(output)
    }
}

/// Unchecked Mercurial revision numbers.
///
/// Values of this type have no guarantee of being a valid revision number
/// in any context. Use method `check_revision` to get a valid revision within
/// the appropriate index object.
#[derive(
    Debug,
    derive_more::Display,
    Clone,
    Copy,
    Hash,
    PartialEq,
    Eq,
    PartialOrd,
    Ord,
)]
pub struct UncheckedRevision(pub BaseRevision);

impl format_bytes::DisplayBytes for UncheckedRevision {
    fn display_bytes(
        &self,
        output: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        self.0.display_bytes(output)
    }
}

impl From<Revision> for UncheckedRevision {
    fn from(value: Revision) -> Self {
        Self(value.0)
    }
}

impl From<BaseRevision> for UncheckedRevision {
    fn from(value: BaseRevision) -> Self {
        Self(value)
    }
}

/// Marker expressing the absence of a parent
///
/// Independently of the actual representation, `NULL_REVISION` is guaranteed
/// to be smaller than all existing revisions.
pub const NULL_REVISION: Revision = Revision(-1);

/// Same as `mercurial.node.wdirrev`
///
/// This is also equal to `i32::max_value()`, but it's better to spell
/// it out explicitely, same as in `mercurial.node`
#[allow(clippy::unreadable_literal)]
pub const WORKING_DIRECTORY_REVISION: UncheckedRevision =
    UncheckedRevision(0x7fffffff);

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
    /// Parent revision does not exist, i.e. below 0 or above max revision.
    ParentOutOfRange(Revision),
    /// Parent revision number is greater than one of its descendants.
    ParentOutOfOrder(Revision),
}

impl std::fmt::Display for GraphError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GraphError::ParentOutOfRange(revision) => {
                write!(f, "parent out of range ({})", revision)
            }
            GraphError::ParentOutOfOrder(revision) => {
                write!(f, "parent out of order ({})", revision)
            }
        }
    }
}

impl<T: Graph> Graph for &T {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        (*self).parents(rev)
    }
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

    /// Return a reference to the Node or `None` for `NULL_REVISION`
    fn node(&self, rev: Revision) -> Option<&Node>;

    /// Return a [`Revision`] if `rev` is a valid revision number for this
    /// index.
    ///
    /// [`NULL_REVISION`] is considered to be valid.
    #[inline(always)]
    fn check_revision(&self, rev: UncheckedRevision) -> Option<Revision> {
        let rev = rev.0;

        if rev == NULL_REVISION.0 || (rev >= 0 && (rev as usize) < self.len())
        {
            Some(Revision(rev))
        } else {
            None
        }
    }
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

#[derive(Debug, derive_more::From, derive_more::Display)]
pub enum RevlogError {
    #[display(fmt = "invalid revision identifier: {}", "_0")]
    InvalidRevision(String),
    /// Working directory is not supported
    WDirUnsupported,
    /// Found more than one entry whose ID match the requested prefix
    AmbiguousPrefix(String),
    #[from]
    Other(HgError),
}

impl From<(NodeMapError, String)> for RevlogError {
    fn from((error, rev): (NodeMapError, String)) -> Self {
        match error {
            NodeMapError::MultipleResults => RevlogError::AmbiguousPrefix(rev),
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

#[derive(derive_more::Display, Debug, Copy, Clone, PartialEq, Eq)]
pub enum RevlogType {
    Changelog,
    Manifestlog,
    Filelog,
}

impl TryFrom<usize> for RevlogType {
    type Error = HgError;

    fn try_from(value: usize) -> Result<Self, Self::Error> {
        match value {
            1001 => Ok(Self::Changelog),
            1002 => Ok(Self::Manifestlog),
            1003 => Ok(Self::Filelog),
            t => Err(HgError::abort(
                format!("Unknown revlog type {}", t),
                exit_codes::ABORT,
                None,
            )),
        }
    }
}

pub struct Revlog {
    inner: InnerRevlog,
    /// When present on disk: the persistent nodemap for this revlog
    nodemap: Option<nodemap::NodeTree>,
}

impl Graph for Revlog {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        self.index().parents(rev)
    }
}
impl Revlog {
    /// Open a revlog index file.
    ///
    /// It will also open the associated data file if index and data are not
    /// interleaved.
    pub fn open(
        // Todo use the `Vfs` trait here once we create a function for mmap
        store_vfs: &VfsImpl,
        index_path: impl AsRef<Path>,
        data_path: Option<&Path>,
        options: RevlogOpenOptions,
    ) -> Result<Self, HgError> {
        Self::open_gen(store_vfs, index_path, data_path, options, None)
    }

    fn index(&self) -> &Index {
        &self.inner.index
    }

    fn open_gen(
        // Todo use the `Vfs` trait here once we create a function for mmap
        store_vfs: &VfsImpl,
        index_path: impl AsRef<Path>,
        data_path: Option<&Path>,
        options: RevlogOpenOptions,
        nodemap_for_test: Option<nodemap::NodeTree>,
    ) -> Result<Self, HgError> {
        let index_path = index_path.as_ref();
        let index = open_index(store_vfs, index_path, options)?;

        let default_data_path = index_path.with_extension("d");
        let data_path = data_path.unwrap_or(&default_data_path);

        let nodemap = if index.is_inline() || !options.use_nodemap {
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

        let nodemap = nodemap_for_test.or(nodemap);

        Ok(Revlog {
            inner: InnerRevlog::new(
                Box::new(store_vfs.clone()),
                index,
                index_path.to_path_buf(),
                data_path.to_path_buf(),
                options.data_config,
                options.delta_config,
                options.feature_config,
            ),
            nodemap,
        })
    }

    /// Return number of entries of the `Revlog`.
    pub fn len(&self) -> usize {
        self.index().len()
    }

    /// Returns `true` if the `Revlog` has zero `entries`.
    pub fn is_empty(&self) -> bool {
        self.index().is_empty()
    }

    /// Returns the node ID for the given revision number, if it exists in this
    /// revlog
    pub fn node_from_rev(&self, rev: Revision) -> &Node {
        match self.index().get_entry(rev) {
            None => &NULL_NODE,
            Some(entry) => entry.hash(),
        }
    }

    /// Like [`Self::node_from_rev`] but checks `rev` first.
    pub fn node_from_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Option<&Node> {
        Some(self.node_from_rev(self.index().check_revision(rev)?))
    }

    /// Return the revision number for the given node ID, if it exists in this
    /// revlog
    pub fn rev_from_node(
        &self,
        node: NodePrefix,
    ) -> Result<Revision, RevlogError> {
        if let Some(nodemap) = &self.nodemap {
            nodemap
                .find_bin(self.index(), node)
                .map_err(|err| (err, format!("{:x}", node)))?
                .ok_or_else(|| {
                    RevlogError::InvalidRevision(format!("{:x}", node))
                })
        } else {
            self.index().rev_from_node_no_persistent_nodemap(node)
        }
    }

    /// Returns whether the given revision exists in this revlog.
    pub fn has_rev(&self, rev: UncheckedRevision) -> bool {
        self.index().check_revision(rev).is_some()
    }

    pub fn get_entry(
        &self,
        rev: Revision,
    ) -> Result<RevlogEntry, RevlogError> {
        self.inner.get_entry(rev)
    }

    pub fn get_entry_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<RevlogEntry, RevlogError> {
        self.inner.get_entry_for_unchecked_rev(rev)
    }

    /// Returns the delta parent of the given revision.
    pub fn delta_parent(&self, rev: Revision) -> Revision {
        if rev == NULL_REVISION {
            NULL_REVISION
        } else {
            self.inner.delta_parent(rev)
        }
    }

    /// Returns the link revision (a.k.a. "linkrev") of the given revision.
    /// Returns an error if the linkrev does not exist in `linked_revlog`.
    pub fn link_revision(
        &self,
        rev: Revision,
        linked_revlog: &Self,
    ) -> Result<Revision, RevlogError> {
        let Some(entry) = self.index().get_entry(rev) else {
            return Ok(NULL_REVISION);
        };
        linked_revlog
            .index()
            .check_revision(entry.link_revision())
            .ok_or_else(|| {
                RevlogError::corrupted(format!(
                    "linkrev for rev {} is invalid",
                    rev
                ))
            })
    }

    /// Return the full data associated to a revision.
    ///
    /// All entries required to build the final data out of deltas will be
    /// retrieved as needed, and the deltas will be applied to the initial
    /// snapshot to rebuild the final data.
    pub fn get_data_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<Cow<[u8]>, RevlogError> {
        if rev == NULL_REVISION.into() {
            return Ok(Cow::Borrowed(&[]));
        };
        self.get_entry_for_unchecked_rev(rev)?.data()
    }

    /// [`Self::get_data_for_unchecked_rev`] for a checked [`Revision`].
    pub fn get_data(&self, rev: Revision) -> Result<Cow<[u8]>, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(Cow::Borrowed(&[]));
        };
        self.get_entry(rev)?.data()
    }

    /// Gets the raw uncompressed data stored for a revision, which is either
    /// the full text or a delta. Panics if `rev` is null.
    pub fn get_data_incr(
        &self,
        rev: Revision,
    ) -> Result<RawdataBuf, RevlogError> {
        let index = self.index();
        let entry = index.get_entry(rev).expect("rev should not be null");
        let delta_base = entry.base_revision_or_base_of_delta_chain();
        let base = if UncheckedRevision::from(rev) == delta_base {
            None
        } else if index.uses_generaldelta() {
            Some(delta_base)
        } else {
            Some(UncheckedRevision(rev.0 - 1))
        };
        let data = self.inner.chunk_for_rev(rev)?;
        Ok(RawdataBuf { base, data })
    }

    /// Check the hash of some given data against the recorded hash.
    pub fn check_hash(
        &self,
        p1: Revision,
        p2: Revision,
        expected: &[u8],
        data: &[u8],
    ) -> bool {
        self.inner.check_hash(p1, p2, expected, data)
    }

    /// Build the full data of a revision out its snapshot
    /// and its deltas.
    fn build_data_from_deltas<T>(
        buffer: &mut dyn RevisionBuffer<Target = T>,
        snapshot: &[u8],
        deltas: &[impl AsRef<[u8]>],
    ) -> Result<(), RevlogError> {
        if deltas.is_empty() {
            buffer.extend_from_slice(snapshot);
            return Ok(());
        }
        let patches: Result<Vec<_>, _> = deltas
            .iter()
            .map(|d| patch::PatchList::new(d.as_ref()))
            .collect();
        let patch = patch::fold_patch_lists(&patches?);
        patch.apply(buffer, snapshot);
        Ok(())
    }
}

pub struct RawdataBuf {
    // If `Some`, data is a delta.
    base: Option<UncheckedRevision>,
    data: std::sync::Arc<[u8]>,
}

impl RawdataBuf {
    fn as_patch_list(&self) -> Result<patch::PatchList, RevlogError> {
        match self.base {
            None => Ok(patch::PatchList::full_snapshot(&self.data)),
            Some(_) => patch::PatchList::new(&self.data),
        }
    }
}

type IndexData = Box<dyn Deref<Target = [u8]> + Send + Sync>;

/// TODO We should check for version 5.14+ at runtime, but we either should
/// add the `nix` dependency to get it efficiently, or vendor the code to read
/// both of which are overkill for such a feature. If we need this dependency
/// for more things later, we'll use it here too.
#[cfg(target_os = "linux")]
fn can_advise_populate_read() -> bool {
    true
}

#[cfg(not(target_os = "linux"))]
fn can_advise_populate_read() -> bool {
    false
}

/// Call `madvise` on the mmap with `MADV_POPULATE_READ` in a separate thread
/// to populate the mmap in the background for a small perf improvement.
#[cfg(target_os = "linux")]
fn advise_populate_read_mmap(mmap: &memmap2::Mmap) {
    const MADV_POPULATE_READ: i32 = 22;

    // This is fine because the mmap is still referenced for at least
    // the duration of this function, and the kernel will reject any wrong
    // address.
    let ptr = mmap.as_ptr() as u64;
    let len = mmap.len();

    // Fire and forget. The `JoinHandle` returned by `spawn` is dropped right
    // after the call, the thread is thus detached. We don't care about success
    // or failure here.
    std::thread::spawn(move || unsafe {
        // mmap's pointer is always page-aligned on Linux. In the case of
        // file-based mmap (which is our use-case), the length should be
        // correct. If not, it's not a safety concern as the kernel will just
        // ignore unmapped pages and return ENOMEM, which we will promptly
        // ignore, because we don't care about any errors.
        libc::madvise(ptr as *mut libc::c_void, len, MADV_POPULATE_READ);
    });
}

#[cfg(not(target_os = "linux"))]
fn advise_populate_read_mmap(mmap: &memmap2::Mmap) {}

/// Open the revlog [`Index`] at `index_path`, through the `store_vfs` and the
/// given `options`. This controls whether (and how) we `mmap` the index file,
/// and returns an empty buffer if the index does not exist on disk.
/// This is only used when doing pure-Rust work, in Python contexts this is
/// unused at the time of writing.
pub fn open_index(
    store_vfs: &impl Vfs,
    index_path: &Path,
    options: RevlogOpenOptions,
) -> Result<Index, HgError> {
    let buf: IndexData = match store_vfs.open(index_path) {
        Ok(mut file) => {
            let mut buf = if let Some(threshold) =
                options.data_config.mmap_index_threshold
            {
                let size = store_vfs.file_size(&file)?;
                if size >= threshold {
                    // TODO madvise populate read in a background thread
                    let mut mmap_options = MmapOptions::new();
                    if !can_advise_populate_read() {
                        // Fall back to populating in the main thread if
                        // post-creation advice is not supported.
                        // Does nothing on platforms where it's not defined.
                        mmap_options.populate();
                    }
                    // Safety is "enforced" by locks and assuming other
                    // processes are well-behaved. If any misbehaving or
                    // malicious process does touch the index, it could lead
                    // to corruption. This is somewhat inherent to file-based
                    // `mmap`, though some platforms have some ways of
                    // mitigating.
                    // TODO linux: set the immutable flag with `chattr(1)`?
                    let mmap = unsafe { mmap_options.map(&file) }
                        .when_reading_file(index_path)?;

                    if can_advise_populate_read() {
                        advise_populate_read_mmap(&mmap);
                    }

                    Some(Box::new(mmap) as IndexData)
                } else {
                    None
                }
            } else {
                None
            };

            if buf.is_none() {
                let mut data = vec![];
                file.read_to_end(&mut data).when_reading_file(index_path)?;
                buf = Some(Box::new(data) as IndexData);
            }
            buf.unwrap()
        }
        Err(err) => match err {
            HgError::IoError { error, context } => match error.kind() {
                ErrorKind::NotFound => Box::<Vec<u8>>::default(),
                _ => return Err(HgError::IoError { error, context }),
            },
            e => return Err(e),
        },
    };

    let index = Index::new(buf, options.index_header())?;
    Ok(index)
}

/// The revlog entry's bytes and the necessary informations to extract
/// the entry's data.
#[derive(Clone)]
pub struct RevlogEntry<'revlog> {
    revlog: &'revlog InnerRevlog,
    rev: Revision,
    uncompressed_len: i32,
    p1: Revision,
    p2: Revision,
    flags: u16,
    hash: Node,
}

impl<'revlog> RevlogEntry<'revlog> {
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

    pub fn p1_entry(
        &self,
    ) -> Result<Option<RevlogEntry<'revlog>>, RevlogError> {
        if self.p1 == NULL_REVISION {
            Ok(None)
        } else {
            Ok(Some(self.revlog.get_entry(self.p1)?))
        }
    }

    pub fn p2_entry(
        &self,
    ) -> Result<Option<RevlogEntry<'revlog>>, RevlogError> {
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
    /// Non-Python callers should probably call [`Self::data`] instead.
    fn rawdata<G, T>(
        &self,
        stop_rev: Option<(Revision, &[u8])>,
        with_buffer: G,
    ) -> Result<(), RevlogError>
    where
        G: FnOnce(
            usize,
            &mut dyn FnMut(
                &mut dyn RevisionBuffer<Target = T>,
            ) -> Result<(), RevlogError>,
        ) -> Result<(), RevlogError>,
    {
        let (delta_chain, stopped) = self
            .revlog
            .delta_chain(self.revision(), stop_rev.map(|(r, _)| r))?;
        let target_size =
            self.uncompressed_len().map(|raw_size| 4 * raw_size as u64);

        let deltas = self.revlog.chunks(delta_chain, target_size)?;

        let (base_text, deltas) = if stopped {
            (
                stop_rev.as_ref().expect("last revision should be cached").1,
                &deltas[..],
            )
        } else {
            let (buf, deltas) = deltas.split_at(1);
            (buf[0].as_ref(), deltas)
        };

        let size = self
            .uncompressed_len()
            .map(|l| l as usize)
            .unwrap_or(base_text.len());
        with_buffer(size, &mut |buf| {
            Revlog::build_data_from_deltas(buf, base_text, deltas)?;
            Ok(())
        })?;
        Ok(())
    }

    fn check_data(
        &self,
        data: Cow<'revlog, [u8]>,
    ) -> Result<Cow<'revlog, [u8]>, RevlogError> {
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
                    "support for ellipsis nodes is missing",
                )
                .into());
            }
            Err(corrupted(format!(
                "hash check failed for revision {}",
                self.rev
            ))
            .into())
        }
    }

    pub fn data(&self) -> Result<Cow<'revlog, [u8]>, RevlogError> {
        // TODO figure out if there is ever a need for `Cow` here anymore.
        let mut data = CoreRevisionBuffer::new();
        if self.rev == NULL_REVISION {
            return Ok(data.finish().into());
        }
        self.rawdata(None, |size, f| {
            // Pre-allocate the expected size (received from the index)
            data.resize(size);
            // Actually fill the buffer
            f(&mut data)?;
            Ok(())
        })?;
        if self.is_censored() {
            return Err(HgError::CensoredNodeError.into());
        }
        self.check_data(data.finish().into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::revlog::index::IndexEntryBuilder;
    use itertools::Itertools;

    #[test]
    fn test_empty() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = VfsImpl::new(temp.path().to_owned(), false);
        std::fs::write(temp.path().join("foo.i"), b"").unwrap();
        std::fs::write(temp.path().join("foo.d"), b"").unwrap();
        let revlog =
            Revlog::open(&vfs, "foo.i", None, RevlogOpenOptions::default())
                .unwrap();
        assert!(revlog.is_empty());
        assert_eq!(revlog.len(), 0);
        assert!(revlog.get_entry_for_unchecked_rev(0.into()).is_err());
        assert!(!revlog.has_rev(0.into()));
        assert_eq!(
            revlog.rev_from_node(NULL_NODE.into()).unwrap(),
            NULL_REVISION
        );
        let null_entry = revlog
            .get_entry_for_unchecked_rev(NULL_REVISION.into())
            .ok()
            .unwrap();
        assert_eq!(null_entry.revision(), NULL_REVISION);
        assert!(null_entry.data().unwrap().is_empty());
    }

    #[test]
    fn test_inline() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = VfsImpl::new(temp.path().to_owned(), false);
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
            .with_node(node0)
            .build();
        let entry1_bytes = IndexEntryBuilder::new().with_node(node1).build();
        let entry2_bytes = IndexEntryBuilder::new()
            .with_p1(Revision(0))
            .with_p2(Revision(1))
            .with_node(node2)
            .build();
        let contents = vec![entry0_bytes, entry1_bytes, entry2_bytes]
            .into_iter()
            .flatten()
            .collect_vec();
        std::fs::write(temp.path().join("foo.i"), contents).unwrap();
        let revlog =
            Revlog::open(&vfs, "foo.i", None, RevlogOpenOptions::default())
                .unwrap();

        let entry0 =
            revlog.get_entry_for_unchecked_rev(0.into()).ok().unwrap();
        assert_eq!(entry0.revision(), Revision(0));
        assert_eq!(*entry0.node(), node0);
        assert!(!entry0.has_p1());
        assert_eq!(entry0.p1(), None);
        assert_eq!(entry0.p2(), None);
        let p1_entry = entry0.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry0.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry1 =
            revlog.get_entry_for_unchecked_rev(1.into()).ok().unwrap();
        assert_eq!(entry1.revision(), Revision(1));
        assert_eq!(*entry1.node(), node1);
        assert!(!entry1.has_p1());
        assert_eq!(entry1.p1(), None);
        assert_eq!(entry1.p2(), None);
        let p1_entry = entry1.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry1.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry2 =
            revlog.get_entry_for_unchecked_rev(2.into()).ok().unwrap();
        assert_eq!(entry2.revision(), Revision(2));
        assert_eq!(*entry2.node(), node2);
        assert!(entry2.has_p1());
        assert_eq!(entry2.p1(), Some(Revision(0)));
        assert_eq!(entry2.p2(), Some(Revision(1)));
        let p1_entry = entry2.p1_entry().unwrap();
        assert!(p1_entry.is_some());
        assert_eq!(p1_entry.unwrap().revision(), Revision(0));
        let p2_entry = entry2.p2_entry().unwrap();
        assert!(p2_entry.is_some());
        assert_eq!(p2_entry.unwrap().revision(), Revision(1));
    }

    #[test]
    fn test_nodemap() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = VfsImpl::new(temp.path().to_owned(), false);

        // building a revlog with a forced Node starting with zeros
        // This is a corruption, but it does not preclude using the nodemap
        // if we don't try and access the data
        let node0 = Node::from_hex("00d2a3912a0b24502043eae84ee4b279c18b90dd")
            .unwrap();
        let node1 = Node::from_hex("b004912a8510032a0350a74daa2803dadfb00e12")
            .unwrap();
        let entry0_bytes = IndexEntryBuilder::new()
            .is_first(true)
            .with_version(1)
            .with_inline(true)
            .with_node(node0)
            .build();
        let entry1_bytes = IndexEntryBuilder::new().with_node(node1).build();
        let contents = vec![entry0_bytes, entry1_bytes]
            .into_iter()
            .flatten()
            .collect_vec();
        std::fs::write(temp.path().join("foo.i"), contents).unwrap();

        let mut idx = nodemap::tests::TestNtIndex::new();
        idx.insert_node(Revision(0), node0).unwrap();
        idx.insert_node(Revision(1), node1).unwrap();

        let revlog = Revlog::open_gen(
            &vfs,
            "foo.i",
            None,
            RevlogOpenOptions::default(),
            Some(idx.nt),
        )
        .unwrap();

        // accessing the data shows the corruption
        revlog
            .get_entry_for_unchecked_rev(0.into())
            .unwrap()
            .data()
            .unwrap_err();

        assert_eq!(
            revlog.rev_from_node(NULL_NODE.into()).unwrap(),
            Revision(-1)
        );
        assert_eq!(revlog.rev_from_node(node0.into()).unwrap(), Revision(0));
        assert_eq!(revlog.rev_from_node(node1.into()).unwrap(), Revision(1));
        assert_eq!(
            revlog
                .rev_from_node(NodePrefix::from_hex("000").unwrap())
                .unwrap(),
            Revision(-1)
        );
        assert_eq!(
            revlog
                .rev_from_node(NodePrefix::from_hex("b00").unwrap())
                .unwrap(),
            Revision(1)
        );
        // RevlogError does not implement PartialEq
        // (ultimately because io::Error does not)
        match revlog
            .rev_from_node(NodePrefix::from_hex("00").unwrap())
            .expect_err("Expected to give AmbiguousPrefix error")
        {
            RevlogError::AmbiguousPrefix(_) => (),
            e => {
                panic!("Got another error than AmbiguousPrefix: {:?}", e);
            }
        };
    }
}
