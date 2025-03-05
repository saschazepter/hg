//! A distinction is made between operations and commands.
//! An operation is what can be done whereas a command is what is exposed by
//! the cli. A single command can use several operations to achieve its goal.

mod annotate;
mod cat;
mod debugdata;
mod list_tracked_files;
mod status_rev_rev;
pub use annotate::{
    annotate, AnnotateOptions, AnnotateOutput, ChangesetAnnotation,
};
pub use cat::{cat, CatOutput};
pub use debugdata::debug_data;
pub use list_tracked_files::{
    list_rev_tracked_files, list_revset_tracked_files, ExpandedManifestEntry,
    FilesForRev,
};
pub use status_rev_rev::{
    status_change, status_rev_rev_no_copies, DiffStatus, ListCopies,
    StatusRevRev,
};
