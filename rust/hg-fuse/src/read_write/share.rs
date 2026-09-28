//! Stores all the state for a virtual share. This is intended to serve both
//! FUSE calls from the kernel and RPC calls from clients.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::ffi::OsString;
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::AtomicU64;

use dashmap::DashMap;
use fuser::Errno;
use fuser::FileAttr;
use fuser::FileType;
use fuser::INodeNo;
use hg::Node;
use hg::errors::HgBacktrace;
use hg::revlog::manifest::ManifestFlags;
use parking_lot::RwLock;

use crate::fuse::Entry;
use crate::fuse::ROOT_INODE;
use crate::read_write::inode::DirEntries;
use crate::read_write::inode::DirEntry;
use crate::read_write::inode::Inode;
use crate::read_write::inode::InodeKind;
use crate::read_write::inode::TimeNs;
use crate::read_write::inode_backing::InodeBacking;
use crate::read_write::inode_backing::StoreKey;
use crate::server::revision::OwnedRevision;
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
    MissingStoreEntries {
        node: Node,
        path: OsString,
        index: INodeNo,
        backtrace: HgBacktrace,
    },
    Internal {
        message: String,
        backtrace: HgBacktrace,
    },
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

    // Helper function to get entries from an OwnedRevision.
    fn get_entries(
        &self,
        data: &OwnedRevision<T>,
        node: Node,
        dir: impl AsRef<OsStr>,
        dir_index: INodeNo,
    ) -> Result<Vec<Entry>, Error> {
        let Some(entries) = data.entries(dir_index) else {
            return Err(Error::MissingStoreEntries {
                node,
                path: dir.as_ref().to_os_string(),
                index: dir_index,
                backtrace: HgBacktrace::capture(),
            });
        };
        // TODO: apply filtering for sparse here.
        Ok(entries)
    }

    #[expect(unused)]
    // Similar to `get_inode_handle`, but will load children if it's a
    // directory.
    fn load(&self, ino: INodeNo) -> Result<Option<InodeHandle>, Error> {
        let Some(inode_handle) = self.get_inode_handle(ino) else {
            return Ok(None);
        };
        let needs_loading = {
            let inode = inode_handle.read();
            inode.is_unloaded_dir()
        };
        if needs_loading {
            // TODO: This blocks readers, e.g. `getattr`, who do not need the
            // children entries.
            let mut inode = inode_handle.write();
            self.load_dir_children(ino, &mut inode)?;
        }
        Ok(Some(inode_handle))
    }

    fn load_dir_children(
        &self,
        parent_ino: INodeNo,
        parent_inode: &mut Inode,
    ) -> Result<(), Error> {
        if !parent_inode.is_unloaded_dir() {
            return Ok(());
        }

        let InodeKind::Dir { children } = &mut parent_inode.kind else {
            return Err(Error::Internal {
                message: "expected a directory instead of a file".to_string(),
                backtrace: HgBacktrace::capture(),
            });
        };

        // TODO: This is not exactly correct. It should probably default to the
        // most recent checkout time.
        let default_time_ns = parent_inode.ctime_ns;

        let InodeBacking::Store(StoreKey::V1 { node, path, index }) =
            &parent_inode.backing;

        let revision_data = self.store.get_revision(*node)?;
        let entries = self.get_entries(&revision_data, *node, path, *index)?;

        *children = self.load_dir_children_from_store(
            parent_ino,
            *node,
            path,
            default_time_ns,
            entries,
        );

        Ok(())
    }

    fn load_dir_children_from_store(
        &self,
        parent_ino: INodeNo,
        parent_node: Node,
        parent_path: &OsStr,
        time_ns: TimeNs,
        entries: Vec<Entry>,
    ) -> DirEntries {
        let mut children = HashMap::with_capacity(entries.len());
        for entry in entries {
            let name = entry.name().to_os_string();
            let store_key = StoreKey::V1 {
                node: parent_node,
                path: Path::new(parent_path).join(&name).into_os_string(),
                index: entry.ino(),
            };
            let dir_entry = match entry {
                Entry::Dir { .. } => {
                    let new_ino =
                        self.add_new_dir(parent_ino, store_key, time_ns);
                    DirEntry { ino: new_ino, file_type: FileType::Directory }
                }
                Entry::File { size, flags, .. } => {
                    let new_ino = self.add_new_file(
                        parent_ino, store_key, time_ns, flags, size,
                    );
                    let (file_type, _perm) = self.file_type_and_perm(flags);
                    DirEntry { ino: new_ino, file_type }
                }
            };
            let existing_child = children.insert(name, dir_entry);
            if existing_child.is_some() {
                // TODO: This should be unreachable, but this leaks
                // `existing_child`. Check this earlier or clean up the inode.
                tracing::error!(
                    "duplicate entry returned from store: node: {:?}, path: {:?}, name: {:?}",
                    &parent_node,
                    parent_path,
                    entry.name(),
                );
            }
        }
        DirEntries::Loaded(children)
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
