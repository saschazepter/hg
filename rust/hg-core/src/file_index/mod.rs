//! The file index maps file paths in a repository to integer tokens.
//! See `mercurial/helptext/internals/fileindex.txt` for more details.

use std::collections::HashSet;
use std::io::BufWriter;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;
use std::ops::Deref;
use std::path::Path;
use std::path::PathBuf;

use bytes_cast::BytesCast;
use indexmap::IndexSet;
use mutable_tree::MutableTree;
pub use on_disk::DebugTreeNode;
pub use on_disk::DebugTreeNodeIter;
pub use on_disk::Docket;
pub use on_disk::Error;
use on_disk::FileIndexView;
use on_disk::GarbageEntry;
use on_disk::Metadata;
use on_disk::OwnedDataFiles;
use on_disk::OwnedFileIndexView;
pub use on_disk::PathInfo;
use on_disk::EMPTY_TREE_BYTES;

use crate::errors::HgError;
use crate::errors::IoResultExt;
use crate::transaction::Transaction;
use crate::utils::docket::FileUid;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::u32_u;
use crate::utils::u_u32;
use crate::vfs::is_on_nfs_mount;
use crate::vfs::Vfs;
use crate::vfs::VfsFile;
use crate::vfs::VfsImpl;

mod mutable_tree;
mod on_disk;

#[cfg(test)]
mod tests;

/// Minimum size of the tree file in bytes before auto-vacuuming starts.
///
/// The value was picked by adding files one by one in individual transaction.
/// 16K allows for adding 100 files before tree file is shrink down to 1.5K
const AUTO_VACUUM_MIN_SIZE: u32 = 16 * 1024;

/// Initial TTL when adding a file to garbage_entries. Each hg transaction that
/// follows will decrement it by 1, and will not delete it until it reaches 0.
const INITIAL_GARBAGE_TTL: u16 = 2;

/// An integer that represents a file path in the repository.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub struct FileToken(pub u32);

/// Values of the config `devel.fileindex.vacuum-mode`.
#[derive(Debug, Copy, Clone, Default)]
pub enum VacuumMode {
    #[default]
    Auto,
    Never,
    Always,
}

impl VacuumMode {
    pub fn parse(value: &[u8]) -> Option<Self> {
        match value {
            b"auto" => Some(VacuumMode::Auto),
            b"never" => Some(VacuumMode::Never),
            b"always" => Some(VacuumMode::Always),
            _ => None,
        }
    }
}

/// Configuration for the file index.
pub struct Config {
    /// Value of config `devel.fileindex.vacuum-mode`.
    pub vacuum_mode: VacuumMode,
    /// Value of config `storage.fileindex.max-unused-percentage`, converted to
    /// a ratio from 0 to 1.
    pub max_unused_ratio: f64,
    /// Value of the config `storage.fileindex.gc-retention-seconds`.
    pub gc_retention_s: u32,
    /// Value of the config `devel.fileindex.garbage-timestamp`.
    pub garbage_timestamp: Option<u32>,
}

/// The main file index object. It provides a high level interface that
/// abstracts over data on disk and pending changes in memory.
pub struct FileIndex {
    /// VFS for reading the docket and data files.
    vfs: VfsImpl,
    /// Docket read from disk, or [`Docket::default()`] if there is none.
    docket: Docket,
    /// Read-only view of the file index on disk.
    on_disk: OwnedFileIndexView,
    /// Configuration values.
    config: Config,
    /// Whether to force a vacuum on the next write.
    force_vacuum: bool,
    /// Paths to be added on the next write.
    add_paths: IndexSet<HgPathBuf>,
    /// Tokens to be removed on the next write.
    remove_tokens: HashSet<FileToken>,
}

impl FileIndex {
    /// Opens the file index from the given store VFS.
    /// If `try_pending` is true, tries reading the pending docket first.
    /// Calls `devel_sync_point` in between reading the docket and data files.
    pub fn open(
        vfs: VfsImpl,
        try_pending: bool,
        config: Config,
        devel_sync_point: impl FnOnce(),
    ) -> Result<Self, HgError> {
        let docket = Self::read_docket(&vfs, try_pending)?;
        devel_sync_point();
        let on_disk = Self::load(&docket, &vfs)?;
        Ok(Self {
            vfs,
            docket,
            on_disk,
            config,
            force_vacuum: false,
            add_paths: IndexSet::new(),
            remove_tokens: HashSet::new(),
        })
    }

    /// Loads an [`OwnedFileIndexView`] from disk.
    fn load(
        docket: &Docket,
        vfs: &VfsImpl,
    ) -> Result<OwnedFileIndexView, HgError> {
        let list_file = Self::read_file(vfs, docket.list_file_path(), b"")?;
        let meta_file = Self::read_file(vfs, docket.meta_file_path(), b"")?;
        let tree_file =
            Self::read_file(vfs, docket.tree_file_path(), &EMPTY_TREE_BYTES)?;
        let files = OwnedDataFiles { list_file, meta_file, tree_file };
        Ok(OwnedFileIndexView::open(docket, files)?)
    }

    /// Returns the file index docket.
    pub fn docket(&self) -> &Docket {
        &self.docket
    }

    /// Reads the docket from disk, trying the pending version first if
    /// `try_pending` is true. Returns a default docket if there's none on disk.
    fn read_docket(
        vfs: &VfsImpl,
        try_pending: bool,
    ) -> Result<Docket, HgError> {
        let mut data = None;
        if try_pending {
            data = vfs.try_read(Docket::pending_path())?;
        }
        if data.is_none() {
            data = vfs.try_read(Docket::path())?;
        }
        Ok(match data {
            Some(data) => Docket::read(&data)?,
            None => Docket::default(),
        })
    }

    /// Reads a file from disk using mmap if possible.
    /// Returns `default` if the file does not exist.
    fn read_file(
        vfs: &VfsImpl,
        path: Option<PathBuf>,
        default: &'static [u8],
    ) -> Result<Box<dyn Deref<Target = [u8]> + Send + Sync>, HgError> {
        let Some(path) = path else {
            return Ok(Box::new(default));
        };
        if is_on_nfs_mount(&vfs.base) {
            Ok(Box::new(vfs.read(&path)?))
        } else {
            Ok(Box::new(vfs.mmap_open(&path)?))
        }
    }

    fn on_disk(&self) -> &FileIndexView {
        self.on_disk.borrow_dependent()
    }

    /// Returns the number of tokens allocated (equivalently, the value to be
    /// used for the next token).
    fn token_count(&self) -> u32 {
        u_u32(self.on_disk().len() + self.add_paths.len())
    }

    /// Returns true if `token` exists in the file index.
    pub fn has_token(&self, token: FileToken) -> bool {
        token.0 < self.token_count() && !self.remove_tokens.contains(&token)
    }

    /// Returns true if `path` exists in the file index.
    pub fn has_path(&self, path: &HgPath) -> Result<bool, Error> {
        Ok(self.get_token(path)?.is_some())
    }

    /// Looks up a path by token.
    pub fn get_path(&self, token: FileToken) -> Result<Option<&HgPath>, Error> {
        if !self.has_token(token) {
            return Ok(None);
        }
        let index = u32_u(token.0);
        let len = self.on_disk().len();
        if index < len {
            return self.on_disk().get_path(token);
        }
        Ok(Some(
            self.add_paths
                .get_index(index - len)
                .expect("should exist since has_token returned true"),
        ))
    }

    /// Looks up a token by path.
    pub fn get_token(&self, path: &HgPath) -> Result<Option<FileToken>, Error> {
        if let Some(index) = self.add_paths.get_index_of(path) {
            return Ok(Some(FileToken(u_u32(self.on_disk().len() + index))));
        };
        Ok(self
            .on_disk()
            .get_token(path)?
            .filter(|token| !self.remove_tokens.contains(token)))
    }

    /// Returns the number of paths in the file index.
    pub fn len(&self) -> usize {
        u32_u(self.token_count()) - self.remove_tokens.len()
    }

    /// Returns true if the file index is empty.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns an iterator over `(path, token)` pairs in the file index.
    pub fn iter(&self) -> PathTokenIter<'_> {
        PathTokenIter { inner: self, index: 0 }
    }

    /// Adds a path to the file index. Returns its token and a boolean which is
    /// true if the file was added and false if it was already present.
    pub fn add(&mut self, path: &HgPath) -> Result<(FileToken, bool), Error> {
        assert!(
            self.remove_tokens.is_empty(),
            "cannot add and remove in same txn"
        );
        if let Some(token) = self.get_token(path)? {
            return Ok((token, false));
        }
        let token = FileToken(self.token_count());
        self.add_paths.insert(path.to_owned());
        Ok((token, true))
    }

    /// Removes a path from the file index.
    ///
    /// # Panics
    ///
    /// Panics if the path is not in the file index.
    pub fn remove(&mut self, path: &HgPath) -> Result<(), Error> {
        assert!(self.add_paths.is_empty(), "cannot add and remove in same txn");
        let Some(token) = self.get_token(path)? else {
            panic!("path is not in file index");
        };
        self.remove_tokens.insert(token);
        Ok(())
    }

    /// Ensures the next write will vacuum the tree file.
    pub fn vacuum(&mut self) {
        self.force_vacuum = true;
    }

    /// Flush changes from [`Self::add`] or [`Self::remove`] to disk.
    /// Writes the data files, but only updates [`Self::docket`] in memory.
    /// It is the caller's responsibility to write the docket to disk.
    pub fn write(&mut self, tr: &mut impl Transaction) -> Result<(), HgError> {
        let clean = self.add_paths.is_empty() && self.remove_tokens.is_empty();
        if !clean || self.force_vacuum {
            let vacuum = self.should_vacuum();
            Self::write_data(
                &mut self.docket,
                &self.vfs,
                tr,
                &self.config,
                self.on_disk.borrow_dependent(),
                &self.add_paths,
                &self.remove_tokens,
                vacuum,
            )?;
            self.force_vacuum = false;
            self.add_paths.clear();
            self.remove_tokens.clear();
            self.on_disk = Self::load(&self.docket, &self.vfs)?;
        }
        Ok(())
    }

    /// Returns the current Unix timestamp in seconds, for garbage collection
    /// bookkeeping. Returns 0 if the system time is before the Unix epoch.
    fn unix_timestamp() -> u32 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or(std::time::Duration::ZERO)
            .as_secs()
            .try_into()
            .expect("u32 is good until 2106")
    }

    /// Return True if the current write should vacuum the tree file.
    fn should_vacuum(&self) -> bool {
        match self.config.vacuum_mode {
            _ if self.force_vacuum => true,
            VacuumMode::Always => true,
            VacuumMode::Never => false,
            VacuumMode::Auto => {
                let size = self.docket.header.tree_file_size.get();
                if size < AUTO_VACUUM_MIN_SIZE {
                    false
                } else {
                    let unused = self.docket.header.tree_unused_bytes.get();
                    let ratio = unused as f64 / size as f64;
                    ratio >= self.config.max_unused_ratio
                }
            }
        }
    }

    /// Deletes data files eligible for garbage collection.
    ///
    /// When the file index writes a new data file instead of appending to an
    /// existing one, it adds the old file to the garbage list. That file
    /// becomes eligible for garbage collection once the retention period has
    /// elapsed (configured by storage.fileindex.gc-retention-seconds) and a
    /// certain number of transactions have occurred.
    ///
    /// If force is True, deletes all files in the garbage list unconditionally.
    ///
    /// Returns true if any change was made to the docket's garbage list.
    pub fn garbage_collect(&mut self, force: bool) -> bool {
        let entries = &mut self.docket.garbage_entries;
        if entries.is_empty() {
            return false;
        }
        let now = Self::unix_timestamp();
        let eligible_for_gc = |entry: &GarbageEntry| -> bool {
            if entry.ttl > 0 {
                return false;
            }
            // Make zero a special case so timing never affects it.
            if self.config.gc_retention_s == 0 {
                return true;
            }
            now > entry.timestamp + self.config.gc_retention_s
        };
        let mut changed = false;
        entries.retain_mut(|entry| {
            if entry.ttl > 0 {
                entry.ttl -= 1;
                changed = true;
            }
            let delete = force || eligible_for_gc(entry);
            if delete {
                let _ = self.vfs.unlink(&entry.path); // best effort
                changed = true;
            }
            !delete
        });
        changed
    }

    pub fn data_files(&self) -> Vec<PathBuf> {
        [
            Some(Docket::path().to_owned()),
            self.docket.list_file_path(),
            self.docket.meta_file_path(),
            self.docket.tree_file_path(),
        ]
        .into_iter()
        .flatten()
        .collect()
    }

    pub fn debug_iter_tree_nodes(&self) -> DebugTreeNodeIter<'_> {
        self.on_disk().debug_iter_tree_nodes()
    }

    /// Writes all data files and updates `docket`.
    // Have to use lots of arguments to avoid lifetime issues with `&mut self`.
    #[allow(clippy::too_many_arguments)]
    fn write_data(
        docket: &mut Docket,
        vfs: &VfsImpl,
        tr: &mut impl Transaction,
        config: &Config,
        on_disk: &FileIndexView<'_>,
        add_paths: &IndexSet<HgPathBuf>,
        remove_tokens: &HashSet<FileToken>,
        vacuum: bool,
    ) -> Result<(), HgError> {
        if !remove_tokens.is_empty() {
            assert!(add_paths.is_empty(), "cannot add and remove in same txn");
            let tree = MutableTree::empty(on_disk.len() - remove_tokens.len());
            let add_paths = on_disk.iter().filter_map(|result| match result {
                Ok((_, token)) if remove_tokens.contains(&token) => None,
                Ok((info, _)) => Some(Ok(info.path())),
                Err(err) => Some(Err(err)),
            });
            return Self::write_data_impl(
                docket, vfs, tr, config, tree, add_paths, true,
            );
        }
        let tree = if docket.header.tree_file_id.is_unset() || vacuum {
            let mut tree = MutableTree::empty(on_disk.len() + add_paths.len());
            for (i, info) in on_disk.meta_array.iter().enumerate() {
                let path = HgPath::new(on_disk.read_span(info.path())?);
                tree.insert(path, FileToken(u_u32(i)), info.offset.get())?;
            }
            tree
        } else {
            MutableTree::with_base(on_disk, add_paths.len())?
        };
        let add_paths = add_paths.iter().map(|path| Ok(path.deref()));
        Self::write_data_impl(docket, vfs, tr, config, tree, add_paths, false)
    }

    /// Helper function for [`Self::write_data`].
    fn write_data_impl<'a>(
        docket: &mut Docket,
        vfs: &VfsImpl,
        tr: &mut impl Transaction,
        config: &Config,
        mut tree: MutableTree<'a>,
        add_paths: impl Iterator<Item = Result<&'a HgPath, Error>>,
        removing: bool,
    ) -> Result<(), HgError> {
        let new_list = docket.header.list_file_id.is_unset() || removing;
        let new_meta = docket.header.meta_file_id.is_unset() || removing;
        let new_tree = !tree.has_base();
        let timestamp =
            config.garbage_timestamp.unwrap_or_else(Self::unix_timestamp);
        let mut opener = FileOpener { docket, vfs, tr, timestamp };
        let list_file = opener.open_list_file(new_list)?;
        let list_file_path = normal_path(&list_file).to_owned();
        let mut list_file = BufWriter::new(list_file);
        let meta_file = opener.open_meta_file(new_meta)?;
        let meta_file_path = normal_path(&meta_file).to_owned();
        let mut meta_file = BufWriter::new(meta_file);
        // The tree file doesn't need buffering since we write it all at once.
        let mut tree_file = opener.open_tree_file(new_tree)?;
        let tree_file_path = normal_path(&tree_file).to_owned();
        let token_start = tree.len();
        let mut list_file_size = docket.header.list_file_size.get();
        let mut meta_file_size = docket.header.meta_file_size.get();
        for (i, path_result) in (token_start..).zip(add_paths) {
            let path = path_result?;
            let metadata = Metadata::new(path, list_file_size);
            list_file
                .write_all(path.as_bytes())
                .when_writing_file(&list_file_path)?;
            list_file.write_all(b"\x00").when_writing_file(&list_file_path)?;
            meta_file
                .write_all(metadata.as_bytes())
                .when_writing_file(&meta_file_path)?;
            tree.insert(path, FileToken(u_u32(i)), list_file_size)?;
            list_file_size += u_u32(path.len() + 1);
            meta_file_size += u_u32(std::mem::size_of::<Metadata>());
        }
        let serialized = tree.serialize();
        tree_file
            .write_all(&serialized.bytes)
            .when_writing_file(&tree_file_path)?;
        docket.header.list_file_size = list_file_size.into();
        docket.header.meta_file_size = meta_file_size.into();
        docket.header.tree_file_size = serialized.tree_file_size.into();
        docket.header.tree_root_pointer = serialized.tree_root_pointer.into();
        docket.header.tree_unused_bytes = serialized.tree_unused_bytes.into();
        docket.header.reserved_flags = [0; 4];
        Ok(())
    }
}

/// Helper for [`FileIndex::write_data_impl`] to open files for writing.
struct FileOpener<'a, Tr> {
    docket: &'a mut Docket,
    vfs: &'a VfsImpl,
    tr: &'a mut Tr,
    timestamp: u32,
}

impl<Tr> FileOpener<'_, Tr>
where
    Tr: Transaction,
{
    fn open_list_file(&mut self, new: bool) -> Result<VfsFile, HgError> {
        let path = self.docket.list_file_path();
        if new {
            self.add_to_garbage(path);
            self.docket.header.list_file_id = FileUid::random();
            self.docket.header.list_file_size = 0.into();
            let path = self.docket.list_file_path().expect("just set the id");
            return self.open_new(&path);
        }
        let path = path.expect("should exist if new is false");
        self.open_for_appending(&path, self.docket.header.list_file_size.get())
    }

    fn open_meta_file(&mut self, new: bool) -> Result<VfsFile, HgError> {
        let path = self.docket.meta_file_path();
        if new {
            self.add_to_garbage(path);
            self.docket.header.meta_file_id = FileUid::random();
            self.docket.header.meta_file_size = 0.into();
            let path = self.docket.meta_file_path().expect("just set the id");
            return self.open_new(&path);
        }
        let path = path.expect("should exist if new is false");
        self.open_for_appending(&path, self.docket.header.meta_file_size.get())
    }

    fn open_tree_file(&mut self, new: bool) -> Result<VfsFile, HgError> {
        let path = self.docket.tree_file_path();
        if new {
            self.add_to_garbage(path);
            self.docket.header.tree_file_id = FileUid::random();
            self.docket.header.tree_file_size = 0.into();
            let path = self.docket.tree_file_path().expect("just set the id");
            return self.open_new(&path);
        }
        let path = path.expect("should exist if new is false");
        self.open_for_appending(&path, self.docket.header.tree_file_size.get())
    }

    /// If `path` is not `None`, adds it to the docket's garbage list.
    fn add_to_garbage(&mut self, path: Option<PathBuf>) {
        if let Some(path) = path {
            self.docket.garbage_entries.push(GarbageEntry {
                ttl: INITIAL_GARBAGE_TTL,
                timestamp: self.timestamp,
                path: path.to_owned(),
            });
        }
    }

    /// Open a new file for writing.
    ///
    /// This adds the file to the transaction so that it will be removed if we
    /// later abort or rollback.
    fn open_new(&mut self, path: &Path) -> Result<VfsFile, HgError> {
        self.tr.add(path, 0);
        self.vfs.create(path, false)
    }

    /// Open a file for appending past `used_size`.
    ///
    /// Despite "appending", this doesn't open in append mode because the
    /// physical size of the file may be larger than `used_size`.
    ///
    /// Unlike [`Self::open_new`], this doesn't add the file to the transaction.
    /// If we rollback, there's no need to truncate since the docket stores
    /// `used_size`.
    fn open_for_appending(
        &mut self,
        path: &Path,
        used_size: u32,
    ) -> Result<VfsFile, HgError> {
        let mut file = self.vfs.open_write(path)?;
        file.seek(SeekFrom::Start(used_size as u64))
            .when_reading_file(normal_path(&file))?;
        Ok(file)
    }
}

/// Returns the path of a [`VfsFile`], assuming it is normal not atomic.
fn normal_path(file: &VfsFile) -> &Path {
    match file {
        VfsFile::Normal { path, .. } => path,
        VfsFile::Atomic(..) => unreachable!("unexpected atomic file"),
    }
}

/// An iterator over `(path, token)` in the file index.
pub struct PathTokenIter<'a> {
    inner: &'a FileIndex,
    index: u32,
}

impl<'a> Iterator for PathTokenIter<'a> {
    type Item = Result<(&'a HgPath, FileToken), Error>;

    fn next(&mut self) -> Option<Self::Item> {
        let len = self.inner.token_count();
        while self.index < len {
            let token = FileToken(self.index);
            self.index += 1;
            match self.inner.get_path(token) {
                Ok(None) => {}
                Ok(Some(path)) => return Some(Ok((path, token))),
                Err(err) => return Some(Err(err)),
            }
        }
        None
    }
}
