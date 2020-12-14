//! A distinction is made between operations and commands.
//! An operation is what can be done whereas a command is what is exposed by
//! the cli. A single command can use several operations to achieve its goal.

mod cat;
mod debugdata;
mod dirstate_status;
mod find_root;
mod list_tracked_files;
pub use cat::{cat, CatRevError, CatRevErrorKind};
pub use debugdata::{
    debug_data, DebugDataError, DebugDataErrorKind, DebugDataKind,
};
pub use find_root::{
    find_root, find_root_from_path, FindRootError, FindRootErrorKind,
};
pub use list_tracked_files::{
    list_rev_tracked_files, FilesForRev, ListRevTrackedFilesError,
    ListRevTrackedFilesErrorKind,
};
pub use list_tracked_files::{
    Dirstate, ListDirstateTrackedFilesError, ListDirstateTrackedFilesErrorKind,
};
