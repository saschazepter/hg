use std::path::Path;

use dyn_clone::DynClone;

/// The FnCache stores the list of most files contained in the store and is
/// used for stream/copy clones.
///
/// It keeps track of the name of "all" indexes and data files for all revlogs.
/// The names are relative to the store roots and are stored before any
/// encoding or path compression.
///
/// Despite its name, the FnCache is *NOT* a cache, it keep tracks of
/// information that is not easily available elsewhere. It has no mechanism
/// for detecting isn't up to date, and de-synchronization with the actual
/// contents of the repository will lead to a corrupted clone and possibly
/// other corruption during maintenance operations.
/// Strictly speaking, it could be recomputed by looking at the contents of all
/// manifests AND actual store files on disk, however that is a
/// prohibitively expensive operation.
pub trait FnCache: Sync + Send + DynClone {
    /// Whether the fncache was loaded from disk
    fn is_loaded(&self) -> bool;
    /// Add a path to be tracked in the fncache
    fn add(&self, path: &Path);
    // TODO add more methods once we start doing more with the FnCache
}
