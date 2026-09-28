use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;
use std::time::Duration;

use dashmap::DashMap;
use fuser::BackgroundSession;
use fuser::Config;
use fuser::FileHandle;
use fuser::Filesystem;
use fuser::FopenFlags;
use fuser::INodeNo;
use fuser::InitFlags;
use fuser::MountOption;
use fuser::SessionACL;
use hg::errors::HgError;
use hg::errors::IoResultExt;
use hg::utils::u_u64;
use hg::utils::u64_u;
use parking_lot::Mutex;

use crate::read_write::share::ReaddirEntry;
use crate::read_write::share::Share;
use crate::server::store::FileToken;
use crate::server::store::StoreBackend;

pub struct HgFuse<S, T> {
    share: Arc<Share<S, T>>,
    /// FUSE capability for zero-message open
    fuse_no_open_support: bool,
    /// Readdir handles are created during opendir and closed in releasedir
    readdir_handles: DashMap<u64, Arc<ReaddirHandle>>,
    next_readdir_handle: AtomicU64,
}

const TTL: Duration = Duration::MAX;
const STATELESS_FILE_HANDLE: FileHandle = FileHandle(0);

impl<S: StoreBackend<T>, T: FileToken> HgFuse<S, T> {
    /// Mount an instance of this FUSE to `destination`.
    /// This function will not try to create the destination folder.
    /// This function returns a handle to the filesystem session, which
    /// if dropped unmounts the filesystem.
    pub fn mount(
        share: Arc<Share<S, T>>,
        destination: impl AsRef<Path>,
        session_acl: SessionACL,
        thread_count: usize,
    ) -> Result<BackgroundSession, HgError> {
        let mountpoint = destination.as_ref();
        let mut config = Config::default();
        config.mount_options.extend([
            MountOption::FSName("hgvfs".to_string()),
            MountOption::RW,
            MountOption::NoAtime,
            // Don't use `MountOption::AutoUnmount`: it's prone to race
            // conditions (unmounting a new mount at the same place), and it's
            // better to leave a more explicitly borked filesystem than an
            // empty one on breakage.
        ]);
        config.acl = session_acl;
        config.n_threads = Some(thread_count);
        let filesystem = Self {
            share,
            fuse_no_open_support: false,
            readdir_handles: DashMap::new(),
            next_readdir_handle: AtomicU64::new(1),
        };
        Ok(fuser::spawn_mount(filesystem, mountpoint, &config)
            .when_writing_file(mountpoint)?)
    }
}

impl<S: StoreBackend<T>, T: FileToken> Filesystem for HgFuse<S, T> {
    fn init(
        &mut self,
        _req: &fuser::Request,
        config: &mut fuser::KernelConfig,
    ) -> std::io::Result<()> {
        match config.add_capabilities(InitFlags::FUSE_NO_OPEN_SUPPORT) {
            Ok(()) => self.fuse_no_open_support = true,
            Err(_) => tracing::warn!("no FUSE_NO_OPEN_SUPPORT capability"),
        };
        Ok(())
    }

    fn access(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        _mask: fuser::AccessFlags,
        reply: fuser::ReplyEmpty,
    ) {
        reply.ok();
    }

    fn getattr(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        _fh: Option<fuser::FileHandle>,
        reply: fuser::ReplyAttr,
    ) {
        match self.share.getattr(ino) {
            Ok(attributes) => {
                reply.attr(&TTL, &attributes);
            }
            Err(err) => reply.error(err),
        };
    }

    fn opendir(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        _flags: fuser::OpenFlags,
        reply: fuser::ReplyOpen,
    ) {
        let flags = FopenFlags::FOPEN_KEEP_CACHE
            | FopenFlags::FOPEN_CACHE_DIR
            | FopenFlags::FOPEN_NOFLUSH;
        let key = self
            .next_readdir_handle
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let value = ReaddirHandle { entries: Mutex::new(None) };
        let existing_handle = self.readdir_handles.insert(key, Arc::new(value));
        if existing_handle.is_some() {
            tracing::warn!(
                "unexpected: readdir handle already exists: {}",
                key
            );
        }
        reply.opened(FileHandle(key), flags)
    }

    fn readdir(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        fh: fuser::FileHandle,
        offset: u64,
        mut reply: fuser::ReplyDirectory,
    ) {
        let readdir_handle = {
            match self.readdir_handles.get(&fh.0) {
                None => {
                    tracing::error!("no readdir handle: {}", fh.0);
                    reply.error(fuser::Errno::EIO);
                    return;
                }
                Some(readdir_handle) => {
                    // Clone the Arc to avoid holding the map lock for too long.
                    Arc::clone(&readdir_handle)
                }
            }
        };
        // Load entries in readdir instead of opendir, because not all opendir
        // calls are followed by readdir calls.
        // TODO: If the directory is small enough such that `reply.add` does not
        // fill the buffer, maybe we can avoid creating a snapshot at all?
        // TODO: Another option is to store this in DirEntries::Loaded instead:
        // - `slots: slab::Slab<Arc<OsString>, DirEntry>`
        // - `by_name: HashMap<Arc<OsString>, usize>`
        // This should improve readdir, but would add some overhead to other
        // operations.
        let mut entries_guard = readdir_handle.entries.lock();
        let entries = match &mut *entries_guard {
            // `rewinddir` resets offset to 0, and expects us to reload the
            // entries.
            Some(entries) if offset != 0 => entries,
            slot => match self.share.entries(ino) {
                Ok(entries) => slot.insert(entries),
                Err(err) => {
                    *slot = None; // For the `rewinddir` path.
                    reply.error(err);
                    return;
                }
            },
        };
        for (i, entry) in entries.iter().enumerate().skip(u64_u(offset)) {
            if reply.add(entry.ino, u_u64(i + 1), entry.file_type, &entry.name)
            {
                break;
            }
        }
        reply.ok();
    }

    fn releasedir(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        fh: FileHandle,
        _flags: fuser::OpenFlags,
        reply: fuser::ReplyEmpty,
    ) {
        let removed_handle = self.readdir_handles.remove(&fh.0);
        if removed_handle.is_none() {
            tracing::warn!("unexpected: no readdir handle: {}", fh.0);
        }
        reply.ok();
    }

    fn open(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        _flags: fuser::OpenFlags,
        reply: fuser::ReplyOpen,
    ) {
        if self.fuse_no_open_support {
            // Tell the kernel to use zero-message open
            reply.error(fuser::Errno::ENOSYS);
        } else {
            let flags =
                FopenFlags::FOPEN_KEEP_CACHE | FopenFlags::FOPEN_NOFLUSH;
            reply.opened(STATELESS_FILE_HANDLE, flags);
        }
    }
}

struct ReaddirHandle {
    entries: Mutex<Option<Vec<ReaddirEntry>>>,
}
