use crate::errors::{HgError, HgResultExt, IoErrorContext, IoResultExt};
use crate::exit_codes;
use crate::fncache::FnCache;
use crate::revlog::path_encode::path_encode;
use crate::utils::files::{get_bytes_from_path, get_path_from_bytes};
use dyn_clone::DynClone;
use format_bytes::format_bytes;
use memmap2::{Mmap, MmapOptions};
use rand::distributions::{Alphanumeric, DistString};
use std::fs::{File, Metadata, OpenOptions};
use std::io::{ErrorKind, Read, Seek, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicUsize;
#[cfg(test)]
use std::sync::atomic::Ordering;
use std::sync::OnceLock;

/// Filesystem access abstraction for the contents of a given "base" diretory
#[derive(Clone)]
pub struct VfsImpl {
    pub(crate) base: PathBuf,
    pub readonly: bool,
    pub mode: Option<u32>,
}

struct FileNotFound(std::io::Error, PathBuf);

/// Store the umask for the whole process since it's expensive to get.
static UMASK: OnceLock<u32> = OnceLock::new();

fn get_umask() -> u32 {
    *UMASK.get_or_init(|| unsafe {
        // TODO is there any way of getting the umask without temporarily
        // setting it? Doesn't this affect all threads in this tiny window?
        let mask = libc::umask(0);
        libc::umask(mask);
        #[allow(clippy::useless_conversion)]
        (mask & 0o777).into()
    })
}

/// Return the (unix) mode with which we will create/fix files
fn get_mode(base: impl AsRef<Path>) -> Option<u32> {
    match base.as_ref().metadata() {
        Ok(meta) => {
            // files in .hg/ will be created using this mode
            let mode = meta.mode();
            // avoid some useless chmods
            if (0o777 & !get_umask()) == (0o777 & mode) {
                None
            } else {
                Some(mode)
            }
        }
        Err(_) => None,
    }
}

impl VfsImpl {
    pub fn new(base: PathBuf, readonly: bool) -> Self {
        let mode = get_mode(&base);
        Self {
            base,
            readonly,
            mode,
        }
    }

    // XXX these methods are probably redundant with VFS trait?

    pub fn join(&self, relative_path: impl AsRef<Path>) -> PathBuf {
        self.base.join(relative_path)
    }

    pub fn symlink_metadata(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<std::fs::Metadata, HgError> {
        let path = self.join(relative_path);
        std::fs::symlink_metadata(&path).when_reading_file(&path)
    }

    pub fn read_link(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<PathBuf, HgError> {
        let path = self.join(relative_path);
        std::fs::read_link(&path).when_reading_file(&path)
    }

    pub fn read(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<Vec<u8>, HgError> {
        let path = self.join(relative_path);
        std::fs::read(&path).when_reading_file(&path)
    }

    /// Returns `Ok(None)` if the file does not exist.
    pub fn try_read(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<Option<Vec<u8>>, HgError> {
        match self.read(relative_path) {
            Err(e) => match &e {
                HgError::IoError { error, .. } => match error.kind() {
                    ErrorKind::NotFound => Ok(None),
                    _ => Err(e),
                },
                _ => Err(e),
            },
            Ok(v) => Ok(Some(v)),
        }
    }

    fn mmap_open_gen(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<Result<Mmap, FileNotFound>, HgError> {
        let path = self.join(relative_path);
        let file = match std::fs::File::open(&path) {
            Err(err) => {
                if let ErrorKind::NotFound = err.kind() {
                    return Ok(Err(FileNotFound(err, path)));
                };
                return (Err(err)).when_reading_file(&path);
            }
            Ok(file) => file,
        };
        // Safety is "enforced" by locks and assuming other processes are
        // well-behaved. If any misbehaving or malicious process does touch
        // the index, it could lead to corruption. This is inherent
        // to file-based `mmap`, though some platforms have some ways of
        // mitigating.
        // TODO linux: set the immutable flag with `chattr(1)`?
        let mmap = unsafe { MmapOptions::new().map(&file) }
            .when_reading_file(&path)?;
        Ok(Ok(mmap))
    }

    pub fn mmap_open_opt(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<Option<Mmap>, HgError> {
        self.mmap_open_gen(relative_path).map(|res| res.ok())
    }

    pub fn mmap_open(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<Mmap, HgError> {
        match self.mmap_open_gen(relative_path)? {
            Err(FileNotFound(err, path)) => Err(err).when_reading_file(&path),
            Ok(res) => Ok(res),
        }
    }

    #[cfg(unix)]
    pub fn create_symlink(
        &self,
        relative_link_path: impl AsRef<Path>,
        target_path: impl AsRef<Path>,
    ) -> Result<(), HgError> {
        let link_path = self.join(relative_link_path);
        std::os::unix::fs::symlink(target_path, &link_path)
            .when_writing_file(&link_path)
    }

    /// Write `contents` into a temporary file, then rename to `relative_path`.
    /// This makes writing to a file "atomic": a reader opening that path will
    /// see either the previous contents of the file or the complete new
    /// content, never a partial write.
    pub fn atomic_write(
        &self,
        relative_path: impl AsRef<Path>,
        contents: &[u8],
    ) -> Result<(), HgError> {
        let mut tmp = tempfile::Builder::new()
            .permissions(std::fs::Permissions::from_mode(0o666))
            .tempfile_in(&self.base)
            .when_writing_file(&self.base)?;
        tmp.write_all(contents)
            .and_then(|()| tmp.flush())
            .when_writing_file(tmp.path())?;
        let path = self.join(relative_path);
        tmp.persist(&path)
            .map_err(|e| e.error)
            .when_writing_file(&path)?;
        Ok(())
    }
}

fn fs_metadata(
    path: impl AsRef<Path>,
) -> Result<Option<std::fs::Metadata>, HgError> {
    let path = path.as_ref();
    match path.metadata() {
        Ok(meta) => Ok(Some(meta)),
        Err(error) => match error.kind() {
            // TODO: when we require a Rust version where `NotADirectory` is
            // stable, invert this logic and return None for it and `NotFound`
            // and propagate any other error.
            ErrorKind::PermissionDenied => Err(error).with_context(|| {
                IoErrorContext::ReadingMetadata(path.to_owned())
            }),
            _ => Ok(None),
        },
    }
}

/// Abstraction over the files handled by a [`Vfs`].
#[derive(Debug)]
pub enum VfsFile {
    Atomic(AtomicFile),

    Normal {
        file: File,
        path: PathBuf,
        /// If `Some`, check (and maybe fix) this file's timestamp ambiguity.
        /// See [`is_filetime_ambiguous`].
        check_ambig: Option<Metadata>,
    },
}

impl VfsFile {
    pub fn normal(file: File, path: PathBuf) -> Self {
        Self::Normal {
            file,
            check_ambig: None,
            path,
        }
    }
    pub fn normal_check_ambig(
        file: File,
        path: PathBuf,
    ) -> Result<Self, HgError> {
        Ok(Self::Normal {
            file,
            check_ambig: Some(path.metadata().when_reading_file(&path)?),
            path,
        })
    }
    pub fn try_clone(&self) -> Result<VfsFile, HgError> {
        Ok(match self {
            VfsFile::Atomic(AtomicFile {
                fp,
                temp_path,
                check_ambig,
                target_name,
                is_open,
            }) => Self::Atomic(AtomicFile {
                fp: fp.try_clone().when_reading_file(temp_path)?,
                temp_path: temp_path.clone(),
                check_ambig: *check_ambig,
                target_name: target_name.clone(),
                is_open: *is_open,
            }),
            VfsFile::Normal {
                file,
                check_ambig,
                path,
            } => Self::Normal {
                file: file.try_clone().when_reading_file(path)?,
                check_ambig: check_ambig.clone(),
                path: path.to_owned(),
            },
        })
    }
    pub fn set_len(&self, len: u64) -> Result<(), std::io::Error> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.set_len(len),
            VfsFile::Normal { file, .. } => file.set_len(len),
        }
    }

    pub fn metadata(&self) -> Result<std::fs::Metadata, std::io::Error> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.metadata(),
            VfsFile::Normal { file, .. } => file.metadata(),
        }
    }
}

impl AsRawFd for VfsFile {
    fn as_raw_fd(&self) -> std::os::unix::prelude::RawFd {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.as_raw_fd(),
            VfsFile::Normal { file, .. } => file.as_raw_fd(),
        }
    }
}

impl Seek for VfsFile {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.seek(pos),
            VfsFile::Normal { file, .. } => file.seek(pos),
        }
    }
}

impl Read for VfsFile {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.read(buf),
            VfsFile::Normal { file, .. } => file.read(buf),
        }
    }
}

impl Write for VfsFile {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.write(buf),
            VfsFile::Normal { file, .. } => file.write(buf),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            VfsFile::Atomic(atomic_file) => atomic_file.fp.flush(),
            VfsFile::Normal { file, .. } => file.flush(),
        }
    }
}

impl Drop for VfsFile {
    fn drop(&mut self) {
        if let VfsFile::Normal {
            path,
            check_ambig: Some(old),
            ..
        } = self
        {
            avoid_timestamp_ambiguity(path, old)
        }
    }
}

/// Records the number of times we've fixed a timestamp ambiguity, only
/// applicable for tests.
#[cfg(test)]
static TIMESTAMP_FIXES_CALLS: AtomicUsize = AtomicUsize::new(0);

fn avoid_timestamp_ambiguity(path: &Path, old: &Metadata) {
    if let Ok(new) = path.metadata() {
        let is_ambiguous = is_filetime_ambiguous(&new, old);
        if is_ambiguous {
            let advanced =
                filetime::FileTime::from_unix_time(old.mtime() + 1, 0);
            if filetime::set_file_times(path, advanced, advanced).is_ok() {
                #[cfg(test)]
                {
                    TIMESTAMP_FIXES_CALLS.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
    }
}

/// Examine whether new stat is ambiguous against old one
///
/// `S[N]` below means stat of a file at `N`-th change:
///
/// - `S[n-1].ctime  < S[n].ctime`: can detect change of a file
/// - `S[n-1].ctime == S[n].ctime`
///   - `S[n-1].ctime  < S[n].mtime`: means natural advancing (*1)
///   - `S[n-1].ctime == S[n].mtime`: is ambiguous (*2)
///   - `S[n-1].ctime  > S[n].mtime`: never occurs naturally (don't care)
/// - `S[n-1].ctime  > S[n].ctime`: never occurs naturally (don't care)
///
/// Case (*2) above means that a file was changed twice or more at
/// same time in sec (= `S[n-1].ctime`), and comparison of timestamp
/// is ambiguous.
///
/// Base idea to avoid such ambiguity is "advance mtime 1 sec, if
/// timestamp is ambiguous".
///
/// But advancing mtime only in case (*2) doesn't work as
/// expected, because naturally advanced `S[n].mtime` in case (*1)
/// might be equal to manually advanced `S[n-1 or earlier].mtime`.
///
/// Therefore, all `S[n-1].ctime == S[n].ctime` cases should be
/// treated as ambiguous regardless of mtime, to avoid overlooking
/// by confliction between such mtime.
///
/// Advancing mtime `if isambig(new, old)` ensures `S[n-1].mtime !=
/// S[n].mtime`, even if size of a file isn't changed.
pub fn is_filetime_ambiguous(new: &Metadata, old: &Metadata) -> bool {
    new.ctime() == old.ctime()
}

/// Writable file object that atomically updates a file
///
/// All writes will go to a temporary copy of the original file. Call
/// [`Self::close`] when you are done writing, and [`Self`] will rename
/// the temporary copy to the original name, making the changes
/// visible. If the object is destroyed without being closed, all your
/// writes are discarded.
#[derive(Debug)]
pub struct AtomicFile {
    /// The temporary file to write to
    fp: std::fs::File,
    /// Path of the temp file
    temp_path: PathBuf,
    /// Used when stat'ing the file, is useful only if the target file is
    /// guarded by any lock (e.g. repo.lock or repo.wlock).
    check_ambig: bool,
    /// Path of the target file
    target_name: PathBuf,
    /// Whether the file is open or not
    is_open: bool,
}

impl AtomicFile {
    pub fn new(
        target_path: impl AsRef<Path>,
        empty: bool,
        check_ambig: bool,
    ) -> Result<Self, HgError> {
        let target_path = target_path.as_ref().to_owned();

        let random_id =
            Alphanumeric.sample_string(&mut rand::thread_rng(), 12);
        let filename =
            target_path.file_name().expect("target has no filename");
        let filename = get_bytes_from_path(filename);
        let temp_filename =
            format_bytes!(b".{}-{}~", filename, random_id.as_bytes());
        let temp_path =
            target_path.with_file_name(get_path_from_bytes(&temp_filename));

        if !empty {
            std::fs::copy(&target_path, &temp_path)
                .with_context(|| IoErrorContext::CopyingFile {
                    from: target_path.to_owned(),
                    to: temp_path.to_owned(),
                })
                // If it doesn't exist, create it on open
                .io_not_found_as_none()?;
        }
        let fp = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(empty)
            .open(&temp_path)
            .when_writing_file(&temp_path)?;

        Ok(Self {
            fp,
            temp_path,
            check_ambig,
            target_name: target_path,
            is_open: true,
        })
    }

    pub fn from_file(
        fp: std::fs::File,
        check_ambig: bool,
        temp_name: PathBuf,
        target_name: PathBuf,
    ) -> Self {
        Self {
            fp,
            check_ambig,
            temp_path: temp_name,
            target_name,
            is_open: true,
        }
    }

    /// Write `buf` to the temporary file
    pub fn write_all(&mut self, buf: &[u8]) -> Result<(), std::io::Error> {
        self.fp.write_all(buf)
    }

    fn target(&self) -> PathBuf {
        self.temp_path
            .parent()
            .expect("should not be at the filesystem root")
            .join(&self.target_name)
    }

    /// Close the temporary file and rename to the target
    pub fn close(mut self) -> Result<(), std::io::Error> {
        self.fp.flush()?;
        let target = self.target();
        if self.check_ambig {
            if let Ok(stat) = target.metadata() {
                std::fs::rename(&self.temp_path, &target)?;
                avoid_timestamp_ambiguity(&target, &stat);
            } else {
                std::fs::rename(&self.temp_path, target)?;
            }
        } else {
            std::fs::rename(&self.temp_path, target)?;
        }
        self.is_open = false;
        Ok(())
    }
}

impl Seek for AtomicFile {
    fn seek(&mut self, pos: std::io::SeekFrom) -> std::io::Result<u64> {
        self.fp.seek(pos)
    }
}

impl Drop for AtomicFile {
    fn drop(&mut self) {
        if self.is_open {
            std::fs::remove_file(&self.temp_path).ok();
        }
    }
}

/// Abstracts over the VFS to allow for different implementations of the
/// filesystem layer (like passing one from Python).
pub trait Vfs: Sync + Send + DynClone {
    /// Open a [`VfsFile::Normal`] for reading the file at `filename`,
    /// relative to this VFS's root.
    fn open(&self, filename: &Path) -> Result<VfsFile, HgError>;
    /// Open a [`VfsFile::Normal`] for writing and reading the file at
    /// `filename`, relative to this VFS's root.
    fn open_write(&self, filename: &Path) -> Result<VfsFile, HgError>;
    /// Open a [`VfsFile::Normal`] for reading and writing the file at
    /// `filename`, relative to this VFS's root. This file will be checked
    /// for an ambiguous mtime on [`drop`]. See [`is_filetime_ambiguous`].
    fn open_check_ambig(&self, filename: &Path) -> Result<VfsFile, HgError>;
    /// Create a [`VfsFile::Normal`] for reading and writing the file at
    /// `filename`, relative to this VFS's root. If the file already exists,
    /// it will be truncated to 0 bytes.
    fn create(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError>;
    /// Create a [`VfsFile::Atomic`] for reading and writing the file at
    /// `filename`, relative to this VFS's root. If the file already exists,
    /// it will be truncated to 0 bytes.
    fn create_atomic(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError>;
    /// Return the total file size in bytes of the open `file`. Errors are
    /// usual IO errors (invalid file handle, permissions, etc.)
    fn file_size(&self, file: &VfsFile) -> Result<u64, HgError>;
    /// Return `true` if `filename` exists relative to this VFS's root. Errors
    /// will coerce to `false`, to this also returns `false` if there are
    /// IO problems. This is fine because any operation that actually tries
    /// to do anything with this path will get the same error.
    fn exists(&self, filename: &Path) -> bool;
    /// Remove the file at `filename` relative to this VFS's root. Errors
    /// are the usual IO errors (lacking permission, file does not exist, etc.)
    fn unlink(&self, filename: &Path) -> Result<(), HgError>;
    /// Rename the file `from` to `to`, both relative to this VFS's root.
    /// Errors are the usual IO errors (lacking permission, file does not
    /// exist, etc.). If `check_ambig` is `true`, the VFS will check for an
    /// ambiguous mtime on rename. See [`is_filetime_ambiguous`].
    fn rename(
        &self,
        from: &Path,
        to: &Path,
        check_ambig: bool,
    ) -> Result<(), HgError>;
    /// Rename the file `from` to `to`, both relative to this VFS's root.
    /// Errors are the usual IO errors (lacking permission, file does not
    /// exist, etc.). If `check_ambig` is passed, the VFS will check for an
    /// ambiguous mtime on rename. See [`is_filetime_ambiguous`].
    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError>;
    /// Returns the absolute root path of this VFS, relative to which all
    /// operations are done.
    fn base(&self) -> &Path;
}

/// These methods will need to be implemented once `rhg` (and other) non-Python
/// users of `hg-core` start doing more on their own, like writing to files.
impl Vfs for VfsImpl {
    fn open(&self, filename: &Path) -> Result<VfsFile, HgError> {
        // TODO auditpath
        let path = self.base.join(filename);
        Ok(VfsFile::normal(
            std::fs::File::open(&path).when_reading_file(&path)?,
            filename.to_owned(),
        ))
    }

    fn open_write(&self, filename: &Path) -> Result<VfsFile, HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }
        // TODO auditpath
        let path = self.base.join(filename);
        copy_in_place_if_hardlink(&path)?;

        Ok(VfsFile::normal(
            OpenOptions::new()
                .create(false)
                .create_new(false)
                .write(true)
                .read(true)
                .open(&path)
                .when_writing_file(&path)?,
            path.to_owned(),
        ))
    }

    fn open_check_ambig(&self, filename: &Path) -> Result<VfsFile, HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }

        let path = self.base.join(filename);
        copy_in_place_if_hardlink(&path)?;

        // TODO auditpath
        VfsFile::normal_check_ambig(
            OpenOptions::new()
                .write(true)
                .read(true) // Can be used for reading to save on `open` calls
                .create(false)
                .open(&path)
                .when_reading_file(&path)?,
            path.to_owned(),
        )
    }

    fn create(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }
        // TODO auditpath
        let path = self.base.join(filename);
        let parent = path.parent().expect("file at root");
        std::fs::create_dir_all(parent).when_writing_file(parent)?;

        let file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .read(true)
            .open(&path)
            .when_writing_file(&path)?;

        if let Some(mode) = self.mode {
            // Creating the file with the right permission (with `.mode()`)
            // may not work since umask takes effect for file creation.
            // So we need to fix the permission after creating the file.
            fix_directory_permissions(&self.base, &path, mode)?;
            let perm = std::fs::Permissions::from_mode(mode & 0o666);
            std::fs::set_permissions(&path, perm).when_writing_file(&path)?;
        }

        Ok(VfsFile::Normal {
            file,
            check_ambig: if check_ambig {
                Some(path.metadata().when_reading_file(&path)?)
            } else {
                None
            },
            path: path.to_owned(),
        })
    }

    fn create_atomic(
        &self,
        _filename: &Path,
        _check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        todo!()
    }

    fn file_size(&self, file: &VfsFile) -> Result<u64, HgError> {
        Ok(file
            .metadata()
            .map_err(|e| {
                HgError::abort(
                    format!("Could not get file metadata: {}", e),
                    exit_codes::ABORT,
                    None,
                )
            })?
            .size())
    }

    fn exists(&self, filename: &Path) -> bool {
        self.base.join(filename).exists()
    }

    fn unlink(&self, filename: &Path) -> Result<(), HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }
        let path = self.base.join(filename);
        std::fs::remove_file(&path)
            .with_context(|| IoErrorContext::RemovingFile(path))
    }

    fn rename(
        &self,
        from: &Path,
        to: &Path,
        check_ambig: bool,
    ) -> Result<(), HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }
        let old_stat = if check_ambig {
            Some(
                from.metadata()
                    .when_reading_file(from)
                    .io_not_found_as_none()?,
            )
        } else {
            None
        };
        let from = self.base.join(from);
        let to = self.base.join(to);
        std::fs::rename(&from, &to).with_context(|| {
            IoErrorContext::RenamingFile {
                from,
                to: to.to_owned(),
            }
        })?;
        if let Some(Some(old)) = old_stat {
            avoid_timestamp_ambiguity(&to, &old);
        }
        Ok(())
    }

    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError> {
        let from = self.base.join(from);
        let to = self.base.join(to);
        std::fs::copy(&from, &to)
            .with_context(|| IoErrorContext::CopyingFile { from, to })
            .map(|_| ())
    }

    fn base(&self) -> &Path {
        &self.base
    }
}

fn fix_directory_permissions(
    base: &Path,
    path: &Path,
    mode: u32,
) -> Result<(), HgError> {
    let mut ancestors = path.ancestors();
    ancestors.next(); // yields the path itself

    for ancestor in ancestors {
        if ancestor == base {
            break;
        }
        let perm = std::fs::Permissions::from_mode(mode);
        std::fs::set_permissions(ancestor, perm)
            .when_writing_file(ancestor)?;
    }
    Ok(())
}

/// A VFS that understands the `fncache` store layout (file encoding), and
/// adds new entries to the `fncache`.
/// TODO Only works when using from Python for now.
pub struct FnCacheVfs {
    inner: VfsImpl,
    fncache: Box<dyn FnCache>,
}

impl Clone for FnCacheVfs {
    fn clone(&self) -> Self {
        Self {
            inner: self.inner.clone(),
            fncache: dyn_clone::clone_box(&*self.fncache),
        }
    }
}

impl FnCacheVfs {
    pub fn new(
        base: PathBuf,
        readonly: bool,
        fncache: Box<dyn FnCache>,
    ) -> Self {
        let inner = VfsImpl::new(base, readonly);
        Self { inner, fncache }
    }

    fn maybe_add_to_fncache(
        &self,
        filename: &Path,
        encoded_path: &Path,
    ) -> Result<(), HgError> {
        let relevant_file = (filename.starts_with("data/")
            || filename.starts_with("meta/"))
            && is_revlog_file(filename);
        if relevant_file {
            let not_load = !self.fncache.is_loaded()
                && (self.exists(filename)
                    && self
                        .inner
                        .join(encoded_path)
                        .metadata()
                        .when_reading_file(encoded_path)?
                        .size()
                        != 0);
            if !not_load {
                self.fncache.add(filename);
            }
        };
        Ok(())
    }
}

impl Vfs for FnCacheVfs {
    fn open(&self, filename: &Path) -> Result<VfsFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.open(filename)
    }

    fn open_write(&self, filename: &Path) -> Result<VfsFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let encoded_path = get_path_from_bytes(&encoded);
        self.maybe_add_to_fncache(filename, encoded_path)?;
        self.inner.open_write(encoded_path)
    }

    fn open_check_ambig(&self, filename: &Path) -> Result<VfsFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.open_check_ambig(filename)
    }

    fn create(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let encoded_path = get_path_from_bytes(&encoded);
        self.maybe_add_to_fncache(filename, encoded_path)?;
        self.inner.create(encoded_path, check_ambig)
    }

    fn create_atomic(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<VfsFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.create_atomic(filename, check_ambig)
    }

    fn file_size(&self, file: &VfsFile) -> Result<u64, HgError> {
        self.inner.file_size(file)
    }

    fn exists(&self, filename: &Path) -> bool {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.exists(filename)
    }

    fn unlink(&self, filename: &Path) -> Result<(), HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.unlink(filename)
    }

    fn rename(
        &self,
        from: &Path,
        to: &Path,
        check_ambig: bool,
    ) -> Result<(), HgError> {
        let encoded = path_encode(&get_bytes_from_path(from));
        let from = get_path_from_bytes(&encoded);
        let encoded = path_encode(&get_bytes_from_path(to));
        let to = get_path_from_bytes(&encoded);
        self.inner.rename(from, to, check_ambig)
    }

    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError> {
        let encoded = path_encode(&get_bytes_from_path(from));
        let from = get_path_from_bytes(&encoded);
        let encoded = path_encode(&get_bytes_from_path(to));
        let to = get_path_from_bytes(&encoded);
        self.inner.copy(from, to)
    }
    fn base(&self) -> &Path {
        self.inner.base()
    }
}

/// Detects whether `path` is a hardlink and does a tmp copy + rename erase
/// to turn it into its own file. Revlogs are usually hardlinked when doing
/// a local clone, and we don't want to modify the original repo.
fn copy_in_place_if_hardlink(path: &Path) -> Result<(), HgError> {
    let metadata = path.metadata().when_writing_file(path)?;
    if metadata.nlink() > 1 {
        // If it's hardlinked, copy it and rename it back before changing it.
        let tmpdir = path.parent().expect("file at root");
        let name = Alphanumeric.sample_string(&mut rand::thread_rng(), 16);
        let tmpfile = tmpdir.join(name);
        std::fs::create_dir_all(tmpfile.parent().expect("file at root"))
            .with_context(|| IoErrorContext::CopyingFile {
                from: path.to_owned(),
                to: tmpfile.to_owned(),
            })?;
        std::fs::copy(path, &tmpfile).with_context(|| {
            IoErrorContext::CopyingFile {
                from: path.to_owned(),
                to: tmpfile.to_owned(),
            }
        })?;
        std::fs::rename(&tmpfile, path).with_context(|| {
            IoErrorContext::RenamingFile {
                from: tmpfile,
                to: path.to_owned(),
            }
        })?;
    }
    Ok(())
}

pub fn is_revlog_file(path: impl AsRef<Path>) -> bool {
    path.as_ref()
        .extension()
        .map(|ext| {
            ["i", "idx", "d", "dat", "n", "nd", "sda"]
                .contains(&ext.to_string_lossy().as_ref())
        })
        .unwrap_or(false)
}

pub(crate) fn is_dir(path: impl AsRef<Path>) -> Result<bool, HgError> {
    Ok(fs_metadata(path)?.map_or(false, |meta| meta.is_dir()))
}

pub(crate) fn is_file(path: impl AsRef<Path>) -> Result<bool, HgError> {
    Ok(fs_metadata(path)?.map_or(false, |meta| meta.is_file()))
}

/// Returns whether the given `path` is on a network file system.
/// Taken from `cargo`'s codebase.
#[cfg(target_os = "linux")]
pub(crate) fn is_on_nfs_mount(path: impl AsRef<Path>) -> bool {
    use std::ffi::CString;
    use std::mem;
    use std::os::unix::prelude::*;

    let path = match CString::new(path.as_ref().as_os_str().as_bytes()) {
        Ok(path) => path,
        Err(_) => return false,
    };

    unsafe {
        let mut buf: libc::statfs = mem::zeroed();
        let r = libc::statfs(path.as_ptr(), &mut buf);

        r == 0 && buf.f_type as u32 == libc::NFS_SUPER_MAGIC as u32
    }
}

/// Similar to what Cargo does; although detecting NFS (or non-local
/// file systems) _should_ be possible on other operating systems,
/// we'll just assume that mmap() works there, for now; after all,
/// _some_ functionality is better than a compile error, i.e. none at
/// all
#[cfg(not(target_os = "linux"))]
pub(crate) fn is_on_nfs_mount(_path: impl AsRef<Path>) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_atomic_file() {
        let dir = tempfile::tempdir().unwrap().into_path();
        let target_path = dir.join("sometargetname");

        for empty in [true, false] {
            let file = AtomicFile::new(&target_path, empty, false).unwrap();
            assert!(file.is_open);
            let filename =
                file.temp_path.file_name().unwrap().to_str().unwrap();
            // Make sure we have a coherent temp name
            assert_eq!(filename.len(), 29, "{}", filename);
            assert!(filename.contains("sometargetname"));

            // Make sure the temp file is created in the same folder
            assert_eq!(target_path.parent(), file.temp_path.parent());
        }

        assert!(!target_path.exists());
        std::fs::write(&target_path, "version 1").unwrap();
        let mut file = AtomicFile::new(&target_path, false, false).unwrap();
        file.write_all(b"version 2!").unwrap();
        assert_eq!(
            std::fs::read(&target_path).unwrap(),
            b"version 1".to_vec()
        );
        let temp_path = file.temp_path.to_owned();
        // test that dropping the file should discard the temp file and not
        // affect the target path.
        drop(file);
        assert_eq!(
            std::fs::read(&target_path).unwrap(),
            b"version 1".to_vec()
        );
        assert!(!temp_path.exists());

        let mut file = AtomicFile::new(&target_path, false, false).unwrap();
        file.write_all(b"version 2!").unwrap();
        assert_eq!(
            std::fs::read(&target_path).unwrap(),
            b"version 1".to_vec()
        );
        file.close().unwrap();
        assert_eq!(
            std::fs::read(&target_path).unwrap(),
            b"version 2!".to_vec(),
            "{}",
            std::fs::read_to_string(&target_path).unwrap()
        );
        assert!(target_path.exists());
        assert!(!temp_path.exists());
    }

    #[test]
    fn test_vfs_file_check_ambig() {
        let dir = tempfile::tempdir().unwrap().into_path();
        let file_path = dir.join("file");

        fn vfs_file_write(file_path: &Path, check_ambig: bool) {
            let file = std::fs::OpenOptions::new()
                .write(true)
                .open(file_path)
                .unwrap();
            let old_stat = if check_ambig {
                Some(file.metadata().unwrap())
            } else {
                None
            };

            let mut vfs_file = VfsFile::Normal {
                file,
                path: file_path.to_owned(),
                check_ambig: old_stat,
            };
            vfs_file.write_all(b"contents").unwrap();
        }

        std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(false)
            .open(&file_path)
            .unwrap();

        let number_of_writes = 3;

        // Try multiple times, because reproduction of an ambiguity depends
        // on "filesystem time"
        for _ in 0..5 {
            TIMESTAMP_FIXES_CALLS.store(0, Ordering::Relaxed);
            vfs_file_write(&file_path, false);
            let old_stat = file_path.metadata().unwrap();
            if old_stat.ctime() != old_stat.mtime() {
                // subsequent changing never causes ambiguity
                continue;
            }

            // Repeat atomic write with `check_ambig == true`, to examine
            // whether the mtime is advanced multiple times as expected
            for _ in 0..number_of_writes {
                vfs_file_write(&file_path, true);
            }
            let new_stat = file_path.metadata().unwrap();
            if !is_filetime_ambiguous(&new_stat, &old_stat) {
                // timestamp ambiguity was naturally avoided while repetition
                continue;
            }

            assert_eq!(
                TIMESTAMP_FIXES_CALLS.load(Ordering::Relaxed),
                number_of_writes
            );
            assert_eq!(
                old_stat.mtime() + number_of_writes as i64,
                file_path.metadata().unwrap().mtime()
            );
            break;
        }
        // If we've arrived here without breaking, we might not have
        // tested anything because the platform is too slow. This test will
        // still work on fast platforms.
    }
}
