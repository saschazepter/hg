//! Represents where the data for an inode is stored.

use std::ffi::OsString;

use fuser::INodeNo;
use hg::Node;

#[derive(Debug, Clone)]
pub enum InodeBacking {
    Store(StoreKey),
}

#[derive(Debug, Clone)]
pub enum StoreKey {
    V1 {
        node: Node,
        // TODO: We should replace this with some key, with these properties:
        // - Can be used to look up directory or file contents.
        // - Deterministic, so we can persist it and remove `index`.
        // - Merkle hashing, to speed up comparison of equal subtrees during
        //   status and update.
        path: OsString,
        // This can be used with OwnedRevision::get_entry. This is not
        // consistent across restarts, so this should not be persisted.
        index: INodeNo,
    },
}
