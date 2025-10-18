// Copyright 2018-2023 Georges Racinet <georges.racinet@octobus.net>
//           and Mercurial contributors
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
//! Mercurial concepts for handling revision history

pub mod deltas;
pub mod diff;
pub mod node;
pub mod nodemap;
mod nodemap_docket;
pub mod path_encode;
use inner_revlog::CoreRevisionBuffer;
use inner_revlog::InnerRevlog;
use inner_revlog::RevisionBuffer;
use memmap2::MmapOptions;
pub use node::FromHexError;
pub use node::Node;
pub use node::NodePrefix;
pub use node::NULL_NODE;
pub use node::NULL_NODE_ID;
use nodemap::read_persistent_nodemap;
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

use std::io::ErrorKind;
use std::io::Read;
use std::path::Path;

use self::nodemap_docket::NodeMapDocket;
use crate::dyn_bytes::DynBytes;
use crate::errors::HgBacktrace;
use crate::errors::HgError;
use crate::errors::IoResultExt;
use crate::exit_codes;
use crate::revlog::index::Index;
use crate::revlog::nodemap::NodeMap;
use crate::revlog::nodemap::NodeMapError;
use crate::utils::u32_u;
use crate::utils::RawData;
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

impl UncheckedRevision {
    pub fn is_nullrev(&self) -> bool {
        self.0 == -1
    }
}

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

/// Either a checked revision or the working directory.
/// Note that [`Revision`] will never hold [`WORKING_DIRECTORY_REVISION`]
/// because that is not a valid revision in any revlog.
#[derive(Copy, Clone, Hash, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct RevisionOrWdir(BaseRevision);

impl From<Revision> for RevisionOrWdir {
    fn from(value: Revision) -> Self {
        RevisionOrWdir(value.0)
    }
}

impl RevisionOrWdir {
    /// Creates a [`RevisionOrWdir`] representing the working directory.
    pub fn wdir() -> Self {
        RevisionOrWdir(WORKING_DIRECTORY_REVISION.0)
    }

    /// Returns the revision, or `None` if this is the working directory.
    pub fn exclude_wdir(self) -> Option<Revision> {
        if self.0 == WORKING_DIRECTORY_REVISION.0 {
            None
        } else {
            Some(Revision(self.0))
        }
    }

    /// Returns true if this is the working directory.
    pub fn is_wdir(&self) -> bool {
        *self == Self::wdir()
    }
}

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

    /// Return a reference to the Node
    fn node(&self, rev: Revision) -> &Node;

    /// Return a [`Revision`] if `rev` is a valid revision number for this
    /// index.
    ///
    /// [`NULL_REVISION`] is considered to be valid.
    #[inline(always)]
    fn check_revision(&self, rev: UncheckedRevision) -> Option<Revision> {
        let rev = rev.0;

        if rev == NULL_REVISION.0 || (rev >= 0 && (rev as usize) < self.len()) {
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
const REVISION_FLAG_HASMETA: u16 = 1 << 11;
const REVISION_FLAG_DELTA_IS_SNAPSHOT: u16 = 1 << 10;

// Keep this in sync with REVIDX_KNOWN_FLAGS in
// mercurial/revlogutils/flagutil.py
const REVIDX_KNOWN_FLAGS: u16 = REVISION_FLAG_CENSORED
    | REVISION_FLAG_ELLIPSIS
    | REVISION_FLAG_EXTSTORED
    | REVISION_FLAG_HASCOPIESINFO
    | REVISION_FLAG_HASMETA
    | REVISION_FLAG_DELTA_IS_SNAPSHOT;

const NULL_REVLOG_ENTRY_FLAGS: u16 = 0;

#[derive(Debug, derive_more::From, derive_more::Display)]
pub enum RevlogError {
    #[display("invalid revision identifier: {}", "_0")]
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
        revlog_type: RevlogType,
    ) -> Result<Self, HgError> {
        Self::open_gen(
            store_vfs,
            index_path,
            data_path,
            options,
            None,
            revlog_type,
        )
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
        revlog_type: RevlogType,
    ) -> Result<Self, HgError> {
        let index_path = index_path.as_ref();
        let index = open_index(store_vfs, index_path, options)?;

        let default_data_path = index_path.with_extension("d");
        let data_path = data_path.unwrap_or(&default_data_path);

        let nodemap = if index.is_inline() || !options.use_nodemap {
            None
        } else {
            read_persistent_nodemap(store_vfs, index_path, &index)?
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
                revlog_type,
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
        self.index().get_entry(rev).hash()
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

    pub fn get_entry(&self, rev: Revision) -> Result<RevlogEntry, RevlogError> {
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
        let entry = self.index().get_entry(rev);
        linked_revlog.index().check_revision(entry.link_revision()).ok_or_else(
            || {
                RevlogError::corrupted(format!(
                    "linkrev for rev {} is invalid",
                    rev
                ))
            },
        )
    }

    /// Return the full data associated to a revision.
    ///
    /// All entries required to build the final data out of deltas will be
    /// retrieved as needed, and the deltas will be applied to the initial
    /// snapshot to rebuild the final data.
    pub fn get_data_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<RawData, RevlogError> {
        if rev == NULL_REVISION.into() {
            return Ok(RawData::empty());
        };
        self.get_entry_for_unchecked_rev(rev)?.data()
    }

    /// [`Self::get_data_for_unchecked_rev`] for a checked [`Revision`].
    pub fn get_data(&self, rev: Revision) -> Result<RawData, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(RawData::empty());
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
        let entry = index.get_entry(rev);
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
}

pub struct RawdataBuf {
    // If `Some`, data is a delta.
    base: Option<UncheckedRevision>,
    data: RawData,
}

impl RawdataBuf {
    fn as_delta(&self) -> Result<patch::Delta, RevlogError> {
        match self.base {
            None => Ok(patch::Delta::full_snapshot(&self.data)),
            Some(_) => patch::Delta::new(&self.data),
        }
    }
}

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
    let buf: DynBytes = match store_vfs.open(index_path) {
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

                    Some(DynBytes::new(Box::new(mmap)))
                } else {
                    None
                }
            } else {
                None
            };

            if buf.is_none() {
                let mut data = vec![];
                file.read_to_end(&mut data).when_reading_file(index_path)?;
                buf = Some(DynBytes::new(Box::new(data)));
            }
            buf.unwrap()
        }
        Err(err) => match err {
            HgError::IoError { error, context, backtrace } => {
                match error.kind() {
                    ErrorKind::NotFound => DynBytes::default(),
                    _ => {
                        return Err(HgError::IoError {
                            error,
                            context,
                            backtrace,
                        })
                    }
                }
            }
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

    fn check_data(&self, data: RawData) -> Result<RawData, RevlogError> {
        if self.revlog.check_hash(self.p1, self.p2, self.hash.as_bytes(), &data)
        {
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

    /// Get the revision data, without checking it integrity
    fn data_unchecked(&self) -> Result<RawData, RevlogError> {
        if self.rev == NULL_REVISION {
            return Ok(RawData::empty());
        }
        if self.is_censored() {
            return Err(HgError::CensoredNodeError(
                *self.node(),
                HgBacktrace::capture(),
            )
            .into());
        }
        let raw_size = self.uncompressed_len();
        if let Some(size) = raw_size {
            if size == 0 {
                return Ok(RawData::empty());
            }
            self.revlog.seen_file_size(u32_u(size));
        }
        let cached_rev = self.revlog.get_rev_cache();
        if let Some(ref cached) = cached_rev {
            if cached.rev == self.rev {
                let raw_text = cached.as_data();
                self.revlog.set_rev_cache_native(self.rev, &raw_text);
                return Ok(raw_text);
            }
        }
        let cache = cached_rev.as_ref().map(|c| c.as_delta_base());
        let stop_rev = cache.map(|(r, _)| r);
        let (chunks, stopped) =
            self.revlog.chunks_for_chain(self.revision(), stop_rev)?;
        let (base_text, deltas) = if stopped {
            if chunks.is_empty() {
                // The revision is equivalent to another one, just return the
                // equivalent one.
                let cache_value =
                    cached_rev.expect("cannot stop without a cache");
                let raw_text = cache_value.as_data();
                self.revlog.set_rev_cache_native(self.rev, &raw_text);
                return Ok(raw_text);
            }
            let cache_value = cache.expect("cannot stop without a cache");
            let base_text = cache_value.1;
            (base_text, &chunks[..])
        } else {
            let base_text = &chunks[0];
            let deltas = &chunks[1..];
            if deltas.is_empty() {
                // The revision is equivalent to another one, just return the
                // equivalent one.
                return Ok(chunks
                    .into_iter()
                    .next()
                    .expect("the base must exists"));
            }
            (base_text.as_ref(), deltas)
        };
        let size = raw_size.map(|l| l as usize).unwrap_or(base_text.len());

        let mut data = CoreRevisionBuffer::new();
        data.resize(size);
        patch::build_data_from_deltas(&mut data, base_text, deltas)?;
        let raw_text: RawData = data.finish().into();
        self.revlog.set_rev_cache_native(self.rev, &raw_text);
        Ok(raw_text)
    }

    /// Get the revision data, checking its integrity in the process
    pub fn data(&self) -> Result<RawData, RevlogError> {
        if self.rev == NULL_REVISION {
            return Ok(RawData::empty());
        }
        self.check_data(self.data_unchecked()?)
    }
}

#[cfg(test)]
mod tests {
    use itertools::Itertools;

    use super::*;
    use crate::revlog::index::IndexEntryBuilder;
    use crate::revlog::path_encode::PathEncoding;

    #[test]
    fn test_empty() {
        let temp = tempfile::tempdir().unwrap();
        let vfs = VfsImpl::new(
            temp.path().to_owned(),
            false,
            PathEncoding::DotEncode,
        );
        std::fs::write(temp.path().join("foo.i"), b"").unwrap();
        std::fs::write(temp.path().join("foo.d"), b"").unwrap();
        let revlog = Revlog::open(
            &vfs,
            "foo.i",
            None,
            RevlogOpenOptions::default(),
            RevlogType::Changelog,
        )
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
        let vfs = VfsImpl::new(
            temp.path().to_owned(),
            false,
            PathEncoding::DotEncode,
        );
        let node0 =
            Node::from_hex("2ed2a3912a0b24502043eae84ee4b279c18b90dd").unwrap();
        let node1 =
            Node::from_hex("b004912a8510032a0350a74daa2803dadfb00e12").unwrap();
        let node2 =
            Node::from_hex("dd6ad206e907be60927b5a3117b97dffb2590582").unwrap();
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
        let revlog = Revlog::open(
            &vfs,
            "foo.i",
            None,
            RevlogOpenOptions::default(),
            RevlogType::Changelog,
        )
        .unwrap();

        let entry0 = revlog.get_entry_for_unchecked_rev(0.into()).ok().unwrap();
        assert_eq!(entry0.revision(), Revision(0));
        assert_eq!(*entry0.node(), node0);
        assert!(!entry0.has_p1());
        assert_eq!(entry0.p1(), None);
        assert_eq!(entry0.p2(), None);
        let p1_entry = entry0.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry0.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry1 = revlog.get_entry_for_unchecked_rev(1.into()).ok().unwrap();
        assert_eq!(entry1.revision(), Revision(1));
        assert_eq!(*entry1.node(), node1);
        assert!(!entry1.has_p1());
        assert_eq!(entry1.p1(), None);
        assert_eq!(entry1.p2(), None);
        let p1_entry = entry1.p1_entry().unwrap();
        assert!(p1_entry.is_none());
        let p2_entry = entry1.p2_entry().unwrap();
        assert!(p2_entry.is_none());

        let entry2 = revlog.get_entry_for_unchecked_rev(2.into()).ok().unwrap();
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
        let vfs = VfsImpl::new(
            temp.path().to_owned(),
            false,
            PathEncoding::DotEncode,
        );

        // building a revlog with a forced Node starting with zeros
        // This is a corruption, but it does not preclude using the nodemap
        // if we don't try and access the data
        let node0 =
            Node::from_hex("00d2a3912a0b24502043eae84ee4b279c18b90dd").unwrap();
        let node1 =
            Node::from_hex("b004912a8510032a0350a74daa2803dadfb00e12").unwrap();
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
            RevlogType::Changelog,
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
            revlog.rev_from_node(NodePrefix::from_hex("000").unwrap()).unwrap(),
            Revision(-1)
        );
        assert_eq!(
            revlog.rev_from_node(NodePrefix::from_hex("b00").unwrap()).unwrap(),
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

    #[test]
    fn test_revision_or_wdir_ord() {
        let highest: RevisionOrWdir = Revision(i32::MAX - 1).into();
        assert!(highest < RevisionOrWdir::wdir());
    }
}
