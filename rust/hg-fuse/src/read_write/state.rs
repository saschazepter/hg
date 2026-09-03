//! Stores all the state for a virtual share. This is intended to serve both
//! FUSE calls from the kernel and RPC calls from clients.

use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::sync::Arc;

use hg::Node;

use crate::server::store::FileToken;
use crate::server::store::Store;
use crate::server::store::StoreBackend;

#[derive(Debug, derive_more::From)]
pub enum Error {
    #[from]
    Io(std::io::Error),
}

pub struct State<S, T> {
    /// The repo that we're serving for
    #[expect(unused)]
    store: Arc<Store<S, T>>,
    /// User ID returned on requests, by default it's the process'
    #[expect(unused)]
    uid: u32,
    /// Group ID returned on requests, by default it's the process'
    #[expect(unused)]
    gid: u32,
}

impl<S: StoreBackend<T>, T: FileToken> State<S, T> {
    pub fn new(
        store: Arc<Store<S, T>>,
        _backing_path: PathBuf,
        _revision: Node,
        user_id: Option<u32>,
        group_id: Option<u32>,
    ) -> Result<Self, Error> {
        let process_metadata = std::fs::metadata("/proc/self")?;
        let uid = user_id.unwrap_or_else(|| process_metadata.uid());
        let gid = group_id.unwrap_or_else(|| process_metadata.gid());

        Ok(Self { store, uid, gid })
    }
}
