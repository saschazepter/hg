use crate::errors::{HgError, IoErrorContext, IoResultExt};
use crate::exit_codes;
use crate::fncache::FnCache;
use crate::revlog::path_encode::path_encode;
use crate::utils::files::{get_bytes_from_path, get_path_from_bytes};
use dyn_clone::DynClone;
use memmap2::{Mmap, MmapOptions};
use rand::distributions::{Alphanumeric, DistString};
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
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
        mask & 0o777
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
        let mut tmp = tempfile::NamedTempFile::new_in(&self.base)
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
    match std::fs::metadata(path) {
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

/// Writable file object that atomically updates a file
///
/// All writes will go to a temporary copy of the original file. Call
/// [`Self::close`] when you are done writing, and [`Self`] will rename
/// the temporary copy to the original name, making the changes
/// visible. If the object is destroyed without being closed, all your
/// writes are discarded.
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
            if let Ok(stat) = std::fs::metadata(&target) {
                std::fs::rename(&self.temp_path, &target)?;
                let new_stat = std::fs::metadata(&target)?;
                let ctime = new_stat.ctime();
                let is_ambiguous = ctime == stat.ctime();
                if is_ambiguous {
                    let advanced =
                        filetime::FileTime::from_unix_time(ctime + 1, 0);
                    filetime::set_file_times(target, advanced, advanced)?;
                }
            } else {
                std::fs::rename(&self.temp_path, target)?;
            }
        } else {
            std::fs::rename(&self.temp_path, target).unwrap();
        }
        self.is_open = false;
        Ok(())
    }
}

impl Drop for AtomicFile {
    fn drop(&mut self) {
        if self.is_open {
            std::fs::remove_file(self.target()).ok();
        }
    }
}

/// Abstracts over the VFS to allow for different implementations of the
/// filesystem layer (like passing one from Python).
pub trait Vfs: Sync + Send + DynClone {
    // TODO make `open` readonly and make `open_read` an `open_write`
    fn open(&self, filename: &Path) -> Result<std::fs::File, HgError>;
    fn open_read(&self, filename: &Path) -> Result<std::fs::File, HgError>;
    fn open_check_ambig(
        &self,
        filename: &Path,
    ) -> Result<std::fs::File, HgError>;
    fn create(&self, filename: &Path) -> Result<std::fs::File, HgError>;
    /// Must truncate the new file if exist
    fn create_atomic(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<AtomicFile, HgError>;
    fn file_size(&self, file: &File) -> Result<u64, HgError>;
    fn exists(&self, filename: &Path) -> bool;
    fn unlink(&self, filename: &Path) -> Result<(), HgError>;
    fn rename(
        &self,
        from: &Path,
        to: &Path,
        check_ambig: bool,
    ) -> Result<(), HgError>;
    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError>;
    fn base(&self) -> &Path;
}

/// These methods will need to be implemented once `rhg` (and other) non-Python
/// users of `hg-core` start doing more on their own, like writing to files.
impl Vfs for VfsImpl {
    fn open(&self, filename: &Path) -> Result<std::fs::File, HgError> {
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

        OpenOptions::new()
            .create(false)
            .create_new(false)
            .write(true)
            .read(true)
            .open(&path)
            .when_writing_file(&path)
    }

    fn open_read(&self, filename: &Path) -> Result<std::fs::File, HgError> {
        // TODO auditpath
        let path = self.base.join(filename);
        std::fs::File::open(&path).when_reading_file(&path)
    }

    fn open_check_ambig(
        &self,
        filename: &Path,
    ) -> Result<std::fs::File, HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }

        let path = self.base.join(filename);
        copy_in_place_if_hardlink(&path)?;

        // TODO auditpath, check ambig
        OpenOptions::new()
            .write(true)
            .read(true) // Can be used for reading to save on `open` calls
            .create(false)
            .open(&path)
            .when_reading_file(&path)
    }

    fn create(&self, filename: &Path) -> Result<std::fs::File, HgError> {
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
        // TODO checkambig (wrap File somehow)

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

        Ok(file)
    }

    fn create_atomic(
        &self,
        _filename: &Path,
        _check_ambig: bool,
    ) -> Result<AtomicFile, HgError> {
        todo!()
    }

    fn file_size(&self, file: &File) -> Result<u64, HgError> {
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
        _check_ambig: bool,
    ) -> Result<(), HgError> {
        if self.readonly {
            return Err(HgError::abort(
                "write access in a readonly vfs",
                exit_codes::ABORT,
                None,
            ));
        }
        // TODO checkambig
        let from = self.base.join(from);
        let to = self.base.join(to);
        std::fs::rename(&from, &to)
            .with_context(|| IoErrorContext::RenamingFile { from, to })
    }

    fn copy(&self, from: &Path, to: &Path) -> Result<(), HgError> {
        // TODO checkambig?
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
    fn open(&self, filename: &Path) -> Result<std::fs::File, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let encoded_path = get_path_from_bytes(&encoded);
        self.maybe_add_to_fncache(filename, encoded_path)?;
        self.inner.open(encoded_path)
    }

    fn open_read(&self, filename: &Path) -> Result<std::fs::File, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.open_read(filename)
    }

    fn open_check_ambig(
        &self,
        filename: &Path,
    ) -> Result<std::fs::File, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.open_check_ambig(filename)
    }

    fn create(&self, filename: &Path) -> Result<std::fs::File, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let encoded_path = get_path_from_bytes(&encoded);
        self.maybe_add_to_fncache(filename, encoded_path)?;
        self.inner.create(encoded_path)
    }

    fn create_atomic(
        &self,
        filename: &Path,
        check_ambig: bool,
    ) -> Result<AtomicFile, HgError> {
        let encoded = path_encode(&get_bytes_from_path(filename));
        let filename = get_path_from_bytes(&encoded);
        self.inner.create_atomic(filename, check_ambig)
    }

    fn file_size(&self, file: &File) -> Result<u64, HgError> {
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
    if metadata.nlink() > 0 {
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
