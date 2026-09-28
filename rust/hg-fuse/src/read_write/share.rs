//! Stores all the state for a virtual share. This is intended to serve both
//! FUSE calls from the kernel and RPC calls from clients.

use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;

use dashmap::DashMap;
use fuser::Errno;
use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;
use hg::Node;
use hg::revlog::manifest::ManifestFlags;
use parking_lot::RwLock;

use crate::fuse::ROOT_INODE;
use crate::read_write::inode::DirEntries;
use crate::read_write::inode::Inode;
use crate::read_write::inode::InodeKind;
use crate::read_write::inode::TimeNs;
use crate::read_write::inode_backing::InodeBacking;
use crate::read_write::inode_backing::StoreKey;
use crate::server::store::Error as StoreError;
use crate::server::store::FileToken;
use crate::server::store::Store;
use crate::server::store::StoreBackend;

type InodeHandle = Arc<RwLock<Inode>>;

#[derive(Debug, derive_more::From)]
pub enum Error {
    #[from]
    Io(std::io::Error),
    Store(String),
}

impl<T> From<StoreError<T>> for Error
where
    T: std::fmt::Debug,
{
    // TODO: Error<T> seems annoying to use, just convert to a string for now.
    fn from(e: StoreError<T>) -> Self {
        Self::Store(format!("{e:?}"))
    }
}

pub struct Share<S, T> {
    /// The repo that we're serving for
    #[expect(unused)]
    store: Arc<Store<S, T>>,
    /// User ID returned on requests, by default it's the process'
    uid: u32,
    /// Group ID returned on requests, by default it's the process'
    gid: u32,
    /// Umask for file and directory permissions
    umask: u16,
    /// Inodes in memory.
    inodes: DashMap<INodeNo, InodeHandle>,
    /// Stores the next available inode number.
    next_ino: AtomicU64,
}

impl<S: StoreBackend<T>, T: FileToken> Share<S, T> {
    pub fn new(
        store: Arc<Store<S, T>>,
        _storage_dir: PathBuf,
        revision: Node,
        user_id: Option<u32>,
        group_id: Option<u32>,
    ) -> Result<Self, Error> {
        let process_metadata = std::fs::metadata("/proc/self")?;
        let uid = user_id.unwrap_or_else(|| process_metadata.uid());
        let gid = group_id.unwrap_or_else(|| process_metadata.gid());
        // TODO: Consider reading this from process info, instead of hardcoding.
        let umask = 0o022;
        let now_ns = TimeNs::now();

        let root_backing = {
            let revision_data = store.get_revision(revision)?;
            let root_index = revision_data.root_ino();
            InodeBacking::Store(StoreKey::V1 {
                node: revision,
                path: OsString::new(),
                index: root_index,
            })
        };

        let root = Inode::create_root(
            root_backing,
            0o777 & !umask,
            now_ns,
            now_ns,
            now_ns,
        );

        let inodes = DashMap::new();
        inodes.insert(ROOT_INODE, Arc::new(RwLock::new(root)));

        Ok(Self { store, uid, gid, umask, inodes, next_ino: AtomicU64::new(2) })
    }

    // Clone the Arc to minimize the time holding any locks in the inode map.
    fn get_inode_handle(&self, ino: INodeNo) -> Option<InodeHandle> {
        self.inodes.get(&ino).map(|inode_handle| Arc::clone(&inode_handle))
    }

    // Get the next available inode number.
    fn next_ino(&self) -> INodeNo {
        INodeNo(
            self.next_ino.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        )
    }

    #[expect(unused)]
    fn add_new_dir(
        &self,
        parent_ino: INodeNo,
        store_key: StoreKey,
        time_ns: TimeNs,
    ) -> INodeNo {
        let ino = self.next_ino();
        self.add_dir(
            parent_ino,
            ino,
            InodeBacking::Store(store_key),
            self.apply_umask(0o777),
            time_ns,
            time_ns,
            time_ns,
        );
        ino
    }

    #[expect(unused)]
    fn add_new_file(
        &self,
        parent_ino: INodeNo,
        store_key: StoreKey,
        time_ns: TimeNs,
        flags: ManifestFlags,
        size: u64,
    ) -> INodeNo {
        let ino = self.next_ino();
        let (file_type, perm) = self.file_type_and_perm(flags);
        self.add_file(
            parent_ino,
            ino,
            InodeBacking::Store(store_key),
            perm,
            time_ns,
            time_ns,
            time_ns,
            file_type,
            size,
        );
        ino
    }

    #[expect(clippy::too_many_arguments)]
    fn add_dir(
        &self,
        parent_ino: INodeNo,
        ino: INodeNo,
        backing: InodeBacking,
        perm: u16,
        atime_ns: TimeNs,
        mtime_ns: TimeNs,
        ctime_ns: TimeNs,
    ) {
        self.inodes.insert(
            ino,
            Arc::new(RwLock::new(Inode {
                parent: parent_ino,
                backing,
                perm,
                atime_ns,
                mtime_ns,
                ctime_ns,
                kind: InodeKind::Dir { children: DirEntries::NotLoaded },
            })),
        );
    }

    #[expect(clippy::too_many_arguments)]
    fn add_file(
        &self,
        parent_ino: INodeNo,
        ino: INodeNo,
        backing: InodeBacking,
        perm: u16,
        atime_ns: TimeNs,
        mtime_ns: TimeNs,
        ctime_ns: TimeNs,
        file_type: FileType,
        size: u64,
    ) {
        self.inodes.insert(
            ino,
            Arc::new(RwLock::new(Inode {
                parent: parent_ino,
                backing,
                perm,
                atime_ns,
                mtime_ns,
                ctime_ns,
                kind: InodeKind::File { file_type, size },
            })),
        );
    }

    pub fn getattr(&self, ino: INodeNo) -> Result<FileAttr, Errno> {
        let Some(inode_handle) = self.get_inode_handle(ino) else {
            return Err(Errno::ESTALE);
        };
        let inode = inode_handle.read();
        Ok(inode.attr(ino, self.uid, self.gid))
    }
}

impl<S: StoreBackend<T>, T: FileToken> Share<S, T> {
    fn apply_umask(&self, mode: u16) -> u16 {
        mode & !self.umask
    }

    fn file_type_and_perm(&self, flags: ManifestFlags) -> (FileType, u16) {
        if flags.is_link() {
            // According to https://man7.org/linux/man-pages/man7/symlink.7.html,
            // symlinks should always have 0777 permissions.
            (FileType::Symlink, 0o777)
        } else if flags.is_exec() {
            (FileType::RegularFile, self.apply_umask(0o777))
        } else {
            (FileType::RegularFile, self.apply_umask(0o666))
        }
    }
}
