//! Defines interfaces that the FUSE calls into to interact with the Mercurial
//! store.

use std::path::PathBuf;

use hg::Node;
use hg::errors::HgBacktrace;
use hg::errors::HgError;
use hg::revlog::manifest::ManifestFlags;
use hg::utils::RawData;
use hg::utils::hg_path::HgPath;
use hg::utils::hg_path::HgPathBuf;

use crate::server::Config;

/// Enumerates the kinds of errors that can happen from interacting with the
/// store.
#[derive(Debug)]
#[non_exhaustive]
pub enum ErrorKind<T> {
    /// This changeset node id does not exist
    NoSuchChangeset(Node),
    /// This path does not exist inside this valid changeset
    NoSuchFile { changeset: Node, path: HgPathBuf, token: T },
    /// This token is invalid for this valid path inside this valid changeset
    InvalidToken { changeset: Node, path: HgPathBuf, token: T },
    /// This revision idx does not match a valid changeset
    InvalidRevisionIdx(RevisionIdx),
    /// Reading this file failed somehow
    ReadFailed { changeset: Node, path: HgPathBuf, token: T },
    /// Catch-all error. You should really think about defining a fine-grained
    /// structured error case before using this.
    /// TODO flesh out more likely (and non-string-based) cases
    Other(Vec<u8>),
}

/// Defines an error that happened when interacting with a [`StoreBackend`].
#[derive(Debug)]
pub struct Error<T> {
    /// Which kind of error occurred
    pub kind: ErrorKind<T>,
    /// The backtrace pointing to where the error occurred
    pub backtrace: HgBacktrace,
}

impl<T> From<ErrorKind<T>> for Error<T> {
    fn from(kind: ErrorKind<T>) -> Self {
        Self { kind, backtrace: HgBacktrace::capture() }
    }
}
impl<T> From<HgError> for Error<T> {
    fn from(err: HgError) -> Self {
        Self {
            kind: ErrorKind::Other(format!("hg error: {:?}", err).into_bytes()),
            backtrace: HgBacktrace::capture(),
        }
    }
}

/// Minimal set of methods to enable a read-only "archive mode" (i.e. no real
/// `.hg`, only very select hg commands work)
pub trait StoreBackend<T: FileToken>: Send + Sync + 'static {
    /// Returns the config for this instance of the FUSE
    fn server_config(&self) -> &Config;

    /// Returns the branch name for this changelog node id
    ///
    /// # Errors
    ///
    /// Must return [`Error::NoSuchChangeset`] if the node does not exist
    /// in the store.
    fn branch(&self, changeset: Node) -> Result<String, Error<T>>;

    /// Returns the [`RevisionIdx`] corresponding to this changelog node id.
    /// This [`RevisionIdx`] must be unique for each node id.
    ///
    /// This is the reverse operation of [`Self::node_for_idx`].
    ///
    /// (This is due to an implementation detail of the FUSE and will not be
    /// required in the long run)
    ///
    /// # Errors
    ///
    /// Must return [`Error::NoSuchChangeset`] if the node does not exist
    /// in the store.
    fn idx_for_node(&self, changeset: Node) -> Result<RevisionIdx, Error<T>>;

    /// Returns the unique changeset [`Node`] corresponding to this
    /// [`RevisionIdx`].
    ///
    /// This is the reverse operation of [`Self::idx_for_node`].
    ///
    /// (This is due to an implementation detail of the FUSE and will not be
    /// required in the long run)
    ///
    /// # Errors
    ///
    /// Must return [`Error::InvalidRevisionIdx`] if the idx does not match a
    /// valid changeset in the store.
    fn node_for_idx(&self, idx: RevisionIdx) -> Result<Node, Error<T>>;

    /// Returns an iterable of all files and their info at this changeset.
    ///
    /// # Errors
    ///
    /// Must return [`Error::NoSuchChangeset`] if the node does not exist in
    /// the store
    fn changeset_files(
        &self,
        changeset: Node,
    ) -> Result<impl ChangesetFiles<T>, Error<T>>;

    /// Returns the file content for that path at this changeset
    /// (i.e uncompressed file datastripped of its metadata)
    ///
    /// The token was provided by [`Self::changeset_files`] as a way of
    /// facilitating an opaque optimization should the store need it to
    /// efficiently fetch the data.
    ///
    /// # Errors
    ///
    /// * Must return [`Error::NoSuchChangeset`] if the node does not exist in
    ///   the store
    /// * Must return [`Error::NoSuchFile`] if the path does not exist at this
    ///   revision
    /// * Must return [`Error::InvalidToken`] if the token is invalid for this
    ///   valid node and valid path.
    fn file_data(
        &self,
        changeset: Node,
        path: &HgPath,
        token: T,
    ) -> Result<RawData, Error<T>>;

    /// Returns information about the store underpinning this FUSE, if
    /// applicable.
    fn changeset_store_info(
        &self,
        _changeset: Node,
    ) -> Result<Option<StoreInfo>, Error<T>> {
        Ok(None)
    }
}

/// A trait whose only method enables iteration over a given changeset's files.
/// Allows for a [`StoreBackend`] implementation to have more control over how
/// to iterate efficiently, by e.g. returning a self-referencing struct and
/// eschewing path clones.
pub trait ChangesetFiles<T: FileToken> {
    /// Returns an iterator of information for every tracked file in this
    /// changeset. Each [`FileInfo`] must refer to a unique file, and
    /// folders should not be included.
    fn iter(&self) -> impl Iterator<Item = &FileInfo<'_, T>>;
}

/// An opaque token for a given file revision. This can be used as an
/// optimization by the store to more efficiently query file data.
pub trait FileToken:
    Send + Sync + Copy + Clone + std::fmt::Debug + 'static
{
}

/// An opaque index, unique for every changeset, due to a current implementation
/// detail of the FUSE. Will be removed at some point in the future.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RevisionIdx(pub u32);

/// Information about the store to be written to a working copy's `.hg` folder
#[derive(Debug)]
pub struct StoreInfo {
    /// The changeset for debugging purposes
    pub changeset: Node,
    /// The full path to the .hg folder of the store
    pub share_source: PathBuf,
    /// The raw on-disk narrow patterns for this changeset, if any
    pub narrow_patterns: Option<Vec<u8>>,
    /// True if the repository uses the `sparse` requirement
    pub has_sparse: bool,
    /// The branch for this changeset
    pub branch: String,
}

/// Information associated with a given file at a certain revision
pub struct FileInfo<'store, T> {
    /// The full path of that file relative to the root of the working copy
    pub path: &'store HgPath,
    /// The size in bytes of the uncompressed contents, stripped of their
    /// metadata
    pub size: u64,
    /// The flags for this file revision
    pub flags: ManifestFlags,
    /// An opaque token, see [`FileRevisionToken`]
    pub token: T,
}
