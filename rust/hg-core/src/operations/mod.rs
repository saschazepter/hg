//! A distinction is made between operations and commands.
//! An operation is what can be done whereas a command is what is exposed by
//! the cli. A single command can use several operations to achieve its goal.

mod annotate;
mod cat;
mod debugdata;
mod list_tracked_files;
mod status_rev_rev;
pub use annotate::annotate;
pub use annotate::AnnotateOptions;
pub use annotate::AnnotateOutput;
pub use annotate::ChangesetAnnotatedFile;
pub use annotate::ChangesetAnnotation;
pub use cat::cat;
pub use cat::CatOutput;
pub use debugdata::debug_data;
pub use list_tracked_files::list_rev_tracked_files;
pub use list_tracked_files::list_revset_tracked_files;
pub use list_tracked_files::ExpandedManifestEntry;
pub use list_tracked_files::FilesForRev;
pub use list_tracked_files::FilesForRevBorrowed;
pub use status_rev_rev::status_change;
pub use status_rev_rev::status_rev_rev_no_copies;
pub use status_rev_rev::DiffStatus;
pub use status_rev_rev::ListCopies;
pub use status_rev_rev::StatusRevRev;
