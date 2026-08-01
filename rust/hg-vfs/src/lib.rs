//! Manager for multiple read-only FUSE mounts.

use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use fuser::BackgroundSession;
pub use fuser::SessionACL;
use hg::errors::HgBacktrace;
use hg::errors::HgError;
use hg::repo::Repo;
use hg_fuse::fuse::HgFuse;
pub use hg_fuse::server::store::BackendMode;
use parking_lot::Mutex;

/// Per-mount options.
pub struct MountOptions {
    /// What kind of working copy to present.
    pub backend_mode: BackendMode,
    /// Which users may access the mount.
    pub session_acl: SessionACL,
    /// Override the uid returned on requests (defaults to the process' uid).
    pub user_id: Option<u32>,
    /// Override the gid returned on requests (defaults to the process' gid).
    pub group_id: Option<u32>,
    /// Maximum number of revisions to keep loaded (`None` for no limit).
    pub max_revisions_loaded: Option<usize>,
}

/// Info about a live mount, returned by `mount_all_revs` and `list_mounts`.
#[derive(Debug, Clone)]
pub struct MountInfo {
    /// Path of the clone being served.
    pub clone_path: PathBuf,
    /// Canonical path the filesystem is mounted at.
    pub mount_point: PathBuf,
    /// Seconds since the Unix epoch when the mount was established.
    pub created_at: u64,
}

/// Why a mount or unmount failed.
#[derive(Debug, derive_more::From)]
pub enum MountError {
    /// A filesystem is already mounted at this point.
    AlreadyMounted(PathBuf, HgBacktrace),
    /// Setting up the backend or FUSE session failed.
    #[from]
    Hg(HgError),
    /// Nothing is mounted at this mount point.
    NotMounted(PathBuf, HgBacktrace),
    /// Unmounting (the umount syscall or the session thread-join) failed.
    Unmount(std::io::Error, HgBacktrace),
}

/// Registry of live read-only FUSE mounts, keyed by mount point.
#[derive(Default)]
pub struct MountManager {
    mounts: Mutex<HashMap<PathBuf, BackgroundSession>>,
}

impl MountManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Mount all of `repo`'s revisions at `mount_point`, returning the info for
    /// the new mount.
    ///
    /// Errors with `AlreadyMounted` if the mount point is already in use. On
    /// success the mount stays live until `unmount` is called or until the
    /// manager is dropped.
    pub fn mount_all_revs(
        &self,
        repo: Repo,
        mount_point: PathBuf,
        options: MountOptions,
    ) -> Result<MountInfo, MountError> {
        let clone_path = repo.working_directory_path().to_path_buf();
        let mount_point = canonical_mount_point(&mount_point);
        let mut mounts = self.mounts.lock();
        if mounts.contains_key(&mount_point) {
            return Err(MountError::AlreadyMounted(
                mount_point,
                HgBacktrace::capture(),
            ));
        }

        let session = HgFuse::mount_all_revs(
            repo,
            &mount_point,
            options.backend_mode,
            options.user_id,
            options.group_id,
            options.max_revisions_loaded,
            options.session_acl,
        )?;

        let created_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let info = MountInfo {
            clone_path,
            mount_point: mount_point.clone(),
            created_at,
        };
        mounts.insert(mount_point, session);
        Ok(info)
    }

    /// Unmount the filesystem at `mount_point`.
    ///
    /// Errors with `NotMounted` if nothing is mounted there, or `Unmount` if
    /// the umount syscall or the session thread-join fails.
    pub fn unmount(&self, mount_point: &Path) -> Result<(), MountError> {
        let mount_point = canonical_mount_point(mount_point);
        let session =
            self.mounts.lock().remove(&mount_point).ok_or_else(|| {
                MountError::NotMounted(mount_point, HgBacktrace::capture())
            })?;
        session
            .umount_and_join()
            .map_err(|e| MountError::Unmount(e, HgBacktrace::capture()))?;
        Ok(())
    }
}

/// Canonicalize a mount point so that the keys of the `mounts` map are stable.
fn canonical_mount_point(mount_point: &Path) -> PathBuf {
    std::fs::canonicalize(mount_point)
        .unwrap_or_else(|_| mount_point.to_path_buf())
}
