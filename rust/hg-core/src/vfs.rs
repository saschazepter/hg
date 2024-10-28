use crate::errors::{HgError, IoErrorContext, IoResultExt};
use crate::exit_codes;
use dyn_clone::DynClone;
use memmap2::{Mmap, MmapOptions};
use std::fs::File;
use std::io::{ErrorKind, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// Filesystem access abstraction for the contents of a given "base" diretory
#[derive(Clone)]
pub struct VfsImpl {
    pub(crate) base: PathBuf,
}

struct FileNotFound(std::io::Error, PathBuf);

impl VfsImpl {
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

    pub fn rename(
        &self,
        relative_from: impl AsRef<Path>,
        relative_to: impl AsRef<Path>,
    ) -> Result<(), HgError> {
        let from = self.join(relative_from);
        let to = self.join(relative_to);
        std::fs::rename(&from, &to)
            .with_context(|| IoErrorContext::RenamingFile { from, to })
    }

    pub fn remove_file(
        &self,
        relative_path: impl AsRef<Path>,
    ) -> Result<(), HgError> {
        let path = self.join(relative_path);
        std::fs::remove_file(&path)
            .with_context(|| IoErrorContext::RemovingFile(path))
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
}

/// These methods will need to be implemented once `rhg` (and other) non-Python
/// users of `hg-core` start doing more on their own, like writing to files.
impl Vfs for VfsImpl {
    fn open(&self, _filename: &Path) -> Result<std::fs::File, HgError> {
        todo!()
    }
    fn open_read(&self, filename: &Path) -> Result<std::fs::File, HgError> {
        let path = self.base.join(filename);
        std::fs::File::open(&path).when_reading_file(&path)
    }
    fn open_check_ambig(
        &self,
        _filename: &Path,
    ) -> Result<std::fs::File, HgError> {
        todo!()
    }
    fn create(&self, _filename: &Path) -> Result<std::fs::File, HgError> {
        todo!()
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
    fn exists(&self, _filename: &Path) -> bool {
        todo!()
    }
    fn unlink(&self, _filename: &Path) -> Result<(), HgError> {
        todo!()
    }
    fn rename(
        &self,
        _from: &Path,
        _to: &Path,
        _check_ambig: bool,
    ) -> Result<(), HgError> {
        todo!()
    }
    fn copy(&self, _from: &Path, _to: &Path) -> Result<(), HgError> {
        todo!()
    }
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
