use std::collections::HashMap;
use std::ffi::OsString;
use std::time::Duration;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;

use crate::fuse::ROOT_INODE;
use crate::read_write::inode_backing::InodeBacking;

const BLOCK_SIZE: u32 = 4096;
// Fake size that's obvious enough to be grepped in case that's
// a problem.
const FAKE_DIR_SIZE: u64 = 2005;

pub struct Inode {
    pub parent: INodeNo,
    pub backing: InodeBacking,
    pub perm: u16,
    pub atime_ns: TimeNs,
    pub mtime_ns: TimeNs,
    pub ctime_ns: TimeNs,
    pub kind: InodeKind,
}

impl Inode {
    pub fn create_root(
        backing: InodeBacking,
        perm: u16,
        atime_ns: TimeNs,
        mtime_ns: TimeNs,
        ctime_ns: TimeNs,
    ) -> Self {
        Self {
            // This is correct for readdir purposes. Other filesystems also show
            // ".." in the root dir as having inode 1.
            parent: ROOT_INODE,
            backing,
            perm,
            atime_ns,
            mtime_ns,
            ctime_ns,
            kind: InodeKind::Dir { children: DirEntries::NotLoaded },
        }
    }

    fn size(&self) -> u64 {
        match self.kind {
            InodeKind::Dir { .. } => FAKE_DIR_SIZE,
            InodeKind::File { size, .. } => size,
        }
    }

    fn links(&self) -> u32 {
        match self.kind {
            InodeKind::Dir { .. } => {
                // 2 + children.len() would be more correct, but we don't always
                // have the children loaded. Using 1 seems most correct here to
                // signal that we do not know how many links there are. For
                // example, see `i_links_count` in:
                // https://www.kernel.org/doc/html/latest/filesystems/ext4/inodes.html
                1
            }
            InodeKind::File { .. } => {
                // Hard links are currently not implemented.
                1
            }
        }
    }

    fn file_type(&self) -> FileType {
        match self.kind {
            InodeKind::Dir { .. } => FileType::Directory,
            InodeKind::File { file_type, .. } => file_type,
        }
    }

    pub fn attr(&self, ino: INodeNo, uid: u32, gid: u32) -> FileAttr {
        let size = self.size();
        FileAttr {
            ino,
            size,
            blocks: size.div_ceil(u64::from(BLOCK_SIZE)),
            atime: self.atime_ns.to_system_time(),
            mtime: self.mtime_ns.to_system_time(),
            ctime: self.ctime_ns.to_system_time(),
            // Creation time is macOS only and not supported.
            crtime: UNIX_EPOCH,
            kind: self.file_type(),
            perm: self.perm,
            nlink: self.links(),
            uid,
            gid,
            rdev: 0,
            blksize: BLOCK_SIZE,
            flags: 0,
        }
    }

    pub fn is_unloaded_dir(&self) -> bool {
        match &self.kind {
            InodeKind::File { .. } => false,
            InodeKind::Dir { children } => match children {
                DirEntries::Loaded(_) => false,
                DirEntries::NotLoaded => true,
            },
        }
    }
}

pub enum InodeKind {
    Dir {
        children: DirEntries,
    },
    File {
        // TODO: Is it worth it to use a NonDirType here?
        file_type: FileType,
        size: u64,
    },
}

pub enum DirEntries {
    NotLoaded,
    Loaded(HashMap<OsString, DirEntry>),
}

#[derive(Clone)]
pub struct DirEntry {
    pub ino: INodeNo,
    pub file_type: FileType,
}

/// This struct saves 8 bytes over a `SystemTime`. It records nanoseconds since
/// Unix epoch, so the representable range is roughly years 1970 to 2554.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TimeNs(pub u64);

impl TimeNs {
    /// Creates a new `TimeNs` from `SystemTime`, clamping the value as needed.
    pub fn saturating_from_system_time(time: SystemTime) -> Self {
        let nanos: u128 = time
            .duration_since(UNIX_EPOCH)
            .map_or(0, |duration| duration.as_nanos());
        Self(u64::try_from(nanos).unwrap_or(u64::MAX))
    }

    pub fn now() -> Self {
        Self::saturating_from_system_time(SystemTime::now())
    }

    pub fn to_system_time(&self) -> SystemTime {
        UNIX_EPOCH + Duration::from_nanos(self.0)
    }
}
