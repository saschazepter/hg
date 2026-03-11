use std::ffi::OsStr;
use std::ffi::OsString;
use std::ops::Range;
use std::path::Path;
use std::path::PathBuf;
use std::time::Duration;

use fuser::BackgroundSession;
use fuser::Config;
use fuser::FileHandle;
use fuser::FileType;
use fuser::Filesystem;
use fuser::FopenFlags;
use fuser::Generation;
use fuser::INodeNo;
use fuser::MountOption;
use fuser::SessionACL;
use hg::Node;
use hg::Revision;
use hg::UncheckedRevision;
use hg::errors::HgError;
use hg::errors::IoResultExt;
use hg::revlog::manifest::ManifestFlags;
use hg::utils::RawData;
use hg::utils::u32_u;
use hg::utils::u64_u;

use crate::server::Server;

/// Return the path to the working directory root, relative to the FUSE root
pub fn path_to_revision_working_copy(changeset: Node) -> PathBuf {
    format!("{COMMITS_INODE_NAME}/{:x}/{FILES_INODE_NAME}", changeset).into()
}

/// A virtual filesystem in user-space (FUSE) for Mercurial
pub struct HgFuse {
    server: Server,
    /// The mount point for this FUSE
    mount_point: PathBuf,
}

impl HgFuse {
    /// Mount an instance of this FUSE to `destination`.
    /// This function will not try to create the destination folder.
    /// This function returns a handle to the filesystem session, which
    /// if dropped unmounts the filesystem.
    pub fn mount(
        server: Server,
        destination: impl AsRef<Path>,
        open_to_all: bool,
    ) -> Result<BackgroundSession, HgError> {
        let mountpoint = destination.as_ref();
        let mut config = Config::default();
        config.mount_options.extend([
            MountOption::FSName("hgvfs".to_string()),
            MountOption::RO,
            MountOption::NoAtime,
            // Don't use `MountOption::AutoUnmount`: it's prone to race
            // conditions (unmounting a new mount at the same place), and it's
            // better to leave a more explicitly borked filesystem than an
            // empty one on breakage.
        ]);
        if open_to_all {
            config.acl = SessionACL::All;
        }
        let filesystem = Self { server, mount_point: mountpoint.to_path_buf() };
        Ok(fuser::spawn_mount2(filesystem, mountpoint, &config)
            .when_writing_file(mountpoint)?)
    }
}

/// Everything we expose is read-only (for now), the kernel can cache it all
const TTL: Duration = Duration::MAX;
// Using `0` here means we're doing stateless work, which is true
// only while we're read-only, but write support at this layer may be a
// long way off.
const STATELESS_FILE_HANDLE: FileHandle = FileHandle(0);

impl Filesystem for HgFuse {
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
        ino: fuser::INodeNo,
        _fh: Option<fuser::FileHandle>,
        reply: fuser::ReplyAttr,
    ) {
        match self.server.attributes(ino) {
            Some(attributes) => {
                reply.attr(&TTL, &attributes);
            }
            None => reply.error(fuser::Errno::ENOENT),
        }
    }

    fn readdir(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        _fh: fuser::FileHandle,
        offset: u64,
        mut reply: fuser::ReplyDirectory,
    ) {
        if ino == COMMITS_INODE {
            // Forbid listing all nodes: it's useless, very slow and uses up
            // a ton of inodes
            reply.error(fuser::Errno::EACCES);
            return;
        }
        let Some(entries) = self.server.entries(ino) else {
            // TODO return the correct `ENOTDIR` for directories
            reply.error(fuser::Errno::ENOENT);
            return;
        };
        let entries = entries.into_iter();
        // TODO implement offset directly in `entries`
        for (idx, entry) in entries.enumerate().skip(u64_u(offset)) {
            if reply.add(
                entry.ino(),
                (idx + 1) as u64,
                entry.file_type(),
                entry.name(),
            ) {
                break;
            }
        }
        reply.ok()
    }

    fn lookup(
        &self,
        _req: &fuser::Request,
        parent: INodeNo,
        name: &std::ffi::OsStr,
        reply: fuser::ReplyEntry,
    ) {
        match self.server.lookup(parent, name, &self.mount_point) {
            Ok(Some(entry)) => {
                reply.entry(
                    &TTL,
                    &self.server.attributes_for_entry(entry),
                    Generation(0),
                );
            }
            Ok(None) => reply.error(fuser::Errno::ENOENT),
            // TODO better error codes
            Err(_) => reply.error(fuser::Errno::EIO),
        }
    }

    fn open(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        _flags: fuser::OpenFlags,
        reply: fuser::ReplyOpen,
    ) {
        let flags = FopenFlags::FOPEN_KEEP_CACHE | FopenFlags::FOPEN_NOFLUSH;
        reply.opened(STATELESS_FILE_HANDLE, flags);
    }

    fn read(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        _fh: fuser::FileHandle,
        offset: u64,
        size: u32,
        _flags: fuser::OpenFlags,
        _lock_owner: Option<fuser::LockOwner>,
        reply: fuser::ReplyData,
    ) {
        match self.server.read(ino) {
            Ok(Some(data)) => {
                let offset = u64_u(offset).min(data.len());
                let end = offset.saturating_add(u32_u(size)).min(data.len());
                reply.data(&data[offset..end]);
            }
            // TODO answer the correct error for folders
            Ok(None) => reply.error(fuser::Errno::ENOENT),
            // TODO better error codes
            Err(_) => reply.error(fuser::Errno::EIO),
        }
    }

    fn readlink(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        reply: fuser::ReplyData,
    ) {
        match self.server.read(ino) {
            Ok(Some(data)) => {
                reply.data(&data);
            }
            // TODO answer the correct error for folders
            Ok(None) => reply.error(fuser::Errno::EIO),
            // TODO better error codes
            Err(_) => reply.error(fuser::Errno::EIO),
        }
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
}

/// Contains information about an entry of the [`HgFuse`]
#[derive(Debug, Clone)]
pub enum Entry {
    /// A normal directory
    Dir { name: OsString, ino: INodeNo },
    /// A normal file
    File { name: OsString, ino: INodeNo, size: u64, flags: ManifestFlags },
}

impl Entry {
    /// Returns a new directory entry
    pub fn dir(name: OsString, ino: INodeNo) -> Self {
        Self::Dir { name, ino }
    }

    /// Returns a new file entry
    pub fn file(
        name: OsString,
        ino: INodeNo,
        size: u64,
        flags: ManifestFlags,
    ) -> Self {
        Self::File { name, ino, size, flags }
    }

    /// Returns the inode for this entry
    pub fn ino(&self) -> INodeNo {
        match self {
            Entry::Dir { ino, .. } => *ino,
            Entry::File { ino, .. } => *ino,
        }
    }

    /// Returns the file type of this entry
    pub fn file_type(&self) -> FileType {
        match self {
            Entry::Dir { .. } => FileType::Directory,
            Entry::File { .. } => FileType::RegularFile,
        }
    }

    /// Return the file or folder name
    pub fn name(&self) -> &OsStr {
        match self {
            Entry::Dir { name, .. } => name.as_os_str(),
            Entry::File { name, .. } => name.as_os_str(),
        }
    }
}

/// A trait for types responsible for deciding how inodes are attributed in an
/// opaque manner.
pub trait InodeEncoder {
    /// Returns a new, unique inode.
    fn new_inode(&self) -> INodeNo; // TODO should we error on out of inode?
    // TODO `reclaim_inode`?
}

// TODO different inodes per virtual share
/// Inode number for the root of the FUSE
pub const ROOT_INODE: INodeNo = INodeNo(1);
/// Name for the top-level metadata directory of the FUSE
pub const META_INODE_NAME: &str = "meta";
/// Inode number for the top-level metadata directory of the FUSE
pub const META_INODE: INodeNo = INodeNo(2);
/// Inode number for the directory containing all revision directories
pub const COMMITS_INODE: INodeNo = INodeNo(3);
/// Inode number for the null revision "working copy", which is always the same
pub const NULL_REV_INODE: INodeNo = INodeNo(4);

/// Name of the top-level directory containing all revision directories
pub const COMMITS_INODE_NAME: &str = "commits";
/// Name of the directory containing a given revision's working copy
pub const FILES_INODE_NAME: &str = "files";

/// Number of reserved inodes for the FUSE itself
const RESERVED_INODES_COUNT: u64 = 1_000_000;
/// Maximum number of inodes per changelog revision
const MAX_INODES_PER_REVISION: u64 = 100_000_000;

/// Responsible for deciding how inodes are attributed outside of revisions
pub struct RootInodeEncoder;

impl RootInodeEncoder {
    /// Get the inode for a given revision
    pub fn revision_inode(rev: Revision) -> INodeNo {
        // Keep it simple for now, devise a (much better) encoding later
        //
        // Reserve 1M inodes for the special FUSE nodes, and 100M inodes
        // for each revision
        let Ok(rev): Result<u64, _> = rev.0.try_into() else {
            return NULL_REV_INODE;
        };
        let number = rev
            .checked_add(RESERVED_INODES_COUNT)
            .expect("not enough space for inodes")
            .checked_mul(MAX_INODES_PER_REVISION)
            .expect("not enough space for inodes");
        INodeNo(number)
    }

    /// Get the inode range for a given revision
    pub fn revision_inode_range(rev: Revision) -> Range<INodeNo> {
        let min_inode = Self::revision_inode(rev);
        min_inode..INodeNo(min_inode.0 + MAX_INODES_PER_REVISION)
    }

    /// Returns `true` if this is the root inode for a revision
    pub fn is_revision_root(inode: INodeNo) -> bool {
        inode
            .0
            .checked_sub(RESERVED_INODES_COUNT)
            .map(|n| n % MAX_INODES_PER_REVISION == 0)
            .unwrap_or(false)
    }

    /// Returns `true` if this is a reserved root inode
    pub fn is_reserved(ino: INodeNo) -> bool {
        ino.0 <= RESERVED_INODES_COUNT
    }

    /// Returns the possible entries for a reserved root inode if it exists
    pub fn entries_for_reserved(ino: INodeNo) -> Option<Vec<Entry>> {
        match ino {
            ROOT_INODE => {
                let entries = vec![
                    Entry::dir(COMMITS_INODE_NAME.into(), COMMITS_INODE),
                    Entry::dir(META_INODE_NAME.into(), META_INODE),
                ];
                Some(entries)
            }
            // Don't allow listing nodes, it's quite expensive and basically
            // useless. This should be taken care of in a higher layer, but
            // this is a reminder.
            COMMITS_INODE => None,
            META_INODE => None,
            _ => None,
        }
    }

    /// Returns the child matching `name` for the parent reserved root inode,
    /// if both exist
    pub fn lookup_reserved(parent: INodeNo, name: &OsStr) -> Option<Entry> {
        match parent {
            ROOT_INODE => match name.to_string_lossy().as_ref() {
                COMMITS_INODE_NAME => {
                    Some(Entry::dir(COMMITS_INODE_NAME.into(), COMMITS_INODE))
                }
                META_INODE_NAME => {
                    Some(Entry::dir(META_INODE_NAME.into(), META_INODE))
                }
                _ => None,
            },
            _ => None,
        }
    }

    /// Returns the entry for a reserved root inode, if it exists
    pub fn entry_for_reserved(ino: INodeNo) -> Option<Entry> {
        match ino {
            ROOT_INODE => Some(Entry::dir("".into(), ROOT_INODE)),
            COMMITS_INODE => {
                Some(Entry::dir(COMMITS_INODE_NAME.into(), COMMITS_INODE))
            }
            META_INODE => Some(Entry::dir(META_INODE_NAME.into(), META_INODE)),
            _ => None,
        }
    }

    /// Returns the data for a reserved root inode, if it exists
    pub fn data_for_reserved(_ino: INodeNo) -> Option<RawData> {
        None
    }

    pub fn ino_to_rev(ino: INodeNo) -> Option<UncheckedRevision> {
        let rev_num = ino
            .0
            .checked_sub(RESERVED_INODES_COUNT)?
            .checked_div_euclid(MAX_INODES_PER_REVISION)?;
        if let Ok(rev_num) = rev_num.try_into() {
            Some(UncheckedRevision(rev_num))
        } else {
            None
        }
    }
}
