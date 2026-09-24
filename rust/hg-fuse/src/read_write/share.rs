//! Stores all the state for a virtual share. This is intended to serve both
//! FUSE calls from the kernel and RPC calls from clients.

use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::sync::Arc;

use dashmap::DashMap;
use fuser::Errno;
use fuser::FileAttr;
use fuser::INodeNo;
use hg::Node;
use parking_lot::RwLock;

use crate::fuse::ROOT_INODE;
use crate::read_write::inode::Inode;
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
    /// Inodes in memory.
    inodes: DashMap<INodeNo, InodeHandle>,
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

        let root =
            Inode::create_root(root_backing, 0o700, now_ns, now_ns, now_ns);

        let inodes = DashMap::new();
        inodes.insert(ROOT_INODE, Arc::new(RwLock::new(root)));

        Ok(Self { store, uid, gid, inodes })
    }

    // Clone the Arc to minimize the time holding any locks in the inode map.
    fn get_inode_handle(&self, ino: INodeNo) -> Option<InodeHandle> {
        self.inodes.get(&ino).map(|inode_handle| Arc::clone(&inode_handle))
    }

    pub fn getattr(&self, ino: INodeNo) -> Result<FileAttr, Errno> {
        let Some(inode_handle) = self.get_inode_handle(ino) else {
            return Err(Errno::ESTALE);
        };
        let inode = inode_handle.read();
        Ok(inode.attr(ino, self.uid, self.gid))
    }
}
