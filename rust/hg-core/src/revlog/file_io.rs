//! Helpers for revlog file reading and writing.

use std::cell::Ref;
use std::cell::RefCell;
use std::io::Read;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;
use std::os::unix::fs::FileExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use crate::errors::HgError;
use crate::errors::IoResultExt;
use crate::vfs::Vfs;
use crate::vfs::VfsFile;

/// Wraps accessing arbitrary chunks of data within a file and reusing handles.
/// This is currently useful for accessing a revlog's data file, only reading
/// the ranges that are currently relevant, like a sort of basic and manual
/// file-based mmap.
///
/// XXX should this just be replaced with `mmap` + `madvise` ranges?
/// The upcoming `UncompressedChunkCache` will make up for most of the slowness
/// of re-reading the same chunks, so this might not be as useful. Aside from
/// the major benefit of having less code to take care of, using `mmap` will
/// allow multiple processes to share the same pages, especially for the
/// changelog and manifest, which would make a difference in server contexts.
pub struct RandomAccessFile {
    /// The current store VFS to pass it to [`FileHandle`]
    vfs: Box<dyn Vfs>,
    /// Filename of the open file, relative to the vfs root
    pub filename: PathBuf,
    /// The current read-only handle on the file, if any.
    /// Specific to the current thread, since we don't want seeks to overlap
    pub reading_handle: thread_local::ThreadLocal<RefCell<Option<FileHandle>>>,
    /// The current read-write handle on the file, if any.
    /// Specific to the current thread, since we don't want seeks to overlap,
    /// and we can re-use the write handle for reading in certain contexts.
    /// Logically, two concurrent writes are impossible because they are only
    /// accessible through `&mut self` methods, which take a lock.
    pub writing_handle: thread_local::ThreadLocal<RefCell<Option<FileHandle>>>,
}

impl RandomAccessFile {
    /// Wrap a file for random access
    pub fn new(vfs: Box<dyn Vfs>, filename: PathBuf) -> Self {
        assert!(filename.is_relative());
        Self {
            vfs,
            filename,
            reading_handle: thread_local::ThreadLocal::new(),
            writing_handle: thread_local::ThreadLocal::new(),
        }
    }

    /// Read a chunk of bytes from the file.
    pub fn read_chunk(
        &self,
        offset: usize,
        length: usize,
    ) -> Result<Vec<u8>, HgError> {
        let handle = self.get_read_handle()?;
        handle.read_exact_at(length, offset).when_reading_file(&self.filename)
    }

    /// `pub` only for hg-pyo3
    #[doc(hidden)]
    pub fn get_read_handle(&self) -> Result<Ref<FileHandle>, HgError> {
        let write_handle = self.writing_handle.get_or_default().borrow();
        if let Ok(handle) = Ref::filter_map(write_handle, Option::as_ref) {
            // Use a file handle being actively used for writes, if available.
            // There is some danger to doing this because reads will seek the
            // file.
            // However, [`Revlog::write_entry`] performs a `SeekFrom::End(0)`
            // before all writes, so we should be safe.
            return Ok(handle);
        }
        let read_handle = self.reading_handle.get_or_default().borrow();
        if let Ok(handle) = Ref::filter_map(read_handle, Option::as_ref) {
            // Use a file handle being actively used for writes, if available.
            // There is some danger to doing this because reads will seek the
            // file.
            // However, [`Revlog::write_entry`] performs a `SeekFrom::End(0)`
            // before all writes, so we should be safe.
            return Ok(handle);
        }
        // early returns done to work around borrowck being overzealous
        // See https://github.com/rust-lang/rust/issues/103108
        let new_handle = FileHandle::new(
            dyn_clone::clone_box(&*self.vfs),
            &self.filename,
            false,
            false,
        )?;
        let read_handle = self.reading_handle.get_or_default();
        *read_handle.borrow_mut() = Some(new_handle);
        Ok(Ref::map(read_handle.borrow(), |h| h.as_ref().expect("just set")))
    }

    /// `pub` only for hg-pyo3
    #[doc(hidden)]
    pub fn exit_reading_context(&self) {
        self.reading_handle.get().map(|h| h.take());
    }

    // Returns whether this file currently open
    pub fn is_open(&self) -> bool {
        self.reading_handle.get_or_default().borrow().is_some()
            || self.writing_handle.get_or_default().borrow().is_some()
    }
}

/// A buffer that holds new changelog index data that needs to be written
/// after the manifest and filelogs so that the repo is updated atomically to
/// external processes.
#[derive(Clone, Debug, Default)]
pub struct DelayedBuffer {
    // The actual in-memory bytes storing the delayed writes
    pub(super) buffer: Vec<u8>,
    /// The current offset into the virtual file composed of file + buffer
    offset: u64,
    /// The size of the file at the time of opening
    file_size: u64,
}

impl DelayedBuffer {
    /// Returns the length of the full data (on-disk + buffer length).
    pub fn len(&self) -> u64 {
        self.buffer.len() as u64 + self.file_size
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Holds an open [`VfsFile`] and the related data. This can be used for
/// reading and writing. Writes can be delayed to a buffer before touching
/// the disk, if relevant (in the changelog case), but reads are transparent.
pub struct FileHandle {
    /// The actual open file
    pub file: VfsFile,
    /// The VFS with which the file was opened
    vfs: Box<dyn Vfs>,
    /// Filename of the open file, relative to the repo root
    filename: PathBuf,
    /// Buffer of delayed entry writes to the changelog index. This points
    /// back to the buffer inside the revlog this handle refers to.
    delayed_buffer: Option<Arc<Mutex<DelayedBuffer>>>,
}

impl std::fmt::Debug for FileHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FileHandle")
            .field("filename", &self.filename)
            .field("delayed_buffer", &self.delayed_buffer)
            .field("file", &self.file)
            .finish()
    }
}

impl Clone for FileHandle {
    fn clone(&self) -> Self {
        Self {
            vfs: dyn_clone::clone_box(&*self.vfs),
            filename: self.filename.clone(),
            delayed_buffer: self.delayed_buffer.clone(),
            // This can only fail if the OS doesn't have the file handle
            // anymore, so we're not going to do anything useful anyway.
            file: self.file.try_clone().expect("couldn't clone file handle"),
        }
    }
}

impl FileHandle {
    /// Get a (read or write) file handle to `filename`. Only creates the file
    /// if `create` is `true`.
    pub fn new(
        vfs: Box<dyn Vfs>,
        filename: impl AsRef<Path>,
        create: bool,
        write: bool,
    ) -> Result<Self, HgError> {
        let file = if create {
            vfs.create(filename.as_ref(), false)?
        } else if write {
            vfs.open_write(filename.as_ref())?
        } else {
            vfs.open(filename.as_ref())?
        };
        Ok(Self {
            vfs,
            filename: filename.as_ref().to_owned(),
            delayed_buffer: None,
            file,
        })
    }

    /// Get a file handle to `filename`, but writes go to a [`DelayedBuffer`].
    pub fn new_delayed(
        vfs: Box<dyn Vfs>,
        filename: impl AsRef<Path>,
        create: bool,
        delayed_buffer: Arc<Mutex<DelayedBuffer>>,
    ) -> Result<Self, HgError> {
        let mut file = if create {
            vfs.create(filename.as_ref(), false)?
        } else {
            vfs.open_write(filename.as_ref())?
        };
        let size = vfs.file_size(&file)?;
        let offset =
            file.stream_position().when_reading_file(filename.as_ref())?;

        {
            let mut buf = delayed_buffer.lock().unwrap();
            buf.file_size = size;
            buf.offset = offset;
        }

        Ok(Self {
            vfs,
            filename: filename.as_ref().to_owned(),
            delayed_buffer: Some(delayed_buffer),
            file,
        })
    }

    /// Wrap an existing [`VfsFile`]
    pub fn from_file(
        file: VfsFile,
        vfs: Box<dyn Vfs>,
        filename: impl AsRef<Path>,
    ) -> Self {
        Self {
            vfs,
            filename: filename.as_ref().to_owned(),
            delayed_buffer: None,
            file,
        }
    }

    /// Wrap an existing [`VfsFile`], but writes go to a [`DelayedBuffer`].
    pub fn from_file_delayed(
        mut file: VfsFile,
        vfs: Box<dyn Vfs>,
        filename: impl AsRef<Path>,
        delayed_buffer: Arc<Mutex<DelayedBuffer>>,
    ) -> Result<Self, HgError> {
        let size = vfs.file_size(&file)?;
        let offset =
            file.stream_position().when_reading_file(filename.as_ref())?;

        {
            let mut buf = delayed_buffer.lock().unwrap();
            buf.file_size = size;
            buf.offset = offset;
        }

        Ok(Self {
            vfs,
            filename: filename.as_ref().to_owned(),
            delayed_buffer: Some(delayed_buffer),
            file,
        })
    }

    /// Move the position of the handle to `pos`,
    /// spanning the [`DelayedBuffer`] if defined. Will return an error if
    /// an invalid seek position is asked, or for any standard io error.
    pub fn seek(&mut self, pos: SeekFrom) -> Result<u64, std::io::Error> {
        if let Some(delay_buf) = &self.delayed_buffer {
            let mut delay_buf = delay_buf.lock().unwrap();
            // Virtual file offset spans real file and data
            match pos {
                SeekFrom::Start(offset) => delay_buf.offset = offset,
                SeekFrom::End(offset) => {
                    delay_buf.offset =
                        delay_buf.len().saturating_add_signed(offset)
                }
                SeekFrom::Current(offset) => {
                    delay_buf.offset =
                        delay_buf.offset.saturating_add_signed(offset);
                }
            }
            if delay_buf.offset < delay_buf.file_size {
                self.file.seek(pos)
            } else {
                Ok(delay_buf.offset)
            }
        } else {
            self.file.seek(pos)
        }
    }

    /// Read exactly `length` bytes from `offset`.
    /// Does not affect the file position.
    /// Errors are the same as [`std::io::Read::read_exact`].
    pub fn read_exact_at(
        &self,
        length: usize,
        offset: usize,
    ) -> Result<Vec<u8>, std::io::Error> {
        let offset: u64 = offset.try_into().expect("offset too large");
        if let Some(delay_buf) = self.delayed_buffer.as_ref() {
            let mut delay_buf = delay_buf.lock().unwrap();
            let mut buf = vec![0; length];
            let file_size: isize =
                delay_buf.file_size.try_into().expect("file size too large");
            let signed_offset: isize =
                offset.try_into().expect("offset too large");
            let span: isize = signed_offset - file_size;
            let length = length.try_into().expect("too large of a length");
            let absolute_span: u64 =
                span.unsigned_abs().try_into().expect("length too large");
            if span < 0 {
                if length <= absolute_span {
                    // We're only in the file
                    self.file.read_exact_at(&mut buf, offset)?;
                } else {
                    // We're spanning file and buffer
                    self.file.read_exact_at(
                        &mut buf[..absolute_span as usize],
                        offset,
                    )?;
                    delay_buf
                        .buffer
                        .take(length - absolute_span)
                        .read_exact(&mut buf[absolute_span as usize..])?;
                }
            } else {
                // We're only in the buffer
                delay_buf.buffer[absolute_span as usize..]
                    .take(length)
                    .read_exact(&mut buf)?;
            }
            delay_buf.offset += length;
            Ok(buf.to_owned())
        } else {
            let mut buf = vec![0; length];
            self.file.read_exact_at(&mut buf, offset)?;
            Ok(buf)
        }
    }

    /// Flush the in-memory changes to disk. This does *not* write the
    /// delayed buffer, only the pending file changes.
    pub fn flush(&mut self) -> Result<(), HgError> {
        self.file.flush().when_writing_file(&self.filename)
    }

    /// Return the current position in the file
    pub fn position(&mut self) -> Result<u64, HgError> {
        self.file.stream_position().when_reading_file(&self.filename)
    }

    /// Append `data` to the file, or to the [`DelayedBuffer`], if any.
    pub fn write_all(&mut self, data: &[u8]) -> Result<(), HgError> {
        if let Some(buf) = &mut self.delayed_buffer {
            let mut delayed_buffer = buf.lock().expect("propagate the panic");
            assert_eq!(delayed_buffer.offset, delayed_buffer.len());
            delayed_buffer.buffer.extend_from_slice(data);
            delayed_buffer.offset += data.len() as u64;
            Ok(())
        } else {
            self.file.write_all(data).when_writing_file(&self.filename)?;
            Ok(())
        }
    }
}

/// Write handles to a given revlog (index + maybe data)
#[derive(Debug)]
pub struct WriteHandles {
    /// Handle to the index file
    pub index_handle: FileHandle,
    /// Handle to the data file, if the revlog is non-inline
    pub data_handle: Option<FileHandle>,
}

#[cfg(test)]
mod tests {
    use std::io::ErrorKind;

    use super::*;
    use crate::revlog::path_encode::PathEncoding;
    use crate::vfs::VfsImpl;

    #[test]
    fn test_random_access_file() {
        let base = tempfile::tempdir().unwrap().into_path();
        let filename = Path::new("a");
        let file_path = base.join(filename);
        let raf = RandomAccessFile::new(
            Box::new(VfsImpl::new(base.clone(), true, PathEncoding::None)),
            filename.to_owned(),
        );

        assert!(!raf.is_open());
        assert_eq!(&raf.filename, &filename);
        // Should fail to read a non-existing file
        match raf.get_read_handle().unwrap_err() {
            HgError::IoError { error, .. } => match error.kind() {
                std::io::ErrorKind::NotFound => {}
                _ => panic!("should be not found"),
            },
            e => panic!("{}", e.to_string()),
        }

        std::fs::write(file_path, b"1234567890").unwrap();

        // Should be able to open an existing file
        let handle = raf.get_read_handle().unwrap();
        assert!(raf.is_open());
        assert_eq!(
            handle.read_exact_at(10, 0).unwrap(),
            b"1234567890".to_vec()
        );
    }

    #[test]
    fn test_file_handle() {
        let base = tempfile::tempdir().unwrap().into_path();
        let filename = base.join("a");
        // No `create` should fail
        FileHandle::new(
            Box::new(VfsImpl::new(base.clone(), false, PathEncoding::None)),
            &filename,
            false,
            false,
        )
        .unwrap_err();
        std::fs::write(&filename, b"1234567890").unwrap();

        let mut read_handle = FileHandle::new(
            Box::new(VfsImpl::new(base.clone(), true, PathEncoding::None)),
            &filename,
            false,
            false,
        )
        .unwrap();
        assert_eq!(&read_handle.filename, &filename);
        assert_eq!(read_handle.position().unwrap(), 0);

        // Writing to an explicit read handle should fail
        read_handle.write_all(b"some data").unwrap_err();

        // reading exactly n bytes should work
        assert_eq!(read_handle.read_exact_at(3, 0).unwrap(), b"123".to_vec());
        // and the position shouldn't be remembered
        assert_eq!(read_handle.read_exact_at(2, 0).unwrap(), b"12".to_vec());
        // offset works
        assert_eq!(read_handle.read_exact_at(2, 3).unwrap(), b"45".to_vec());

        // Seeking should work
        let position = read_handle.position().unwrap();
        read_handle.seek(SeekFrom::Current(2)).unwrap();
        assert_eq!(position + 2, read_handle.position().unwrap());

        // Seeking too much data should fail
        read_handle.read_exact_at(1000, 0).unwrap_err();

        // Open a write handle
        let mut handle = FileHandle::new(
            Box::new(VfsImpl::new(base.clone(), false, PathEncoding::None)),
            &filename,
            false,
            true,
        )
        .unwrap();

        // Now writing should succeed
        handle.write_all(b"new data").unwrap();
        // Opening or writing does not seek, so we should be at the start
        assert_eq!(handle.position().unwrap(), 8);
        // We can still read
        assert_eq!(handle.read_exact_at(2, 8).unwrap(), b"90".to_vec());

        let mut read_handle = FileHandle::new(
            Box::new(VfsImpl::new(base.clone(), true, PathEncoding::None)),
            &filename,
            false,
            false,
        )
        .unwrap();
        read_handle.seek(SeekFrom::Start(0)).unwrap();
        // On-disk file contents should be changed
        assert_eq!(
            &read_handle.read_exact_at(10, 0).unwrap(),
            &b"new data90".to_vec(),
        );
        // Flushing doesn't do anything unexpected
        handle.flush().unwrap();

        let delayed_buffer = Arc::new(Mutex::new(DelayedBuffer::default()));
        let mut handle = FileHandle::new_delayed(
            Box::new(VfsImpl::new(base.clone(), false, PathEncoding::None)),
            &filename,
            false,
            delayed_buffer,
        )
        .unwrap();

        assert_eq!(
            handle.delayed_buffer.as_ref().unwrap().lock().unwrap().file_size,
            10
        );
        handle.seek(SeekFrom::End(0)).unwrap();
        handle.write_all(b"should go to buffer").unwrap();
        assert_eq!(
            handle.delayed_buffer.as_ref().unwrap().lock().unwrap().len(),
            29
        );
        read_handle.seek(SeekFrom::Start(0)).unwrap();
        // On-disk file contents should be unchanged
        assert_eq!(
            read_handle.read_exact_at(10, 0).unwrap(),
            b"new data90".to_vec(),
        );

        assert_eq!(
            read_handle.read_exact_at(1, 10).unwrap_err().kind(),
            ErrorKind::UnexpectedEof
        );

        handle.flush().unwrap();
        // On-disk file contents should still be unchanged after a flush
        assert_eq!(
            read_handle.read_exact_at(1, 10).unwrap_err().kind(),
            ErrorKind::UnexpectedEof
        );

        // Read from the buffer only
        assert_eq!(handle.read_exact_at(6, 23).unwrap(), b"buffer".to_vec());

        // Read from an overlapping section of file and buffer
        assert_eq!(
            handle.read_exact_at(20, 6).unwrap(),
            b"ta90should go to buf".to_vec()
        );

        // Read from file only
        assert_eq!(handle.read_exact_at(8, 0).unwrap(), b"new data".to_vec());
    }
}
