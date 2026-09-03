use std::path::Path;
use std::sync::Arc;

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

use crate::read_write::state::State;
use crate::server::store::FileToken;
use crate::server::store::StoreBackend;

pub struct HgFuse<S, T> {
    #[expect(unused)]
    state: Arc<State<S, T>>,
    /// FUSE capability for zero-message open
    fuse_no_open_support: bool,
}

const STATELESS_FILE_HANDLE: FileHandle = FileHandle(0);

impl<S: StoreBackend<T>, T: FileToken> HgFuse<S, T> {
    /// Mount an instance of this FUSE to `destination`.
    /// This function will not try to create the destination folder.
    /// This function returns a handle to the filesystem session, which
    /// if dropped unmounts the filesystem.
    pub fn mount(
        state: Arc<State<S, T>>,
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
        let filesystem = Self { state, fuse_no_open_support: false };
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
        reply.opened(STATELESS_FILE_HANDLE, flags);
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
