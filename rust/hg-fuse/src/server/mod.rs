use std::os::unix::fs::MetadataExt;
use std::sync::Mutex;
use std::time::SystemTime;

use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;
use hg::errors::HgError;
use hg::errors::IoResultExt;
use hg::repo::Repo;

use crate::fuse::Entry;

/// Responsible for serving contents from the store to the FUSE layer
pub struct Server {
    /// The repo that we're serving for
    /// TODO more than 1 repo at once
    #[expect(unused)]
    repo: Mutex<Repo>,
    /// When this server was started
    start_time: SystemTime,
    /// User ID from this process
    uid: u32,
    /// Group ID from this process
    gid: u32,
}

impl Server {
    pub fn new(repo: &Repo) -> Result<Self, HgError> {
        // Recreate our owned repo
        let repo = Repo::find(
            repo.config(),
            Some(repo.working_directory_path().to_path_buf()),
        )?;
        let process_metadata =
            std::fs::metadata("/proc/self").when_reading_file("/proc/self")?;
        let uid = process_metadata.uid();
        let gid = process_metadata.gid();
        Ok(Self {
            repo: Mutex::new(repo),
            start_time: SystemTime::now(),
            uid,
            gid,
        })
    }

    /// Return the [`Entry`] that corresponds to `ino`
    pub fn get_entry(&self, ino: fuser::INodeNo) -> Option<Entry> {
        if ino != INodeNo(1) {
            // TODO handle more than the root node
            return None;
        }
        Some(Entry::dir(self.start_time))
    }

    pub fn attributes(&self, ino: INodeNo) -> Option<fuser::FileAttr> {
        if ino != INodeNo(1) {
            // TODO handle more than the root node
            return None;
        }

        const BLOCK_SIZE: u32 = 4096;
        // Fake size that's obvious enough to be grepped in case that's
        // a problem.
        const FAKE_DIR_SIZE: u64 = 2005;

        Some(FileAttr {
            ino,
            size: FAKE_DIR_SIZE,
            blocks: 0,
            atime: self.start_time,
            mtime: self.start_time,
            ctime: self.start_time,
            crtime: self.start_time,
            kind: FileType::Directory,
            perm: 0o555,
            nlink: 1,
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            flags: 0,
            blksize: BLOCK_SIZE,
        })
    }
}
