use std::path::Path;

use fuser::BackgroundSession;
use fuser::Config;
use fuser::Filesystem;
use fuser::MountOption;
use fuser::SessionACL;
use hg::errors::HgError;
use hg::errors::IoResultExt;

pub struct HgFuse {}

impl HgFuse {
    /// Mount an instance of this FUSE to `destination`.
    /// This function will not try to create the destination folder.
    /// This function returns a handle to the filesystem session, which
    /// if dropped unmounts the filesystem.
    pub fn mount(
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
        let filesystem = Self {};
        Ok(fuser::spawn_mount2(filesystem, mountpoint, &config)
            .when_writing_file(mountpoint)?)
    }
}

impl Filesystem for HgFuse {}
