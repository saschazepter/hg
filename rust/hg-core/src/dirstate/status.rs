// status.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Rust implementation of dirstate.status (dirstate.py).
//! It is currently missing a lot of functionality compared to the Python one
//! and will only be triggered in narrow cases.

use crate::dirstate::dirstate_map::BorrowedPath;
use crate::dirstate::dirstate_map::ChildNodesRef;
use crate::dirstate::dirstate_map::DirstateMap;
use crate::dirstate::dirstate_map::DirstateVersion;
use crate::dirstate::dirstate_map::NodeRef;
use crate::dirstate::entry::TruncatedTimestamp;
use crate::dirstate::on_disk::DirstateV2ParseError;
use crate::filepatterns::PatternError;
use crate::filepatterns::PatternFileWarning;
use crate::matchers::get_ignore_function;
use crate::matchers::{Matcher, VisitChildrenSet};
use crate::utils::files::filesystem_now;
use crate::utils::files::get_bytes_from_os_string;
use crate::utils::files::get_bytes_from_path;
use crate::utils::files::get_path_from_bytes;
use crate::utils::hg_path::hg_path_to_path_buf;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathError;
use once_cell::sync::OnceCell;
use rayon::prelude::*;
use sha1::{Digest, Sha1};
use std::io;
use std::os::unix::prelude::FileTypeExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Mutex;

use std::{borrow::Cow, fmt};

/// Wrong type of file from a `BadMatch`
/// Note: a lot of those don't exist on all platforms.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum BadType {
    CharacterDevice,
    BlockDevice,
    FIFO,
    Socket,
    Directory,
    Unknown,
}

impl fmt::Display for BadType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str(match self {
            BadType::CharacterDevice => "character device",
            BadType::BlockDevice => "block device",
            BadType::FIFO => "fifo",
            BadType::Socket => "socket",
            BadType::Directory => "directory",
            BadType::Unknown => "unknown",
        })
    }
}

/// Was explicitly matched but cannot be found/accessed
#[derive(Debug, Copy, Clone)]
pub enum BadMatch {
    OsError(i32),
    BadType(BadType),
}

/// `Box<dyn Trait>` is syntactic sugar for `Box<dyn Trait + 'static>`, so add
/// an explicit lifetime here to not fight `'static` bounds "out of nowhere".
pub type IgnoreFnType<'a> =
    Box<dyn for<'r> Fn(&'r HgPath) -> bool + Sync + 'a>;

/// We have a good mix of owned (from directory traversal) and borrowed (from
/// the dirstate/explicit) paths, this comes up a lot.
pub type HgPathCow<'a> = Cow<'a, HgPath>;

#[derive(Debug, Copy, Clone)]
pub struct StatusOptions {
    /// Whether we are on a filesystem with UNIX-like exec flags
    pub check_exec: bool,
    pub list_clean: bool,
    pub list_unknown: bool,
    pub list_ignored: bool,
    /// Whether to populate `StatusPath::copy_source`
    pub list_copies: bool,
    /// Whether to collect traversed dirs for applying a callback later.
    /// Used by `hg purge` for example.
    pub collect_traversed_dirs: bool,
}

#[derive(Default)]
pub struct DirstateStatus<'a> {
    /// The current time at the start of the `status()` algorithm, as measured
    /// and possibly truncated by the filesystem.
    pub filesystem_time_at_status_start: Option<TruncatedTimestamp>,

    /// Tracked files whose contents have changed since the parent revision
    pub modified: Vec<StatusPath<'a>>,

    /// Newly-tracked files that were not present in the parent
    pub added: Vec<StatusPath<'a>>,

    /// Previously-tracked files that have been (re)moved with an hg command
    pub removed: Vec<StatusPath<'a>>,

    /// (Still) tracked files that are missing, (re)moved with an non-hg
    /// command
    pub deleted: Vec<StatusPath<'a>>,

    /// Tracked files that are up to date with the parent.
    /// Only pupulated if `StatusOptions::list_clean` is true.
    pub clean: Vec<StatusPath<'a>>,

    /// Files in the working directory that are ignored with `.hgignore`.
    /// Only pupulated if `StatusOptions::list_ignored` is true.
    pub ignored: Vec<StatusPath<'a>>,

    /// Files in the working directory that are neither tracked nor ignored.
    /// Only pupulated if `StatusOptions::list_unknown` is true.
    pub unknown: Vec<StatusPath<'a>>,

    /// Was explicitly matched but cannot be found/accessed
    pub bad: Vec<(HgPathCow<'a>, BadMatch)>,

    /// Either clean or modified, but we can’t tell from filesystem metadata
    /// alone. The file contents need to be read and compared with that in
    /// the parent.
    pub unsure: Vec<StatusPath<'a>>,

    /// Only filled if `collect_traversed_dirs` is `true`
    pub traversed: Vec<HgPathCow<'a>>,

    /// Whether `status()` made changed to the `DirstateMap` that should be
    /// written back to disk
    pub dirty: bool,
}

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct StatusPath<'a> {
    pub path: HgPathCow<'a>,
    pub copy_source: Option<HgPathCow<'a>>,
}

#[derive(Debug, derive_more::From)]
pub enum StatusError {
    /// An invalid path that cannot be represented in Mercurial was found
    Path(HgPathError),
    /// An invalid "ignore" pattern was found
    Pattern(PatternError),
    /// Corrupted dirstate
    DirstateV2ParseError(DirstateV2ParseError),
}

impl fmt::Display for StatusError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            StatusError::Path(error) => error.fmt(f),
            StatusError::Pattern(error) => error.fmt(f),
            StatusError::DirstateV2ParseError(_) => {
                f.write_str("dirstate-v2 parse error")
            }
        }
    }
}

/// Returns the status of the working directory compared to its parent
/// changeset.
///
/// This algorithm is based on traversing the filesystem tree (`fs` in function
/// and variable names) and dirstate tree at the same time. The core of this
/// traversal is the recursive `traverse_fs_directory_and_dirstate` function
/// and its use of `itertools::merge_join_by`. When reaching a path that only
/// exists in one of the two trees, depending on information requested by
/// `options` we may need to traverse the remaining subtree.
#[logging_timer::time("trace")]
pub fn status<'dirstate>(
    dmap: &'dirstate mut DirstateMap,
    matcher: &(dyn Matcher + Sync),
    root_dir: PathBuf,
    ignore_files: Vec<PathBuf>,
    options: StatusOptions,
) -> Result<(DirstateStatus<'dirstate>, Vec<PatternFileWarning>), StatusError>
{
    // Also cap for a Python caller of this function, but don't complain if
    // the global threadpool has already been set since this code path is also
    // being used by `rhg`, which calls this early.
    let _ = crate::utils::cap_default_rayon_threads();

    let (ignore_fn, warnings, patterns_changed): (IgnoreFnType, _, _) =
        if options.list_ignored || options.list_unknown {
            let (ignore_fn, warnings, changed) = match dmap.dirstate_version {
                DirstateVersion::V1 => {
                    let (ignore_fn, warnings) = get_ignore_function(
                        ignore_files,
                        &root_dir,
                        &mut |_source, _pattern_bytes| {},
                    )?;
                    (ignore_fn, warnings, None)
                }
                DirstateVersion::V2 => {
                    let mut hasher = Sha1::new();
                    let (ignore_fn, warnings) = get_ignore_function(
                        ignore_files,
                        &root_dir,
                        &mut |source, pattern_bytes| {
                            // If inside the repo, use the relative version to
                            // make it deterministic inside tests.
                            // The performance hit should be negligible.
                            let source = source
                                .strip_prefix(&root_dir)
                                .unwrap_or(source);
                            let source = get_bytes_from_path(source);

                            let mut subhasher = Sha1::new();
                            subhasher.update(pattern_bytes);
                            let patterns_hash = subhasher.finalize();

                            hasher.update(source);
                            hasher.update(b" ");
                            hasher.update(patterns_hash);
                            hasher.update(b"\n");
                        },
                    )?;
                    let new_hash = *hasher.finalize().as_ref();
                    let changed = new_hash != dmap.ignore_patterns_hash;
                    dmap.ignore_patterns_hash = new_hash;
                    (ignore_fn, warnings, Some(changed))
                }
            };
            (ignore_fn, warnings, changed)
        } else {
            (Box::new(|&_| true), vec![], None)
        };

    let filesystem_time_at_status_start =
        filesystem_now(&root_dir).ok().map(TruncatedTimestamp::from);

    // If the repository is under the current directory, prefer using a
    // relative path, so the kernel needs to traverse fewer directory in every
    // call to `read_dir` or `symlink_metadata`.
    // This is effective in the common case where the current directory is the
    // repository root.

    // TODO: Better yet would be to use libc functions like `openat` and
    // `fstatat` to remove such repeated traversals entirely, but the standard
    // library does not provide APIs based on those.
    // Maybe with a crate like https://crates.io/crates/openat instead?
    let root_dir = if let Some(relative) = std::env::current_dir()
        .ok()
        .and_then(|cwd| root_dir.strip_prefix(cwd).ok())
    {
        relative
    } else {
        &root_dir
    };

    let outcome = DirstateStatus {
        filesystem_time_at_status_start,
        ..Default::default()
    };
    let common = StatusCommon {
        dmap,
        options,
        matcher,
        ignore_fn,
        outcome: Mutex::new(outcome),
        ignore_patterns_have_changed: patterns_changed,
        new_cacheable_directories: Default::default(),
        outdated_cached_directories: Default::default(),
        filesystem_time_at_status_start,
    };
    let is_at_repo_root = true;
    let hg_path = &BorrowedPath::OnDisk(HgPath::new(""));
    let has_ignored_ancestor = HasIgnoredAncestor::create(None, hg_path);
    let root_cached_mtime = None;
    // If the path we have for the repository root is a symlink, do follow it.
    // (As opposed to symlinks within the working directory which are not
    // followed, using `std::fs::symlink_metadata`.)
    common.traverse_fs_directory_and_dirstate(
        &has_ignored_ancestor,
        dmap.root.as_ref(),
        hg_path,
        &DirEntry {
            hg_path: Cow::Borrowed(HgPath::new(b"")),
            fs_path: Cow::Borrowed(root_dir),
            symlink_metadata: None,
            file_type: FakeFileType::Directory,
        },
        root_cached_mtime,
        is_at_repo_root,
    )?;
    if let Some(file_set) = common.matcher.file_set() {
        for file in file_set {
            if !file.is_empty() && !dmap.has_node(file)? {
                let path = hg_path_to_path_buf(file)?;
                if let io::Result::Err(error) =
                    root_dir.join(path).symlink_metadata()
                {
                    common.io_error(error, file)
                }
            }
        }
    }
    let mut outcome = common.outcome.into_inner().unwrap();
    let new_cacheable = common.new_cacheable_directories.into_inner().unwrap();
    let outdated = common.outdated_cached_directories.into_inner().unwrap();

    outcome.dirty = common.ignore_patterns_have_changed == Some(true)
        || !outdated.is_empty()
        || (!new_cacheable.is_empty()
            && dmap.dirstate_version == DirstateVersion::V2);

    // Remove outdated mtimes before adding new mtimes, in case a given
    // directory is both
    for path in &outdated {
        dmap.clear_cached_mtime(path)?;
    }
    for (path, mtime) in &new_cacheable {
        dmap.set_cached_mtime(path, *mtime)?;
    }

    Ok((outcome, warnings))
}

/// Bag of random things needed by various parts of the algorithm. Reduces the
/// number of parameters passed to functions.
struct StatusCommon<'a, 'tree, 'on_disk: 'tree> {
    dmap: &'tree DirstateMap<'on_disk>,
    options: StatusOptions,
    matcher: &'a (dyn Matcher + Sync),
    ignore_fn: IgnoreFnType<'a>,
    outcome: Mutex<DirstateStatus<'on_disk>>,
    /// New timestamps of directories to be used for caching their readdirs
    new_cacheable_directories:
        Mutex<Vec<(Cow<'on_disk, HgPath>, TruncatedTimestamp)>>,
    /// Used to invalidate the readdir cache of directories
    outdated_cached_directories: Mutex<Vec<Cow<'on_disk, HgPath>>>,

    /// Whether ignore files like `.hgignore` have changed since the previous
    /// time a `status()` call wrote their hash to the dirstate. `None` means
    /// we don’t know as this run doesn’t list either ignored or uknown files
    /// and therefore isn’t reading `.hgignore`.
    ignore_patterns_have_changed: Option<bool>,

    /// The current time at the start of the `status()` algorithm, as measured
    /// and possibly truncated by the filesystem.
    filesystem_time_at_status_start: Option<TruncatedTimestamp>,
}

enum Outcome {
    Modified,
    Added,
    Removed,
    Deleted,
    Clean,
    Ignored,
    Unknown,
    Unsure,
}

/// Lazy computation of whether a given path has a hgignored
/// ancestor.
struct HasIgnoredAncestor<'a> {
    /// `path` and `parent` constitute the inputs to the computation,
    /// `cache` stores the outcome.
    path: &'a HgPath,
    parent: Option<&'a HasIgnoredAncestor<'a>>,
    cache: OnceCell<bool>,
}

impl<'a> HasIgnoredAncestor<'a> {
    fn create(
        parent: Option<&'a HasIgnoredAncestor<'a>>,
        path: &'a HgPath,
    ) -> HasIgnoredAncestor<'a> {
        Self {
            path,
            parent,
            cache: OnceCell::new(),
        }
    }

    fn force(&self, ignore_fn: &IgnoreFnType<'_>) -> bool {
        match self.parent {
            None => false,
            Some(parent) => {
                *(self.cache.get_or_init(|| {
                    parent.force(ignore_fn) || ignore_fn(self.path)
                }))
            }
        }
    }
}

impl<'a, 'tree, 'on_disk> StatusCommon<'a, 'tree, 'on_disk> {
    fn push_outcome(
        &self,
        which: Outcome,
        dirstate_node: &NodeRef<'tree, 'on_disk>,
    ) -> Result<(), DirstateV2ParseError> {
        let path = dirstate_node
            .full_path_borrowed(self.dmap.on_disk)?
            .detach_from_tree();
        let copy_source = if self.options.list_copies {
            dirstate_node
                .copy_source_borrowed(self.dmap.on_disk)?
                .map(|source| source.detach_from_tree())
        } else {
            None
        };
        self.push_outcome_common(which, path, copy_source);
        Ok(())
    }

    fn push_outcome_without_copy_source(
        &self,
        which: Outcome,
        path: &BorrowedPath<'_, 'on_disk>,
    ) {
        self.push_outcome_common(which, path.detach_from_tree(), None)
    }

    fn push_outcome_common(
        &self,
        which: Outcome,
        path: HgPathCow<'on_disk>,
        copy_source: Option<HgPathCow<'on_disk>>,
    ) {
        let mut outcome = self.outcome.lock().unwrap();
        let vec = match which {
            Outcome::Modified => &mut outcome.modified,
            Outcome::Added => &mut outcome.added,
            Outcome::Removed => &mut outcome.removed,
            Outcome::Deleted => &mut outcome.deleted,
            Outcome::Clean => &mut outcome.clean,
            Outcome::Ignored => &mut outcome.ignored,
            Outcome::Unknown => &mut outcome.unknown,
            Outcome::Unsure => &mut outcome.unsure,
        };
        vec.push(StatusPath { path, copy_source });
    }

    fn read_dir(
        &self,
        hg_path: &HgPath,
        fs_path: &Path,
        is_at_repo_root: bool,
    ) -> Result<Vec<DirEntry>, ()> {
        DirEntry::read_dir(fs_path, is_at_repo_root)
            .map_err(|error| self.io_error(error, hg_path))
    }

    fn io_error(&self, error: std::io::Error, hg_path: &HgPath) {
        let errno = error.raw_os_error().expect("expected real OS error");
        self.outcome
            .lock()
            .unwrap()
            .bad
            .push((hg_path.to_owned().into(), BadMatch::OsError(errno)))
    }

    fn check_for_outdated_directory_cache(
        &self,
        dirstate_node: &NodeRef<'tree, 'on_disk>,
    ) -> Result<bool, DirstateV2ParseError> {
        if self.ignore_patterns_have_changed == Some(true)
            && dirstate_node.cached_directory_mtime()?.is_some()
        {
            self.outdated_cached_directories.lock().unwrap().push(
                dirstate_node
                    .full_path_borrowed(self.dmap.on_disk)?
                    .detach_from_tree(),
            );
            return Ok(true);
        }
        Ok(false)
    }

    /// If this returns true, we can get accurate results by only using
    /// `symlink_metadata` for child nodes that exist in the dirstate and don’t
    /// need to call `read_dir`.
    fn can_skip_fs_readdir(
        &self,
        directory_entry: &DirEntry,
        cached_directory_mtime: Option<TruncatedTimestamp>,
    ) -> bool {
        if !self.options.list_unknown && !self.options.list_ignored {
            // All states that we care about listing have corresponding
            // dirstate entries.
            // This happens for example with `hg status -mard`.
            return true;
        }
        if !self.options.list_ignored
            && self.ignore_patterns_have_changed == Some(false)
        {
            if let Some(cached_mtime) = cached_directory_mtime {
                // The dirstate contains a cached mtime for this directory, set
                // by a previous run of the `status` algorithm which found this
                // directory eligible for `read_dir` caching.
                if let Ok(meta) = directory_entry.symlink_metadata() {
                    if cached_mtime
                        .likely_equal_to_mtime_of(&meta)
                        .unwrap_or(false)
                    {
                        // The mtime of that directory has not changed
                        // since then, which means that the results of
                        // `read_dir` should also be unchanged.
                        return true;
                    }
                }
            }
        }
        false
    }

    fn should_visit(set: &VisitChildrenSet, basename: &HgPath) -> bool {
        match set {
            VisitChildrenSet::This | VisitChildrenSet::Recursive => true,
            VisitChildrenSet::Empty => false,
            VisitChildrenSet::Set(children_to_visit) => {
                children_to_visit.contains(basename)
            }
        }
    }

    /// Returns whether all child entries of the filesystem directory have a
    /// corresponding dirstate node or are ignored.
    fn traverse_fs_directory_and_dirstate<'ancestor>(
        &self,
        has_ignored_ancestor: &'ancestor HasIgnoredAncestor<'ancestor>,
        dirstate_nodes: ChildNodesRef<'tree, 'on_disk>,
        directory_hg_path: &BorrowedPath<'tree, 'on_disk>,
        directory_entry: &DirEntry,
        cached_directory_mtime: Option<TruncatedTimestamp>,
        is_at_repo_root: bool,
    ) -> Result<bool, DirstateV2ParseError> {
        let children_set = self.matcher.visit_children_set(directory_hg_path);
        if let VisitChildrenSet::Empty = children_set {
            return Ok(false);
        }
        if self.can_skip_fs_readdir(directory_entry, cached_directory_mtime) {
            dirstate_nodes
                .par_iter()
                .map(|dirstate_node| {
                    let fs_path = &directory_entry.fs_path;
                    let basename =
                        dirstate_node.base_name(self.dmap.on_disk)?.as_bytes();
                    let fs_path = fs_path.join(get_path_from_bytes(basename));
                    if !Self::should_visit(
                        &children_set,
                        HgPath::new(basename),
                    ) {
                        return Ok(());
                    }
                    match std::fs::symlink_metadata(&fs_path) {
                        Ok(fs_metadata) => {
                            let file_type = fs_metadata.file_type().into();
                            let entry = DirEntry {
                                hg_path: Cow::Borrowed(
                                    dirstate_node
                                        .full_path(self.dmap.on_disk)?,
                                ),
                                fs_path: Cow::Borrowed(&fs_path),
                                symlink_metadata: Some(fs_metadata),
                                file_type,
                            };
                            self.traverse_fs_and_dirstate(
                                &entry,
                                dirstate_node,
                                has_ignored_ancestor,
                            )
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                            self.traverse_dirstate_only(dirstate_node)
                        }
                        Err(error) => {
                            let hg_path =
                                dirstate_node.full_path(self.dmap.on_disk)?;
                            self.io_error(error, hg_path);
                            Ok(())
                        }
                    }
                })
                .collect::<Result<(), _>>()?;

            // We don’t know, so conservatively say this isn’t the case
            let children_all_have_dirstate_node_or_are_ignored = false;

            return Ok(children_all_have_dirstate_node_or_are_ignored);
        }

        let readdir_succeeded;
        let mut fs_entries = if let Ok(entries) = self.read_dir(
            directory_hg_path,
            &directory_entry.fs_path,
            is_at_repo_root,
        ) {
            readdir_succeeded = true;
            entries
        } else {
            // Treat an unreadable directory (typically because of insufficient
            // permissions) like an empty directory. `self.read_dir` has
            // already called `self.io_error` so a warning will be emitted.
            // We still need to remember that there was an error so that we
            // know not to cache this result.
            readdir_succeeded = false;
            Vec::new()
        };

        // `merge_join_by` requires both its input iterators to be sorted:

        let dirstate_nodes = dirstate_nodes.sorted();
        // `sort_unstable_by_key` doesn’t allow keys borrowing from the value:
        // https://github.com/rust-lang/rust/issues/34162
        fs_entries.sort_unstable_by(|e1, e2| e1.hg_path.cmp(&e2.hg_path));

        // Propagate here any error that would happen inside the comparison
        // callback below
        for dirstate_node in &dirstate_nodes {
            dirstate_node.base_name(self.dmap.on_disk)?;
        }
        itertools::merge_join_by(
            dirstate_nodes,
            &fs_entries,
            |dirstate_node, fs_entry| {
                // This `unwrap` never panics because we already propagated
                // those errors above
                dirstate_node
                    .base_name(self.dmap.on_disk)
                    .unwrap()
                    .cmp(&fs_entry.hg_path)
            },
        )
        .par_bridge()
        .map(|pair| {
            use itertools::EitherOrBoth::*;
            let basename = match &pair {
                Left(dirstate_node) | Both(dirstate_node, _) => HgPath::new(
                    dirstate_node.base_name(self.dmap.on_disk)?.as_bytes(),
                ),
                Right(fs_entry) => &fs_entry.hg_path,
            };
            if !Self::should_visit(&children_set, basename) {
                return Ok(false);
            }
            let has_dirstate_node_or_is_ignored = match pair {
                Both(dirstate_node, fs_entry) => {
                    self.traverse_fs_and_dirstate(
                        fs_entry,
                        dirstate_node,
                        has_ignored_ancestor,
                    )?;
                    true
                }
                Left(dirstate_node) => {
                    self.traverse_dirstate_only(dirstate_node)?;
                    true
                }
                Right(fs_entry) => self.traverse_fs_only(
                    has_ignored_ancestor.force(&self.ignore_fn),
                    directory_hg_path,
                    fs_entry,
                ),
            };
            Ok(has_dirstate_node_or_is_ignored)
        })
        .try_reduce(|| true, |a, b| Ok(a && b))
        .map(|res| res && readdir_succeeded)
    }

    fn traverse_fs_and_dirstate<'ancestor>(
        &self,
        fs_entry: &DirEntry,
        dirstate_node: NodeRef<'tree, 'on_disk>,
        has_ignored_ancestor: &'ancestor HasIgnoredAncestor<'ancestor>,
    ) -> Result<(), DirstateV2ParseError> {
        let outdated_dircache =
            self.check_for_outdated_directory_cache(&dirstate_node)?;
        let hg_path = &dirstate_node.full_path_borrowed(self.dmap.on_disk)?;
        let file_or_symlink = fs_entry.is_file() || fs_entry.is_symlink();
        if !file_or_symlink {
            // If we previously had a file here, it was removed (with
            // `hg rm` or similar) or deleted before it could be
            // replaced by a directory or something else.
            self.mark_removed_or_deleted_if_file(&dirstate_node)?;
        }
        if let Some(bad_type) = fs_entry.is_bad() {
            if self.matcher.exact_match(hg_path) {
                let path = dirstate_node.full_path(self.dmap.on_disk)?;
                self.outcome.lock().unwrap().bad.push((
                    path.to_owned().into(),
                    BadMatch::BadType(bad_type),
                ))
            }
        }
        if fs_entry.is_dir() {
            if self.options.collect_traversed_dirs {
                self.outcome
                    .lock()
                    .unwrap()
                    .traversed
                    .push(hg_path.detach_from_tree())
            }
            let is_ignored = HasIgnoredAncestor::create(
                Some(has_ignored_ancestor),
                hg_path,
            );
            let is_at_repo_root = false;
            let children_all_have_dirstate_node_or_are_ignored = self
                .traverse_fs_directory_and_dirstate(
                    &is_ignored,
                    dirstate_node.children(self.dmap.on_disk)?,
                    hg_path,
                    fs_entry,
                    dirstate_node.cached_directory_mtime()?,
                    is_at_repo_root,
                )?;
            self.maybe_save_directory_mtime(
                children_all_have_dirstate_node_or_are_ignored,
                fs_entry,
                dirstate_node,
                outdated_dircache,
            )?
        } else {
            if file_or_symlink && self.matcher.matches(hg_path) {
                if let Some(entry) = dirstate_node.entry()? {
                    if !entry.any_tracked() {
                        // Forward-compat if we start tracking unknown/ignored
                        // files for caching reasons
                        self.mark_unknown_or_ignored(
                            has_ignored_ancestor.force(&self.ignore_fn),
                            hg_path,
                        );
                    }
                    if entry.added() {
                        self.push_outcome(Outcome::Added, &dirstate_node)?;
                    } else if entry.removed() {
                        self.push_outcome(Outcome::Removed, &dirstate_node)?;
                    } else if entry.modified() {
                        self.push_outcome(Outcome::Modified, &dirstate_node)?;
                    } else {
                        self.handle_normal_file(&dirstate_node, fs_entry)?;
                    }
                } else {
                    // `node.entry.is_none()` indicates a "directory"
                    // node, but the filesystem has a file
                    self.mark_unknown_or_ignored(
                        has_ignored_ancestor.force(&self.ignore_fn),
                        hg_path,
                    );
                }
            }

            for child_node in dirstate_node.children(self.dmap.on_disk)?.iter()
            {
                self.traverse_dirstate_only(child_node)?
            }
        }
        Ok(())
    }

    /// Save directory mtime if applicable.
    ///
    /// `outdated_directory_cache` is `true` if we've just invalidated the
    /// cache for this directory in `check_for_outdated_directory_cache`,
    /// which forces the update.
    fn maybe_save_directory_mtime(
        &self,
        children_all_have_dirstate_node_or_are_ignored: bool,
        directory_entry: &DirEntry,
        dirstate_node: NodeRef<'tree, 'on_disk>,
        outdated_directory_cache: bool,
    ) -> Result<(), DirstateV2ParseError> {
        if !children_all_have_dirstate_node_or_are_ignored {
            return Ok(());
        }
        // All filesystem directory entries from `read_dir` have a
        // corresponding node in the dirstate, so we can reconstitute the
        // names of those entries without calling `read_dir` again.

        // TODO: use let-else here and below when available:
        // https://github.com/rust-lang/rust/issues/87335
        let status_start = if let Some(status_start) =
            &self.filesystem_time_at_status_start
        {
            status_start
        } else {
            return Ok(());
        };

        // Although the Rust standard library’s `SystemTime` type
        // has nanosecond precision, the times reported for a
        // directory’s (or file’s) modified time may have lower
        // resolution based on the filesystem (for example ext3
        // only stores integer seconds), kernel (see
        // https://stackoverflow.com/a/14393315/1162888), etc.
        let metadata = match directory_entry.symlink_metadata() {
            Ok(meta) => meta,
            Err(_) => return Ok(()),
        };

        let directory_mtime = match TruncatedTimestamp::for_reliable_mtime_of(
            &metadata,
            status_start,
        ) {
            Ok(Some(directory_mtime)) => directory_mtime,
            Ok(None) => {
                // The directory was modified too recently,
                // don’t cache its `read_dir` results.
                //
                // 1. A change to this directory (direct child was added or
                //    removed) cause its mtime to be set (possibly truncated)
                //    to `directory_mtime`
                // 2. This `status` algorithm calls `read_dir`
                // 3. An other change is made to the same directory is made so
                //    that calling `read_dir` agin would give different
                //    results, but soon enough after 1. that the mtime stays
                //    the same
                //
                // On a system where the time resolution poor, this
                // scenario is not unlikely if all three steps are caused
                // by the same script.
                return Ok(());
            }
            Err(_) => {
                // OS/libc does not support mtime?
                return Ok(());
            }
        };
        // We’ve observed (through `status_start`) that time has
        // “progressed” since `directory_mtime`, so any further
        // change to this directory is extremely likely to cause a
        // different mtime.
        //
        // Having the same mtime again is not entirely impossible
        // since the system clock is not monotonous. It could jump
        // backward to some point before `directory_mtime`, then a
        // directory change could potentially happen during exactly
        // the wrong tick.
        //
        // We deem this scenario (unlike the previous one) to be
        // unlikely enough in practice.

        let is_up_to_date = if let Some(cached) =
            dirstate_node.cached_directory_mtime()?
        {
            !outdated_directory_cache && cached.likely_equal(directory_mtime)
        } else {
            false
        };
        if !is_up_to_date {
            let hg_path = dirstate_node
                .full_path_borrowed(self.dmap.on_disk)?
                .detach_from_tree();
            self.new_cacheable_directories
                .lock()
                .unwrap()
                .push((hg_path, directory_mtime))
        }
        Ok(())
    }

    /// A file that is clean in the dirstate was found in the filesystem
    fn handle_normal_file(
        &self,
        dirstate_node: &NodeRef<'tree, 'on_disk>,
        fs_entry: &DirEntry,
    ) -> Result<(), DirstateV2ParseError> {
        // Keep the low 31 bits
        fn truncate_u64(value: u64) -> i32 {
            (value & 0x7FFF_FFFF) as i32
        }

        let fs_metadata = match fs_entry.symlink_metadata() {
            Ok(meta) => meta,
            Err(_) => return Ok(()),
        };

        let entry = dirstate_node
            .entry()?
            .expect("handle_normal_file called with entry-less node");
        let mode_changed =
            || self.options.check_exec && entry.mode_changed(&fs_metadata);
        let size = entry.size();
        let size_changed = size != truncate_u64(fs_metadata.len());
        if size >= 0 && size_changed && fs_metadata.file_type().is_symlink() {
            // issue6456: Size returned may be longer due to encryption
            // on EXT-4 fscrypt. TODO maybe only do it on EXT4?
            self.push_outcome(Outcome::Unsure, dirstate_node)?
        } else if dirstate_node.has_copy_source()
            || entry.is_from_other_parent()
            || (size >= 0 && (size_changed || mode_changed()))
        {
            self.push_outcome(Outcome::Modified, dirstate_node)?
        } else {
            let mtime_looks_clean = if let Some(dirstate_mtime) =
                entry.truncated_mtime()
            {
                let fs_mtime = TruncatedTimestamp::for_mtime_of(&fs_metadata)
                    .expect("OS/libc does not support mtime?");
                // There might be a change in the future if for example the
                // internal clock become off while process run, but this is a
                // case where the issues the user would face
                // would be a lot worse and there is nothing we
                // can really do.
                fs_mtime.likely_equal(dirstate_mtime)
            } else {
                // No mtime in the dirstate entry
                false
            };
            if !mtime_looks_clean {
                self.push_outcome(Outcome::Unsure, dirstate_node)?
            } else if self.options.list_clean {
                self.push_outcome(Outcome::Clean, dirstate_node)?
            }
        }
        Ok(())
    }

    /// A node in the dirstate tree has no corresponding filesystem entry
    fn traverse_dirstate_only(
        &self,
        dirstate_node: NodeRef<'tree, 'on_disk>,
    ) -> Result<(), DirstateV2ParseError> {
        self.check_for_outdated_directory_cache(&dirstate_node)?;
        self.mark_removed_or_deleted_if_file(&dirstate_node)?;
        dirstate_node
            .children(self.dmap.on_disk)?
            .par_iter()
            .map(|child_node| self.traverse_dirstate_only(child_node))
            .collect()
    }

    /// A node in the dirstate tree has no corresponding *file* on the
    /// filesystem
    ///
    /// Does nothing on a "directory" node
    fn mark_removed_or_deleted_if_file(
        &self,
        dirstate_node: &NodeRef<'tree, 'on_disk>,
    ) -> Result<(), DirstateV2ParseError> {
        if let Some(entry) = dirstate_node.entry()? {
            if !entry.any_tracked() {
                // Future-compat for when we start storing ignored and unknown
                // files for caching reasons
                return Ok(());
            }
            let path = dirstate_node.full_path(self.dmap.on_disk)?;
            if self.matcher.matches(path) {
                if entry.removed() {
                    self.push_outcome(Outcome::Removed, dirstate_node)?
                } else {
                    self.push_outcome(Outcome::Deleted, dirstate_node)?
                }
            }
        }
        Ok(())
    }

    /// Something in the filesystem has no corresponding dirstate node
    ///
    /// Returns whether that path is ignored
    fn traverse_fs_only(
        &self,
        has_ignored_ancestor: bool,
        directory_hg_path: &HgPath,
        fs_entry: &DirEntry,
    ) -> bool {
        let hg_path = directory_hg_path.join(&fs_entry.hg_path);
        let file_or_symlink = fs_entry.is_file() || fs_entry.is_symlink();
        if fs_entry.is_dir() {
            let is_ignored =
                has_ignored_ancestor || (self.ignore_fn)(&hg_path);
            let traverse_children = if is_ignored {
                // Descendants of an ignored directory are all ignored
                self.options.list_ignored
            } else {
                // Descendants of an unknown directory may be either unknown or
                // ignored
                self.options.list_unknown || self.options.list_ignored
            };
            if traverse_children {
                let is_at_repo_root = false;
                if let Ok(children_fs_entries) =
                    self.read_dir(&hg_path, &fs_entry.fs_path, is_at_repo_root)
                {
                    children_fs_entries.par_iter().for_each(|child_fs_entry| {
                        self.traverse_fs_only(
                            is_ignored,
                            &hg_path,
                            child_fs_entry,
                        );
                    })
                }
                if self.options.collect_traversed_dirs {
                    self.outcome.lock().unwrap().traversed.push(hg_path.into())
                }
            }
            is_ignored
        } else if file_or_symlink {
            if self.matcher.matches(&hg_path) {
                self.mark_unknown_or_ignored(
                    has_ignored_ancestor,
                    &BorrowedPath::InMemory(&hg_path),
                )
            } else {
                // We haven’t computed whether this path is ignored. It
                // might not be, and a future run of status might have a
                // different matcher that matches it. So treat it as not
                // ignored. That is, inhibit readdir caching of the parent
                // directory.
                false
            }
        } else {
            // This is neither a directory, a plain file, or a symlink.
            // Treat it like an ignored file.
            true
        }
    }

    /// Returns whether that path is ignored
    fn mark_unknown_or_ignored(
        &self,
        has_ignored_ancestor: bool,
        hg_path: &BorrowedPath<'_, 'on_disk>,
    ) -> bool {
        let is_ignored = has_ignored_ancestor || (self.ignore_fn)(hg_path);
        if is_ignored {
            if self.options.list_ignored {
                self.push_outcome_without_copy_source(
                    Outcome::Ignored,
                    hg_path,
                )
            }
        } else if self.options.list_unknown {
            self.push_outcome_without_copy_source(Outcome::Unknown, hg_path)
        }
        is_ignored
    }
}

/// Since [`std::fs::FileType`] cannot be built directly, we emulate what we
/// care about.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
enum FakeFileType {
    File,
    Directory,
    Symlink,
    BadType(BadType),
}

impl From<std::fs::FileType> for FakeFileType {
    fn from(f: std::fs::FileType) -> Self {
        if f.is_dir() {
            Self::Directory
        } else if f.is_file() {
            Self::File
        } else if f.is_symlink() {
            Self::Symlink
        } else if f.is_fifo() {
            Self::BadType(BadType::FIFO)
        } else if f.is_block_device() {
            Self::BadType(BadType::BlockDevice)
        } else if f.is_char_device() {
            Self::BadType(BadType::CharacterDevice)
        } else if f.is_socket() {
            Self::BadType(BadType::Socket)
        } else {
            Self::BadType(BadType::Unknown)
        }
    }
}

struct DirEntry<'a> {
    /// Path as stored in the dirstate, or just the filename for optimization.
    hg_path: HgPathCow<'a>,
    /// Filesystem path
    fs_path: Cow<'a, Path>,
    /// Lazily computed
    symlink_metadata: Option<std::fs::Metadata>,
    /// Already computed for ergonomics.
    file_type: FakeFileType,
}

impl<'a> DirEntry<'a> {
    /// Returns **unsorted** entries in the given directory, with name,
    /// metadata and file type.
    ///
    /// If a `.hg` sub-directory is encountered:
    ///
    /// * At the repository root, ignore that sub-directory
    /// * Elsewhere, we’re listing the content of a sub-repo. Return an empty
    ///   list instead.
    fn read_dir(path: &Path, is_at_repo_root: bool) -> io::Result<Vec<Self>> {
        // `read_dir` returns a "not found" error for the empty path
        let at_cwd = path == Path::new("");
        let read_dir_path = if at_cwd { Path::new(".") } else { path };
        let mut results = Vec::new();
        for entry in read_dir_path.read_dir()? {
            let entry = entry?;
            let file_type = match entry.file_type() {
                Ok(v) => v,
                Err(e) => {
                    // race with file deletion?
                    if e.kind() == std::io::ErrorKind::NotFound {
                        continue;
                    } else {
                        return Err(e);
                    }
                }
            };
            let file_name = entry.file_name();
            // FIXME don't do this when cached
            if file_name == ".hg" {
                if is_at_repo_root {
                    // Skip the repo’s own .hg (might be a symlink)
                    continue;
                } else if file_type.is_dir() {
                    // A .hg sub-directory at another location means a subrepo,
                    // skip it entirely.
                    return Ok(Vec::new());
                }
            }
            let full_path = if at_cwd {
                file_name.clone().into()
            } else {
                entry.path()
            };
            let filename =
                Cow::Owned(get_bytes_from_os_string(file_name).into());
            let file_type = FakeFileType::from(file_type);
            results.push(DirEntry {
                hg_path: filename,
                fs_path: Cow::Owned(full_path.to_path_buf()),
                symlink_metadata: None,
                file_type,
            })
        }
        Ok(results)
    }

    fn symlink_metadata(&self) -> Result<std::fs::Metadata, std::io::Error> {
        match &self.symlink_metadata {
            Some(meta) => Ok(meta.clone()),
            None => std::fs::symlink_metadata(&self.fs_path),
        }
    }

    fn is_dir(&self) -> bool {
        self.file_type == FakeFileType::Directory
    }

    fn is_file(&self) -> bool {
        self.file_type == FakeFileType::File
    }

    fn is_symlink(&self) -> bool {
        self.file_type == FakeFileType::Symlink
    }

    fn is_bad(&self) -> Option<BadType> {
        match self.file_type {
            FakeFileType::BadType(ty) => Some(ty),
            _ => None,
        }
    }
}
