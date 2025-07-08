//! Tools for moving the repository to a given revision

use std::collections::HashSet;
use std::fs::Permissions;
use std::io::Write;
use std::ops::Deref;
use std::os::unix::fs::MetadataExt;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::time::Duration;

use crossbeam_channel::Receiver;
use crossbeam_channel::Sender;
use rayon::prelude::*;

use crate::checkexec::check_exec;
use crate::checkexec::is_executable;
use crate::dirstate::dirstate_map::DirstateEntryReset;
use crate::dirstate::dirstate_map::DirstateMap;
use crate::dirstate::entry::ParentFileData;
use crate::dirstate::entry::TruncatedTimestamp;
use crate::dirstate::on_disk::write_tracked_key;
use crate::errors::HgError;
use crate::errors::HgResultExt;
use crate::errors::IoResultExt;
use crate::exit_codes;
use crate::matchers::Matcher;
use crate::narrow;
use crate::operations::list_rev_tracked_files;
use crate::operations::ExpandedManifestEntry;
use crate::operations::FilesForRevBorrowed;
use crate::progress::Progress;
use crate::repo::Repo;
use crate::revlog::filelog::is_file_modified;
use crate::revlog::filelog::FileCompOutcome;
use crate::revlog::filelog::Filelog;
use crate::revlog::manifest::Manifest;
use crate::revlog::manifest::ManifestFlags;
use crate::revlog::node::NULL_NODE;
use crate::revlog::options::default_revlog_options;
use crate::revlog::options::RevlogOpenOptions;
use crate::revlog::path_encode::PathEncoding;
use crate::revlog::RevlogType;
use crate::sparse;
use crate::utils::cap_default_rayon_threads;
use crate::utils::files::filesystem_now;
use crate::utils::files::find_dirs_recursive_no_root;
use crate::utils::files::get_path_from_bytes;
use crate::utils::hg_path::hg_path_to_path_buf;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathErrorKind;
use crate::utils::path_auditor::check_filesystem_single;
use crate::utils::path_auditor::PathAuditor;
use crate::vfs::get_umask;
use crate::vfs::is_on_nfs_mount;
use crate::vfs::Vfs;
use crate::vfs::VfsImpl;
use crate::warnings::HgWarningSender;
use crate::DirstateParents;
use crate::Node;
use crate::Revision;
use crate::UncheckedRevision;
use crate::INTERRUPT_RECEIVED;

/// Write the dirstate to disk and update the tracked key if needed
fn write_dirstate(repo: &Repo, tracked_change: bool) -> Result<(), HgError> {
    repo.write_dirstate()
        .map_err(|e| HgError::abort(e.to_string(), exit_codes::ABORT, None))?;
    if tracked_change {
        write_tracked_key(repo)
    } else {
        Ok(())
    }
}

/// What kind of update we're doing
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum UpdateKind {
    /// All tracked files are clean, but there can be unknown/ignored files
    FromClean,
    /// We're starting from the null revision and the working copy is empty
    /// save for the `.hg` folder.
    FromNull,
}

/// A clutch to be used to pass down relevant config items from Python that
/// may have been set through the CLI and thus be inaccessible from Rust.
///
/// TODO remove this once the Python config object is backed by Rust code.
#[derive(Debug)]
pub struct UpdateConfig {
    /// `worker.numcpus` if `worker.enabled`
    pub workers: Option<usize>,
    /// `experimental.removeemptydirs`
    pub remove_empty_dirs: bool,
    /// `devel.update.abort-on-dirstate-change`
    pub devel_abort_dirstate: bool,
    /// `ui.origbackuppath`
    pub orig_backup_path: Option<Vec<u8>>,
    /// `experimental.update.atomic-file`
    pub atomic_file: bool,
}

/// Update the current working copy of `repo` to the given revision `to`, from
/// the null revision and set + write out the dirstate to reflect that.
///
/// Do not call this outside of a Python context. This does *not* handle any
/// of the checks, hooks, lock taking needed to setup and get out of this
/// update from the null revision.
#[tracing::instrument(level = "debug", skip_all)]
pub fn update_from_null(
    repo: &Repo,
    to: UncheckedRevision,
    progress: &dyn Progress,
    update_config: &UpdateConfig,
    warnings: &HgWarningSender,
) -> Result<UpdateStats, HgError> {
    let narrow_matcher = narrow::matcher(repo, warnings)?;

    let files_for_rev = list_rev_tracked_files(repo, to, narrow_matcher)?;
    repo.manually_set_parents(DirstateParents {
        p1: repo.node(to).expect("update target should exist"),
        p2: NULL_NODE,
    })?;

    // Filter the working copy according to the sparse spec
    let tracked_files: Result<Vec<_>, HgError> = if !repo.has_sparse() {
        files_for_rev
            .iter()
            .map(|e| Ok(WorkingCopyFileUpdate { entry: e?, backup: false }))
            .collect()
    } else {
        let sparse_matcher = sparse::matcher(repo, None, warnings)?;
        files_for_rev
            .iter()
            .filter(|f| {
                match f {
                    Ok(f) => sparse_matcher.matches(f.0),
                    Err(_) => true, // Errors stop the update, include them
                }
            })
            .map(|e| Ok(WorkingCopyFileUpdate { entry: e?, backup: false }))
            .collect()
    };
    let tracked_files = tracked_files?;

    if tracked_files.is_empty() {
        // Still write the dirstate because we might not be in the null
        // revision.
        // This can happen in narrow repos where all paths are excluded in
        // this revision.
        // We stay on the safe side and pass in `tracked_change=true`, because
        // this is exceptionally niche.
        write_dirstate(repo, true)?;
        return Ok(UpdateStats::default());
    }
    let store_vfs = &repo.store_vfs();
    let options = default_revlog_options(
        repo.config(),
        repo.requirements(),
        crate::revlog::RevlogType::Filelog,
    )?;
    let (errors_sender, errors_receiver) = crossbeam_channel::unbounded();
    let (files_sender, files_receiver) = crossbeam_channel::unbounded();

    let files_count = tracked_files.len();
    let (symlinks, chunks) = chunk_tracked_files(tracked_files, true);
    progress.update(0, Some(files_count as u64));

    // TODO find a way (with `nix` or `signal-hook`?) of resetting the
    // previous signal handler directly after. Currently, this is Python's
    // job, but:
    //     - it introduces a (small) race between catching and resetting
    //     - it would break signal handlers in other contexts like `rhg``
    let _ = ctrlc::set_handler(|| {
        INTERRUPT_RECEIVED.store(true, Ordering::Relaxed)
    });

    create_working_copy(
        chunks,
        symlinks,
        &repo.working_directory_vfs(),
        store_vfs,
        options,
        &files_sender,
        &errors_sender,
        progress,
        update_config,
    );
    drop(files_sender);

    // Reset the global interrupt now that we're done
    if INTERRUPT_RECEIVED.swap(false, Ordering::Relaxed) {
        tracing::warn!("Interrupt received, aborting the update");
        // The threads have all exited early, let's re-raise
        return Err(HgError::InterruptReceived);
    }

    drop(errors_sender);
    let errors: Vec<HgError> = errors_receiver.iter().collect();
    if !errors.is_empty() {
        tracing::debug!(
            "{} errors during update (see trace logs)",
            errors.len()
        );
        for error in errors.iter() {
            tracing::trace!("{}", error);
        }
        // Best we can do is raise the first error (in order of the channel)
        return Err(errors.into_iter().next().expect("can never be empty"));
    }

    // TODO try to run this concurrently to update the dirstate while we're
    // still writing out the working copy to see if that improves performance.
    let total = update_dirstate(
        repo,
        files_receiver,
        None,
        update_config.devel_abort_dirstate,
        UpdateKind::FromNull,
    )?;

    write_dirstate(repo, true)?;

    Ok(total)
}

/// Update the current working copy of `repo` to the given revision `to`, from
/// an arbitrary revision with clean tracked files, and set + write out the
/// dirstate to reflect that.
///
/// Do not call this outside of a Python context. This does *not* handle any
/// of the checks, hooks, lock taking needed to setup and get out of this
/// update.
#[allow(clippy::too_many_arguments)]
#[tracing::instrument(level = "debug", skip_all)]
pub fn update_from_clean(
    repo: &Repo,
    wc_manifest_bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    target_node: Node,
    target_rev: Revision,
    target_manifest_bytes: Box<dyn Deref<Target = [u8]> + Send + Sync>,
    progress: &dyn Progress,
    update_config: &UpdateConfig,
    warnings: &HgWarningSender,
) -> Result<UpdateStats, HgError> {
    let wc_manifest = Manifest::from_bytes(wc_manifest_bytes);
    let target_manifest = Manifest::from_bytes(target_manifest_bytes);

    let narrow_matcher = narrow::matcher(repo, warnings)?;
    let sparse_matcher =
        sparse::matcher(repo, Some(vec![target_rev]), warnings)?;

    let (errors_sender, errors_receiver) = crossbeam_channel::unbounded();

    let narrow_matcher = narrow_matcher.as_ref();
    let actions = compute_actions(
        repo,
        &wc_manifest,
        &target_manifest,
        &narrow_matcher,
        &sparse_matcher.as_ref(),
        warnings,
    )?;

    progress.update(0, Some(actions.len() as u64));
    repo.manually_set_parents(DirstateParents {
        p1: target_node,
        p2: NULL_NODE,
    })?;

    let (file_updates_sender, file_updates_receiver) =
        crossbeam_channel::unbounded();
    let (removals_sender, removals_receiver) = crossbeam_channel::unbounded();

    apply_actions(
        repo,
        actions,
        progress,
        file_updates_sender,
        removals_sender,
        &errors_sender,
        warnings,
        update_config,
    )?;

    drop(errors_sender);
    let errors: Vec<HgError> = errors_receiver.iter().collect();
    if !errors.is_empty() {
        tracing::debug!(
            "{} errors during update (see trace logs)",
            errors.len()
        );
        for error in errors.iter() {
            tracing::trace!("{}", error);
        }
        // Best we can do is raise the first error (in order of the channel)
        return Err(errors.into_iter().next().expect("can never be empty"));
    }

    // TODO try to run this concurrently to update the dirstate while we're
    // still writing out the working copy to see if that improves performance.
    let stats = update_dirstate(
        repo,
        file_updates_receiver,
        Some(removals_receiver),
        update_config.devel_abort_dirstate,
        UpdateKind::FromClean,
    )?;

    let changed_tracked_set = stats.removed > 0 || stats.added > 0;
    write_dirstate(repo, changed_tracked_set)?;

    Ok(stats)
}

/// Statistics about the update we've just done
#[derive(Debug, Default)]
pub struct UpdateStats {
    /// The number of files that were added
    pub added: usize,
    /// The number of files that were updated without merge
    pub updated: usize,
    /// The number of files that were merged
    pub merged: usize,
    /// The number of files that were removed
    pub removed: usize,
    /// The number of files that were left unresolved
    pub unresolved: usize,
}

/// Represents an update to be applied to the working copy
#[derive(Debug, PartialEq)]
pub struct WorkingCopyFileUpdate<'a> {
    /// The manifest entry metadata from which to get the file information
    entry: ExpandedManifestEntry<'a>,
    /// Whether to backup this path before trying to update it
    backup: bool,
}

/// Represents the actions to take on the working copy for an update
#[derive(Debug)]
pub struct MergeActions<'a> {
    /// Files whose only flags have changed (exec or link toggled either way)
    pub flags: Vec<(&'a HgPath, ManifestFlags)>,
    /// Files that need to be updated
    pub get: Vec<WorkingCopyFileUpdate<'a>>,
    /// Files that need to be created
    pub create: Vec<ExpandedManifestEntry<'a>>,
    /// Files that need to be removed
    pub remove: Vec<&'a HgPath>,
}

impl<'paths> MergeActions<'paths> {
    fn new() -> Self {
        Self {
            flags: vec![],
            get: vec![],
            create: vec![],
            remove: vec![],
            // Adjust [`Self::len`] and [`Self::files`] when changing fields!
        }
    }
    pub fn len(&self) -> usize {
        self.flags.len()
            + self.get.len()
            + self.create.len()
            + self.remove.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Retains files for which `retain_fn` returns `true`
    pub fn retain_files(
        &mut self,
        mut retain_fn: impl FnMut(&'paths HgPath) -> bool,
    ) {
        self.flags.retain(|item| retain_fn(item.0));
        self.get.retain(|item| retain_fn(item.path()));
        self.create.retain(|item| retain_fn(item.0));
        self.remove.retain(|item| retain_fn(item));
    }
}

/// Change the file to a symlink or set executable permissions, if any flag
/// information asks for it, and return the mode, size and mtime for exec
/// file changes.
pub fn apply_flags_to_file(
    path: &Path,
    flags: ManifestFlags,
) -> Result<Option<(u32, usize, TruncatedTimestamp)>, HgError> {
    let meta = path.symlink_metadata().when_reading_file(path)?;
    let flags_link = flags.is_link();
    let disk_link = meta.is_symlink();
    let flags_exec = flags.is_exec();
    let disk_exec = is_executable(&meta);

    if flags_link && !disk_link {
        // Switch file to link
        let contents = std::fs::read(path).when_reading_file(path)?;
        std::fs::remove_file(path).when_writing_file(path)?;
        let target = get_path_from_bytes(&contents);
        if std::os::unix::fs::symlink(target, path)
            .when_writing_file(path)
            .is_err()
        {
            // failed to create the link, rewrite the file
            std::fs::write(path, contents).when_writing_file(path)?;
            return Ok(None);
        }

        return Ok(None);
    }
    if !flags_link && disk_link {
        // Switch link to file
        let target = std::fs::read_link(path).when_reading_file(path)?;
        std::fs::remove_file(path).when_writing_file(path)?;
        std::os::unix::fs::symlink(target, path).when_writing_file(path)?;
    }
    if meta.nlink() > 1 && flags_exec != disk_exec {
        // The file is a hardlink, break it
        let contents = std::fs::read(path).when_reading_file(path)?;
        std::fs::remove_file(path).when_writing_file(path)?;
        std::fs::write(path, contents).when_writing_file(path)?;
    }

    let mode = meta.mode();

    let mode = if flags_exec && !disk_exec {
        // Turn on +x for every +r bit when making a file executable
        // and obey umask.
        let mode = mode | ((mode & 0o444) >> 2) & !get_umask();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
            .when_writing_file(path)?;
        Some(mode)
    } else if !flags_exec && disk_exec {
        // Turn off all +x bits
        let mode = mode & 0o666;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
            .when_writing_file(path)?;
        Some(mode)
    } else {
        None
    };
    let truncated_timestamp =
        TruncatedTimestamp::for_mtime_of(&meta).when_reading_file(path)?;
    Ok(mode.map(|mode| {
        (
            mode,
            meta.len().try_into().expect("file too large"),
            truncated_timestamp,
        )
    }))
}

fn working_copy_remove(
    path: impl AsRef<Path>,
    vfs: &impl Vfs,
    remove_empty_dirs: bool,
) -> Result<(), HgError> {
    vfs.unlink(path.as_ref())?;
    if remove_empty_dirs {
        let path = vfs.base().join(path.as_ref());

        let mut current = path;
        while let Some(Ok(parent)) = current.parent().map(|p| p.canonicalize())
        {
            if vfs.base() == parent {
                break;
            }
            if std::fs::remove_dir(&parent).is_err() {
                break;
            }
            current = parent;
        }
    }
    Ok(())
}

/// Apply the computed `actions` to the working copy.
#[allow(clippy::too_many_arguments)]
#[tracing::instrument(level = "debug", skip_all)]
fn apply_actions<'a: 'b, 'b>(
    repo: &Repo,
    actions: MergeActions<'a>,
    progress: &dyn Progress,
    file_updates: Sender<(&'b HgPath, u32, usize, TruncatedTimestamp)>,
    file_removals: Sender<&'b HgPath>,
    errors: &Sender<HgError>,
    warnings: &HgWarningSender,
    update_config: &UpdateConfig,
) -> Result<(), HgError> {
    let options = default_revlog_options(
        repo.config(),
        repo.requirements(),
        crate::revlog::RevlogType::Filelog,
    )?;
    let working_copy_vfs = repo.working_directory_vfs();
    let auditor = PathAuditor::new(working_copy_vfs.base());

    let work_closure =
        |(_dir, chunk): (&HgPath, Vec<&'a HgPath>)| -> Result<(), HgError> {
            let chunk_size = chunk.len();
            for hg_path in chunk {
                auditor.audit_path(hg_path)?;
                let path = hg_path_to_path_buf(hg_path)?;
                if let Err(e) = working_copy_remove(
                    &path,
                    &working_copy_vfs,
                    update_config.remove_empty_dirs,
                )
                .io_not_found_as_none()
                {
                    warnings.send(UpdateWarning::UnlinkFailure(path, e));
                }
                file_removals.send(hg_path).expect("channel should be open");
            }
            progress.increment(chunk_size as u64, None);
            Ok(())
        };

    let cwd_exists = std::env::current_dir().is_ok();

    let removing_span =
        tracing::span!(tracing::Level::TRACE, "removing files").entered();
    maybe_parallel(
        "update",
        chunk_tracked_files(actions.remove, false).1,
        work_closure,
        update_config.workers,
        errors,
    );
    removing_span.exit();

    if cwd_exists && std::env::current_dir().is_err() {
        // cwd was removed in the course of removing files; print a helpful
        // warning.
        warnings.send(UpdateWarning::CwdRemoved);
    }

    let (symlinks, chunks) = chunk_tracked_files(actions.get, true);
    create_working_copy(
        chunks,
        symlinks,
        &repo.working_directory_vfs(),
        &repo.store_vfs(),
        options,
        &file_updates,
        errors,
        progress,
        update_config,
    );

    // Change flags on any files that only need their flags changed
    for (path, flags) in actions.flags {
        progress.increment(1, None);
        let full_path =
            repo.working_directory_vfs().join(hg_path_to_path_buf(path)?);
        if let Some((mode, size, mtime)) =
            apply_flags_to_file(&full_path, flags)?
        {
            file_updates
                .send((path, mode, size, mtime))
                .expect("channel must be open");
        }
    }

    Ok(())
}

/// Warnings that can occur during the update process
#[derive(Debug)]
pub enum UpdateWarning {
    /// We've failed to remove a file
    UnlinkFailure(PathBuf, HgError),
    /// Current directory was removed
    CwdRemoved,
    /// We have a conflict with an untracked file
    UntrackedConflict(HgPathBuf),
    /// We are replacing a conflicting untracked file
    ReplacingUntracked(HgPathBuf),
}

/// What to do when encountering a file conflict on disk. There is a different
/// config for unknown and ignored files.
#[derive(Copy, Clone, Debug)]
enum FileConflictConfig {
    /// Abort the update process entirely
    Abort,
    /// Warn about each file
    Warn,
    /// Ignore all conflicts
    Ignore,
}

impl FileConflictConfig {
    fn new(config: &str, value: Option<&str>) -> Result<Self, HgError> {
        match value {
            Some("abort") => Ok(Self::Abort),
            Some("warn") => Ok(Self::Warn),
            Some("ignore") => Ok(Self::Ignore),
            _ => Err(HgError::abort(
                format!(
                    "{} not valid, expected 'abort', 'ignore' or 'warn'",
                    config
                ),
                exit_codes::CONFIG_ERROR_ABORT,
                None,
            )),
        }
    }
}

/// Compute what actions need to be taken to update the working copy to the
/// target revision.
#[tracing::instrument(level = "debug", skip_all)]
pub fn compute_actions<
    'manifests,
    'm1: 'manifests,
    'm2: 'manifests,
    'ma: 'manifests,
>(
    repo: &Repo,
    wc_manifest: &'m1 Manifest,
    target_manifest: &'m2 Manifest,
    narrow_matcher: &'m1 impl Matcher,
    sparse_matcher: &impl Matcher,
    warnings: &HgWarningSender,
) -> Result<MergeActions<'manifests>, HgError> {
    let mut actions =
        manifest_actions(wc_manifest, target_manifest, narrow_matcher)?;
    if !actions.create.is_empty() {
        let mut old_gets = std::mem::take(&mut actions.get);
        let file_conflicts =
            check_unknown_files(repo, &actions, target_manifest, warnings)?;

        if file_conflicts.len() >= 100 {
            // There will be few conflicts most of the time, and they are
            // sorted,so only create and use a HashSet if we need to match
            // against many paths.
            let file_conflicts: HashSet<_> =
                file_conflicts.into_iter().collect();
            let new_gets = actions.create.iter().copied().map(|c| {
                let backup = file_conflicts.contains(&c.0);
                WorkingCopyFileUpdate { entry: c, backup }
            });
            old_gets.extend(new_gets);
        } else {
            // This is the same as the other arm, it's just not worth the
            // complexity to build a macro for this, so just copy.
            let new_gets = actions.create.iter().copied().map(|c| {
                let backup = file_conflicts.contains(&c.0);
                WorkingCopyFileUpdate { entry: c, backup }
            });
            old_gets.extend(new_gets);
        }
        actions.get = old_gets;
        // Don't `sort_unstable` since we're in the special case of
        // concatenating two sorted sequences.
        actions.get.sort_by_key(|e| e.entry.0);
    }
    if repo.has_sparse() {
        filter_sparse_actions(
            repo,
            sparse_matcher,
            narrow_matcher,
            target_manifest,
            &mut actions,
            warnings,
        )?;
    }
    Ok(actions)
}

/// Filter actions that would fall outside of the sparse profile
fn filter_sparse_actions<'a>(
    repo: &Repo,
    sparse_matcher: &impl Matcher,
    narrow_matcher: &'a impl Matcher,
    target_manifest: &'a Manifest,
    actions: &mut MergeActions<'a>,
    warnings: &HgWarningSender,
) -> Result<(), HgError> {
    let old_sparse_matcher = sparse::matcher(repo, None, warnings)?;
    if old_sparse_matcher.matches_everything() {
        return Ok(());
    }

    let mut to_remove = vec![];
    let profiles = sparse::active_profiles(repo, warnings)?;
    let mut profile_changed = false;
    actions.retain_files(|path| {
        if !profile_changed && profiles.contains(path.as_bytes()) {
            profile_changed = true
        }
        let matches = sparse_matcher.matches(path);
        if !matches {
            to_remove.push(path);
        }
        matches
    });
    actions.remove.extend(to_remove);
    if profile_changed {
        let mut to_remove = vec![];
        let mut to_get = vec![];
        let files = FilesForRevBorrowed::new(target_manifest, narrow_matcher);
        // If an active profile changed during the update, refresh the checkout
        for entry in files.iter() {
            let (path, node, flags) = entry?;
            let old = old_sparse_matcher.matches(path);
            let new = sparse_matcher.matches(path);
            if !old && new {
                to_get.push(WorkingCopyFileUpdate {
                    entry: (path, node, flags),
                    backup: false,
                });
            } else if old && !new {
                to_remove.push(path);
            }
        }
        actions.get.extend(to_get);
        actions.remove.extend(to_remove);
    }
    Ok(())
}

/// Gathers a list of all unknown (potentially ignored) files and either abort,
/// warn or ignore them depending on the config, and returns that list.
fn check_unknown_files<'a>(
    repo: &Repo,
    merge_result: &'a MergeActions,
    p2_manifest: &Manifest,
    warnings: &HgWarningSender,
) -> Result<Vec<&'a HgPath>, HgError> {
    let owning_dirstate_map = repo.dirstate_map()?;
    let dirstate = owning_dirstate_map.get_map();
    let check_exec = check_exec(repo.working_directory_path());
    let filelog_options = default_revlog_options(
        repo.config(),
        repo.requirements(),
        RevlogType::Filelog,
    )?;
    let (unknown_sender, unknown_receiver) = crossbeam_channel::unbounded();
    let (ignored_sender, ignored_receiver) = crossbeam_channel::unbounded();
    let ignore_func = repo.get_ignore_function(warnings)?;
    let working_directory_vfs = repo.working_directory_vfs();
    let store_vfs = repo.store_vfs();
    merge_result.create.par_iter().try_for_each(
        |(path, _, _)| -> Result<(), HgError> {
            if is_conflicting_unknown_file(
                path,
                dirstate,
                p2_manifest,
                check_exec,
                filelog_options,
                &working_directory_vfs,
                &store_vfs,
            )? {
                if ignore_func(path) {
                    ignored_sender.send(*path).expect("channel must be open");
                } else {
                    unknown_sender.send(*path).expect("channel must be open");
                }
            }
            Ok(())
        },
    )?;
    drop(ignored_sender);
    drop(unknown_sender);
    let mut ignored_conflicts: Vec<&HgPath> =
        ignored_receiver.into_iter().collect();
    let unknown_conflicts: Vec<&HgPath> =
        unknown_receiver.into_iter().collect();

    let ignored_conflict_config =
        repo.config().get_str(b"merge", b"checkignored")?;
    let on_ignored_conflict =
        FileConflictConfig::new("merge.checkignored", ignored_conflict_config)?;
    let unknown_conflict_config =
        repo.config().get_str(b"merge", b"checkunknown")?;
    let on_unknown_conflict =
        FileConflictConfig::new("merge.checkunknown", unknown_conflict_config)?;

    let (mut abort_conflicts, mut warn_conflicts): (
        Vec<&HgPath>,
        Vec<&HgPath>,
    ) = match (on_ignored_conflict, on_unknown_conflict) {
        (FileConflictConfig::Abort, FileConflictConfig::Abort) => (
            ignored_conflicts
                .iter()
                .chain(unknown_conflicts.iter())
                .copied()
                .collect(),
            vec![],
        ),
        (FileConflictConfig::Abort, FileConflictConfig::Warn) => {
            (ignored_conflicts.to_owned(), unknown_conflicts.to_owned())
        }
        (FileConflictConfig::Abort, FileConflictConfig::Ignore) => {
            (ignored_conflicts.to_owned(), vec![])
        }
        (FileConflictConfig::Warn, FileConflictConfig::Abort) => {
            (unknown_conflicts.to_owned(), ignored_conflicts.to_owned())
        }
        (FileConflictConfig::Warn, FileConflictConfig::Warn) => (
            vec![],
            ignored_conflicts
                .iter()
                .chain(unknown_conflicts.iter())
                .copied()
                .collect(),
        ),
        (FileConflictConfig::Warn, FileConflictConfig::Ignore) => {
            (vec![], ignored_conflicts.to_owned())
        }
        (FileConflictConfig::Ignore, FileConflictConfig::Abort) => {
            (unknown_conflicts.to_owned(), vec![])
        }
        (FileConflictConfig::Ignore, FileConflictConfig::Warn) => {
            (vec![], unknown_conflicts.to_owned())
        }
        (FileConflictConfig::Ignore, FileConflictConfig::Ignore) => {
            (vec![], vec![])
        }
    };

    if !abort_conflicts.is_empty() {
        abort_conflicts.sort_unstable();
        for conflict in abort_conflicts {
            let warn = UpdateWarning::UntrackedConflict(conflict.to_owned());
            warnings.send(warn);
        }
        return Err(HgError::abort(
            "untracked files in working directory differ \
            from files in requested revision",
            exit_codes::STATE_ERROR,
            None,
        ));
    }
    if !warn_conflicts.is_empty() {
        warn_conflicts.sort_unstable();
        for conflict in warn_conflicts {
            let warn = UpdateWarning::ReplacingUntracked(conflict.to_owned());
            warnings.send(warn);
        }
    }
    ignored_conflicts.extend(unknown_conflicts);
    // The two vecs are sorted, then concatenated, so use stable sorting.
    ignored_conflicts.sort();
    Ok(ignored_conflicts)
}

/// Whether this path is unknown (or ignored) and conflicts with the update
fn is_conflicting_unknown_file(
    path: &HgPath,
    dirstate: &DirstateMap,
    p2_manifest: &Manifest,
    check_exec: bool,
    filelog_open_options: RevlogOpenOptions,
    wc_vfs: &VfsImpl,
    store_vfs: &VfsImpl,
) -> Result<bool, HgError> {
    Ok(!dirstate.has_node(path)?
        && is_file_or_link_check_dirs(path, wc_vfs).unwrap_or(false)
        // TODO write is_entry_modified to re-use the entry we've already
        // resolved during the diff
        && !matches!(is_file_modified(
            wc_vfs,
            store_vfs,
            check_exec,
            p2_manifest,
            path,
            filelog_open_options,
        )?, FileCompOutcome::Clean | FileCompOutcome::Deleted))
}

/// Whether this path if a file or a symlink, taking care of not traversing
/// symlinks.
fn is_file_or_link_check_dirs(
    path: &HgPath,
    working_directory_vfs: &impl Vfs,
) -> Result<bool, HgError> {
    for dir in find_dirs_recursive_no_root(path) {
        check_filesystem_single(
            working_directory_vfs.base().join(hg_path_to_path_buf(path)?),
            dir,
            path,
        )?;
    }
    let path = working_directory_vfs.base().join(hg_path_to_path_buf(path)?);
    Ok(path.is_file() || path.is_symlink())
}

/// Return the actions to be taken to get from the current manifest to the
/// target manifest.
#[tracing::instrument(level = "debug", skip_all)]
fn manifest_actions<'manifests, 'm1: 'manifests, 'm2: 'manifests>(
    wc_manifest: &'m1 Manifest,
    target_manifest: &'m2 Manifest,
    narrow_matcher: &impl Matcher,
) -> Result<MergeActions<'manifests>, HgError> {
    let diff = wc_manifest.diff(target_manifest)?;

    let mut actions = MergeActions::new();

    for (wc_entry, p2_entry) in diff.into_iter() {
        match (wc_entry, p2_entry) {
            (Some(wc_entry), Some(p2_entry)) => {
                let filename = wc_entry.path;
                let p2_node_id = p2_entry.node_id()?;
                let nodes_equal = wc_entry.node_id()? == p2_node_id;
                let flags_differ = wc_entry.flags != p2_entry.flags;
                if nodes_equal && flags_differ {
                    actions.flags.push((filename, p2_entry.flags));
                } else {
                    actions.get.push(WorkingCopyFileUpdate {
                        entry: (filename, p2_node_id, p2_entry.flags),
                        backup: false,
                    });
                }
            }
            (Some(wc_entry), None) => {
                let filename = wc_entry.path;
                actions.remove.push(filename);
            }
            (None, Some(p2_entry)) => {
                actions.create.push((
                    p2_entry.path,
                    p2_entry.node_id()?,
                    p2_entry.flags,
                ));
            }
            (None, None) => unreachable!("diff missing from both sides"),
        }
    }
    if !narrow_matcher.matches_everything() {
        filter_narrow_actions(narrow_matcher, &mut actions)
    }
    Ok(actions)
}

/// Filters actions that would touch files outside of the narrowspec
fn filter_narrow_actions(matcher: &impl Matcher, actions: &mut MergeActions) {
    actions.retain_files(|file| matcher.matches(file));
}

/// Preallocated size of Vec holding directory contents. This aims at
/// preventing the need for re-allocating the Vec in most cases.
///
/// The value is arbitrarily picked as a little over an average number of files
/// per directory done by looking at a few larger open-source repos.
/// Most of the runtime is IO anyway, so this doesn't matter too much.
const FILES_PER_DIRECTORY: usize = 16;

/// Abstraction over types of path information to help with parallel chunking
pub trait ChunkableItem<'a> {
    /// Returns the path of this item
    fn path(&self) -> &'a HgPath;
    /// Whether this path is a symlink
    fn is_link(&self) -> bool;
}

impl<'a> ChunkableItem<'a> for WorkingCopyFileUpdate<'a> {
    fn path(&self) -> &'a HgPath {
        self.entry.0
    }

    fn is_link(&self) -> bool {
        self.entry.2.is_link()
    }
}

impl<'a> ChunkableItem<'a> for &'a HgPath {
    fn path(&self) -> &'a HgPath {
        self
    }

    fn is_link(&self) -> bool {
        // This impl is made for simpler paths, which don't concern themselves
        // with whether this is a link (file removals and tests).
        false
    }
}

/// Represents a directory with its direct descendants
type DirectoryChunk<'a, T> = (&'a HgPath, Vec<T>);

/// Chunk files per directory prefix, so almost every directory is handled
/// in a separate thread, which works around the FS inode mutex.
/// Chunking less (and doing approximately `files_count`/`threads`) actually
/// ends up being less performant: my hypothesis is `rayon`'s work stealing
/// being more efficient with tasks of varying lengths.
///
/// If `separate_symlinks` is true, the first item of the returned tuple will
/// be the same chunked structure, but only for the symlinks, separate from
/// the normal files. See [`create_working_copy`] for why.
#[tracing::instrument(level = "debug", skip_all)]
fn chunk_tracked_files<'a, T: ChunkableItem<'a>>(
    tracked_files: Vec<T>,
    separate_symlinks: bool,
) -> (Vec<DirectoryChunk<'a, T>>, Vec<DirectoryChunk<'a, T>>) {
    if tracked_files.is_empty() {
        return (vec![], vec![]);
    }
    let files_count = tracked_files.len();
    // TODO don't chunk if we know we'll end up doing it sequentially?
    //      Refactor the heuristic for parallelism somewhere

    let mut chunks = Vec::with_capacity(files_count / FILES_PER_DIRECTORY);
    let mut symlinks = vec![];

    let mut current_chunk = Vec::with_capacity(FILES_PER_DIRECTORY);
    let mut current_symlinks = vec![];
    let mut tracked_files = tracked_files.into_iter().peekable();
    let mut last_directory =
        tracked_files.peek().expect("empty tracked files").path().parent();

    for file_info in tracked_files {
        let current_directory = file_info.path().parent();
        let different_directory = current_directory != last_directory;
        if different_directory {
            if separate_symlinks && !current_symlinks.is_empty() {
                symlinks.push((last_directory, current_symlinks));
                current_symlinks = vec![];
            }
            if !current_chunk.is_empty() {
                chunks.push((last_directory, current_chunk));
                current_chunk = Vec::with_capacity(FILES_PER_DIRECTORY);
            }
        }
        if separate_symlinks && file_info.is_link() {
            current_symlinks.push(file_info);
        } else {
            current_chunk.push(file_info);
        }
        last_directory = current_directory;
    }
    symlinks.push((last_directory, current_symlinks));
    chunks.push((last_directory, current_chunk));
    (symlinks, chunks)
}

/// Run `work_closure` either serially or in parallel depending on its
/// `work_arg`, and the `workers` config.
///
/// Allows the `work_closure` to abort, but does not do anything with the
/// output, the closure should communicate through something like channels.
pub fn maybe_parallel<T: Send>(
    topic: &str,
    work_arg: Vec<T>,
    work_closure: impl Fn(T) -> Result<(), HgError> + Sync + Send,
    mut workers: Option<usize>,
    error_sender: &Sender<HgError>,
) {
    if work_arg.len() < 10 {
        workers = Some(1);
    }
    if let Some(workers) = workers {
        if workers > 1 {
            // Work in parallel, potentially restricting the number of threads
            match rayon::ThreadPoolBuilder::new().num_threads(workers).build() {
                Err(error) => error_sender
                    .send(HgError::abort(
                        error.to_string(),
                        exit_codes::ABORT,
                        None,
                    ))
                    .expect("channel should not be disconnected"),
                Ok(pool) => {
                    tracing::debug!(
                        "restricting {} to {} threads",
                        topic,
                        workers
                    );
                    pool.install(|| {
                        let _ =
                            work_arg.into_par_iter().try_for_each(work_closure);
                    });
                }
            }
        } else {
            // Work sequentially, don't even invoke rayon
            let _ = work_arg.into_iter().try_for_each(work_closure);
        }
    } else {
        // Work in parallel by default in the global threadpool
        let _ = cap_default_rayon_threads();
        let _ = work_arg
            .into_par_iter()
            .with_min_len(10)
            .try_for_each(work_closure);
    }
}

/// Contains the information for all files or all symlinks, chunked by directory
type ChunkedFileInfo<'a> = Vec<DirectoryChunk<'a, WorkingCopyFileUpdate<'a>>>;

/// Take both chunked file information and update the working copy, possibly
/// in parallel.
#[tracing::instrument(level = "debug", skip_all)]
#[allow(clippy::too_many_arguments)]
fn create_working_copy<'a: 'b, 'b>(
    chunks: ChunkedFileInfo<'a>,
    symlinks: ChunkedFileInfo<'a>,
    working_copy_vfs: &VfsImpl,
    store_vfs: &VfsImpl,
    options: RevlogOpenOptions,
    files_sender: &Sender<(&'b HgPath, u32, usize, TruncatedTimestamp)>,
    error_sender: &Sender<HgError>,
    progress: &dyn Progress,
    update_config: &UpdateConfig,
) {
    let auditor = PathAuditor::new(working_copy_vfs.base());

    // First, create all the symlinks sequentially.
    // We need to make sure that no two threads will race:
    //     - A: successfully audit file a/b
    //     - B: correctly delete empty `a` folder
    //     - B: correctly create `a` symlink
    //     - A: incorrectly create `a/b`, traversing the symlink `a`
    // This can only happen because Mercurial can store an invalid commit:
    //
    // $ mkdir update-symlink-out
    // $ hg init update-symlink
    // $ cd update-symlink
    // $ ln -s ../update-symlink-out a
    // $ hg commit -qAm 'symlink a -> ../update-symlink-out'
    // $ hg rm a
    // $ mkdir a && touch a/b
    // $ hg commit -qAm 'file a/b' a/b
    //
    // The crucial detail is in the last line: committing *only* `a/b` succeeds,
    // but `hg` should either refuse or also commit the removal of `a`.
    //
    // This needs to be fixed in `commit`, but regardless will always exist in
    // the wild, so catch it here.
    let symlinks_span =
        tracing::span!(tracing::Level::TRACE, "adding symlinks").entered();
    for (dir_path, chunk) in symlinks {
        let progress_incr = chunk.len() as u64;
        if let Err(e) = working_copy_worker(
            dir_path,
            chunk,
            working_copy_vfs,
            store_vfs,
            options,
            files_sender,
            &auditor,
            update_config,
        ) {
            error_sender
                .clone()
                .send(e)
                .expect("channel should not be disconnected")
        };
        progress.increment(progress_incr, None);
    }
    symlinks_span.exit();

    let files_span =
        tracing::span!(tracing::Level::TRACE, "adding files").entered();
    // Then take care of the normal files
    let work_closure = |(dir_path, chunk): (_, Vec<_>)| -> Result<(), HgError> {
        let progress_incr = chunk.len() as u64;
        if let Err(e) = working_copy_worker(
            dir_path,
            chunk,
            working_copy_vfs,
            store_vfs,
            options,
            files_sender,
            &auditor,
            update_config,
        ) {
            error_sender
                .clone()
                .send(e)
                .expect("channel should not be disconnected")
        }
        progress.increment(progress_incr, None);
        Ok(())
    };
    maybe_parallel(
        "update",
        chunks,
        work_closure,
        update_config.workers,
        error_sender,
    );
    files_span.exit();
}

/// Returns the backup path for `path`, relative to the `working_copy_vfs`'s
/// base. The backup root can be overridden by the config.
pub fn backup_path(
    orig_backup_path: Option<&[u8]>,
    working_copy_vfs: &VfsImpl,
    path: &Path,
) -> Result<PathBuf, HgError> {
    // TODO improve the VFS trait and use it everywhere:
    //  - makedirs
    //  - is_dir, is_symlink
    //  - join from hg_path
    //  - etc.
    let vfs = if let Some(orig_path) = orig_backup_path {
        if orig_path.is_empty() {
            return Ok(working_copy_vfs.join(path.with_extension("orig")));
        }
        VfsImpl::new(
            working_copy_vfs.join(get_path_from_bytes(orig_path)),
            false,
            PathEncoding::None,
        )
    } else {
        return Ok(working_copy_vfs.join(path.with_extension("orig")));
    };

    let full_path = vfs.join(path);
    let backup_dir = full_path.parent().expect("file at root");
    let backup_meta = backup_dir.symlink_metadata().ok();
    if backup_meta.map(|m| !m.is_dir() || m.is_symlink()).unwrap_or(true) {
        // Remove any files that conflict with the backup file's path
        for ancestor in full_path.ancestors() {
            if ancestor.is_file() || ancestor.is_symlink() {
                tracing::debug!(
                    "removing conflicting file {}",
                    backup_dir.display()
                );
                vfs.unlink(ancestor)?;
                break;
            }
            if ancestor == vfs.base() {
                break;
            }
        }
        tracing::debug!("creating {}", backup_dir.display());
        std::fs::create_dir_all(backup_dir).when_writing_file(backup_dir)?;
    }
    let full_path_meta = full_path.symlink_metadata().ok();
    if full_path_meta.map(|m| m.is_dir() && !m.is_symlink()).unwrap_or(false) {
        tracing::debug!(
            "removing conflicting directory {}",
            full_path.display()
        );
        std::fs::remove_dir_all(&full_path).with_context(|| {
            crate::errors::IoErrorContext::RemovingFile(full_path.to_owned())
        })?;
    }
    Ok(full_path
        .strip_prefix(working_copy_vfs.base())
        .expect("backup path should be relative to the working copy vfs")
        .to_owned())
}

/// Represents a work unit for a single thread, responsible for this set of
/// files and restoring them to the working copy.
#[allow(clippy::too_many_arguments)]
fn working_copy_worker<'a: 'b, 'b>(
    dir_path: &HgPath,
    chunk: Vec<WorkingCopyFileUpdate<'a>>,
    working_copy_vfs: &VfsImpl,
    store_vfs: &VfsImpl,
    options: RevlogOpenOptions,
    files_sender: &Sender<(&'b HgPath, u32, usize, TruncatedTimestamp)>,
    auditor: &PathAuditor,
    update_config: &UpdateConfig,
) -> Result<(), HgError> {
    let dir_path =
        hg_path_to_path_buf(dir_path).expect("invalid path in manifest");
    let dir_path = working_copy_vfs.join(dir_path);
    std::fs::create_dir_all(&dir_path).when_writing_file(&dir_path)?;

    if INTERRUPT_RECEIVED.load(Ordering::Relaxed) {
        // Stop working, the user has requested that we stop
        return Err(HgError::InterruptReceived);
    }

    for WorkingCopyFileUpdate { entry, backup } in chunk {
        let (file, file_node, flags) = entry;
        if backup {
            // If a file or directory exists with the same name, back that
            // up. Otherwise, look to see if there is a file that conflicts
            // with a directory this file is in, and if so, back that up.
            let file_path = hg_path_to_path_buf(file)?;
            let mut conflicting = working_copy_vfs.base().join(&file_path);
            let conflict_exists = match conflicting.symlink_metadata() {
                Ok(_) => true,
                Err(_) => {
                    for ancestor in find_dirs_recursive_no_root(file) {
                        let ancestor = hg_path_to_path_buf(ancestor)?;
                        let ancestor = working_copy_vfs.base().join(ancestor);
                        if ancestor.is_file() || ancestor.is_symlink() {
                            conflicting = ancestor;
                        }
                    }
                    conflicting.symlink_metadata().is_ok()
                }
            };

            if conflict_exists {
                let orig = backup_path(
                    update_config.orig_backup_path.as_deref(),
                    working_copy_vfs,
                    &file_path,
                )?;
                working_copy_vfs.rename(&conflicting, &orig, false)?;
            }
        }
        auditor.audit_path(file)?;
        let relative_path = hg_path_to_path_buf(file)?;
        let path = working_copy_vfs.join(&relative_path);
        // This handles the edge case of a previous unknown directory
        // conflicting with this creation. We've backed up anything relevant
        // by this point.
        if path.is_dir() && !path.is_symlink() {
            let dir_removal = std::fs::remove_dir(&path).with_context(|| {
                crate::errors::IoErrorContext::RemovingFile(path.to_owned())
            });
            if let Err(err) = dir_removal {
                // Give an error message instead of a traceback in the case
                // where the conflicting unknown directory is not empty
                match &err {
                    HgError::IoError { error, .. }
                        if error.kind()
                            == std::io::ErrorKind::DirectoryNotEmpty =>
                    {
                        let msg = format!(
                            "conflicting unknown directory '{}' is not empty",
                            path.display()
                        );
                        return Err(HgError::abort_simple(msg));
                    }
                    _ => return Err(err),
                }
            }
        }

        // Treemanifest is not supported
        assert!(!flags.is_tree());

        let filelog = Filelog::open_vfs(store_vfs, file, options)?;
        let filelog_revision_data = &filelog.data_for_node(file_node)?;
        let file_data = filelog_revision_data.file_data()?;

        if flags.is_link() {
            let target = get_path_from_bytes(file_data);
            let _ = working_copy_vfs.unlink(&path);
            if let Err(e) = std::os::unix::fs::symlink(target, &path) {
                // If the path already exists either:
                //   - this symlink points to a different directory in this new
                //     revision
                //   - another process created this file while ignoring the lock
                //     => error
                //   - our check for the fast path is incorrect => error
                //   - this is a malicious repo/bundle and this is symlink that
                //     tries to write things where it shouldn't be able to.
                match e.kind() {
                    std::io::ErrorKind::AlreadyExists => {
                        let metadata = std::fs::symlink_metadata(&path)
                            .when_reading_file(&path)?;
                        if metadata.is_dir() {
                            return Err(HgError::Path(
                                HgPathErrorKind::TraversesSymbolicLink {
                                    // Technically it should be one of the
                                    // children, but good enough
                                    path: file
                                        .join(HgPath::new(b"*"))
                                        .to_owned(),
                                    symlink: file.to_owned(),
                                }
                                .into(),
                            ));
                        } else if metadata.is_symlink() {
                            let _ = working_copy_vfs.unlink(&path);
                            std::os::unix::fs::symlink(target, &path)
                                .when_writing_file(&path)?;
                        } else {
                            return Err(e).when_writing_file(&path);
                        }
                    }
                    _ => return Err(e).when_writing_file(&path),
                }
            }
        } else if update_config.atomic_file {
            working_copy_vfs.atomic_write(relative_path, file_data)?;
        } else {
            let mut f = working_copy_vfs.create(&relative_path, false)?;
            f.write_all(file_data).when_writing_file(&path)?;
        }

        if !flags.is_link() {
            let mode = if flags.is_exec() { 0o755 } else { 0o666 };
            // Respect umask since this is an after-creation update
            let mode = mode & !get_umask();
            std::fs::set_permissions(&path, Permissions::from_mode(mode))
                .when_writing_file(&path)?;
        }

        let metadata =
            std::fs::symlink_metadata(&path).when_reading_file(&path)?;

        let mode = metadata.mode();

        files_sender
            .send((
                file,
                mode,
                file_data.len(),
                TruncatedTimestamp::for_mtime_of(&metadata)
                    .when_reading_file(&path)?,
            ))
            .expect("channel should not be closed");
    }
    Ok(())
}

/// Update the dirstate to reflect the changes we've made to the working copy
#[tracing::instrument(level = "debug", skip_all)]
fn update_dirstate(
    repo: &Repo,
    files_receiver: Receiver<(&HgPath, u32, usize, TruncatedTimestamp)>,
    removals_receiver: Option<Receiver<&HgPath>>,
    devel_abort: bool,
    update_kind: UpdateKind,
) -> Result<UpdateStats, HgError> {
    if devel_abort {
        let msg = "simulated error while recording dirstate updates";
        return Err(HgError::abort_simple(msg));
    }
    let mut dirstate = repo
        .dirstate_map_mut()
        .map_err(|e| HgError::abort(e.to_string(), exit_codes::ABORT, None))?;

    let mut removed = 0;

    if let Some(removals) = removals_receiver {
        for filename in removals.into_iter() {
            removed += 1;
            dirstate.drop_entry_and_copy_source(filename).map_err(|e| {
                HgError::abort(e.to_string(), exit_codes::ABORT, None)
            })?;
        }
    }

    // (see the comments in `filter_ambiguous_files` in `merge.py` for more)
    // It turns out that (on Linux at least) the filesystem resolution time
    // for most filesystems is based on the HZ kernel config. Their internal
    // clocks do return nanoseconds if the hardware clock is precise enough,
    // which should be the case on most recent computers but are only updated
    // every few milliseconds at best (every "jiffy").
    //
    // We are still not concerned with fixing the race with other
    // processes that might modify the working copy right after it was created
    // within the same tick, because it is impossible to catch.
    // However, we might as well not race with operations that could run right
    // after this one, especially other Mercurial operations that could be
    // waiting for the wlock to change file contents and the dirstate.
    //
    // Thus: wait until the filesystem clock has ticked to filter ambiguous
    // entries and write the dirstate, but only for dirstate-v2, since v1 only
    // has second-level granularity and waiting for a whole second is too much
    // of a penalty in the general case.
    // Although we're assuming that people running dirstate-v2 on Linux
    // don't have a second-granularity FS (with the exclusion of NFS), users
    // can be surprising, and at some point in the future dirstate-v2 will
    // become the default. To that end, we limit the wait time to 100ms and
    // fall back to the filter method in case of a timeout.
    //
    // +------------+------+--------------+
    // |   version  | wait | filter level |
    // +------------+------+--------------+
    // |     V1     | No   | Second       |
    // |     V2     | Yes  | Nanosecond   |
    // | V2-slow-fs | No   | Second       |
    // +------------+------+--------------+
    let dirstate_v2 = repo.use_dirstate_v2();

    // Let's ignore NFS right off the bat
    let mut fast_enough_fs = !is_on_nfs_mount(repo.working_directory_path());
    let fs_time_now = if dirstate_v2 && fast_enough_fs {
        match wait_until_fs_tick(repo.working_directory_path()) {
            None => None,
            Some(Ok(time)) => Some(time),
            Some(Err(time)) => {
                fast_enough_fs = false;
                Some(time)
            }
        }
    } else {
        filesystem_now(repo.working_directory_path())
            .ok()
            .map(TruncatedTimestamp::from)
    };

    let mut updated = 0;
    let mut added = 0;
    for (filename, mode, size, mtime) in files_receiver.into_iter() {
        updated += 1;
        // When using dirstate-v2 on a filesystem with reasonable performance
        // this is basically always true unless you get a mtime from the
        // far future.
        let has_meaningful_mtime = if let Some(fs_time) = fs_time_now {
            mtime.for_reliable_mtime_of_self(&fs_time).is_some_and(|t| {
                // Dirstate-v1 only has second-level information
                !t.second_ambiguous || dirstate_v2 && fast_enough_fs
            })
        } else {
            // We somehow failed to write to the filesystem, so don't store
            // the cache information.
            false
        };

        let reset = DirstateEntryReset {
            filename,
            wc_tracked: true,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime,
            parent_file_data_opt: Some(ParentFileData {
                mode_size: Some((
                    mode,
                    size.try_into().expect("invalid file size in manifest"),
                )),
                mtime: Some(mtime),
            }),
            // We are only certain that there isn't a previous entry in the
            // case of update from null
            from_empty: update_kind == UpdateKind::FromNull,
        };
        let new_entry = dirstate.reset_state(reset).map_err(|e| {
            HgError::abort(e.to_string(), exit_codes::ABORT, None)
        })?;
        if new_entry {
            added += 1
        }
    }

    Ok(UpdateStats { updated, added, merged: 0, removed, unresolved: 0 })
}

/// Wait until the next update from the filesystem time by writing in a loop
/// a new temporary file inside the working directory and checking if its time
/// differs from the first one observed.
///
/// Returns `None` if we are unable to get the filesystem time,
/// `Some(Err(timestamp))` if we've timed out waiting for the filesystem clock
/// to tick, and `Some(Ok(timestamp))` if we've waited successfully.
///
/// On Linux, your average tick is going to be a "jiffy", or 1/HZ.
/// HZ is your kernel's tick rate (if it has one configured) and the value
/// is the one returned by `grep 'CONFIG_HZ=' /boot/config-$(uname -r)`,
/// again assuming a normal setup.
///
/// In my case (Alphare) at the time of writing, I get `CONFIG_HZ=250`,
/// which equates to 4ms.
///
/// This might change with a series that could make it to Linux 6.12:
/// https://lore.kernel.org/all/20241002-mgtime-v10-8-d1c4717f5284@kernel.org
fn wait_until_fs_tick(
    working_directory_path: &Path,
) -> Option<Result<TruncatedTimestamp, TruncatedTimestamp>> {
    let start = std::time::Instant::now();
    let old_fs_time = filesystem_now(working_directory_path).ok()?;
    let mut fs_time = filesystem_now(working_directory_path).ok()?;

    const FS_TICK_WAIT_TIMEOUT: Duration = Duration::from_millis(100);

    while fs_time == old_fs_time {
        if std::time::Instant::now() - start > FS_TICK_WAIT_TIMEOUT {
            tracing::debug!(
                "timed out waiting for the fs clock to tick after {:?}",
                FS_TICK_WAIT_TIMEOUT
            );
            return Some(Err(TruncatedTimestamp::from(old_fs_time)));
        }
        fs_time = filesystem_now(working_directory_path).ok()?;
    }
    tracing::debug!(
        "waited for {:?} before writing the dirstate",
        fs_time.duration_since(old_fs_time)
    );
    Some(Ok(TruncatedTimestamp::from(fs_time)))
}

#[cfg(test)]
mod test {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::revlog::manifest::ManifestFlags;

    #[test]
    fn test_chunk_tracked_files() {
        fn chunk(v: Vec<&'static str>) -> Vec<WorkingCopyFileUpdate<'static>> {
            v.into_iter()
                .map(|f| WorkingCopyFileUpdate {
                    entry: (
                        HgPath::new(f.as_bytes()),
                        NULL_NODE,
                        ManifestFlags::new_empty(),
                    ),
                    backup: false,
                })
                .collect()
        }
        let p = HgPath::new;

        let files = chunk(vec!["a"]);
        let expected = vec![(p(""), chunk(vec!["a"]))];
        assert_eq!(chunk_tracked_files(files, false).1, expected);

        let files = chunk(vec!["a", "b", "c"]);
        let expected = vec![(p(""), chunk(vec!["a", "b", "c"]))];
        assert_eq!(chunk_tracked_files(files, false).1, expected);

        let files = chunk(vec![
            "dir/a-new",
            "dir/a/mut",
            "dir/a/mut-mut",
            "dir/albert",
            "dir/b",
            "dir/subdir/c",
            "dir/subdir/d",
            "file",
        ]);
        let expected = vec![
            (p("dir"), chunk(vec!["dir/a-new"])),
            (p("dir/a"), chunk(vec!["dir/a/mut", "dir/a/mut-mut"])),
            (p("dir"), chunk(vec!["dir/albert", "dir/b"])),
            (p("dir/subdir"), chunk(vec!["dir/subdir/c", "dir/subdir/d"])),
            (p(""), chunk(vec!["file"])),
        ];
        assert_eq!(chunk_tracked_files(files, false).1, expected);

        // Doesn't get split
        let large_dir = vec![
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
            "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23",
        ];
        let files = chunk(large_dir.clone());
        let expected = vec![(p(""), chunk(large_dir))];
        assert_eq!(chunk_tracked_files(files, false).1, expected);
    }
}
