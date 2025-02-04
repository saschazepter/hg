// status.rs
//
// Copyright 2020, Georges Racinet <georges.racinets@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::error::CommandError;
use crate::ui::{
    format_pattern_file_warning, print_narrow_sparse_warnings, relative_paths,
    RelativePaths, Ui,
};
use crate::utils::path_utils::RelativizePaths;
use clap::Arg;
use format_bytes::format_bytes;
use hg::config::Config;
use hg::dirstate::entry::{has_exec_bit, TruncatedTimestamp};
use hg::dirstate::status::{
    BadMatch, DirstateStatus, StatusError, StatusOptions, StatusPath,
};
use hg::errors::{HgError, IoResultExt};
use hg::filepatterns::{parse_pattern_args, PatternFileWarning};
use hg::lock::LockError;
use hg::matchers::{AlwaysMatcher, IntersectionMatcher};
use hg::repo::Repo;
use hg::revlog::manifest::Manifest;
use hg::revlog::options::{default_revlog_options, RevlogOpenOptions};
use hg::revlog::RevlogType;
use hg::utils::debug::debug_wait_for_file;
use hg::utils::files::{
    get_bytes_from_os_str, get_bytes_from_os_string, get_path_from_bytes,
};
use hg::utils::hg_path::{hg_path_to_path_buf, HgPath};
use hg::Revision;
use hg::{self, narrow, sparse};
use log::info;
use rayon::prelude::*;
use std::io;
use std::mem::take;
use std::path::PathBuf;

pub const HELP_TEXT: &str = "
Show changed files in the working directory

This is a pure Rust version of `hg status`.

Some options might be missing, check the list below.
";

pub fn args() -> clap::Command {
    clap::command!("status")
        .alias("st")
        .about(HELP_TEXT)
        .arg(
            Arg::new("file")
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("show only these files")
                .action(clap::ArgAction::Append),
        )
        .arg(
            Arg::new("all")
                .help("show status of all files")
                .short('A')
                .action(clap::ArgAction::SetTrue)
                .long("all"),
        )
        .arg(
            Arg::new("modified")
                .help("show only modified files")
                .short('m')
                .action(clap::ArgAction::SetTrue)
                .long("modified"),
        )
        .arg(
            Arg::new("added")
                .help("show only added files")
                .short('a')
                .action(clap::ArgAction::SetTrue)
                .long("added"),
        )
        .arg(
            Arg::new("removed")
                .help("show only removed files")
                .short('r')
                .action(clap::ArgAction::SetTrue)
                .long("removed"),
        )
        .arg(
            Arg::new("clean")
                .help("show only clean files")
                .short('c')
                .action(clap::ArgAction::SetTrue)
                .long("clean"),
        )
        .arg(
            Arg::new("deleted")
                .help("show only deleted files")
                .short('d')
                .action(clap::ArgAction::SetTrue)
                .long("deleted"),
        )
        .arg(
            Arg::new("unknown")
                .help("show only unknown (not tracked) files")
                .short('u')
                .action(clap::ArgAction::SetTrue)
                .long("unknown"),
        )
        .arg(
            Arg::new("ignored")
                .help("show only ignored files")
                .short('i')
                .action(clap::ArgAction::SetTrue)
                .long("ignored"),
        )
        .arg(
            Arg::new("copies")
                .help("show source of copied files (DEFAULT: ui.statuscopies)")
                .short('C')
                .action(clap::ArgAction::SetTrue)
                .long("copies"),
        )
        .arg(
            Arg::new("no-copies")
                .action(clap::ArgAction::SetTrue)
                .long("no-copies")
                .overrides_with("copies"),
        )
        .arg(
            Arg::new("print0")
                .help("end filenames with NUL, for use with xargs")
                .short('0')
                .action(clap::ArgAction::SetTrue)
                .long("print0"),
        )
        .arg(
            Arg::new("no-status")
                .help("hide status prefix")
                .short('n')
                .action(clap::ArgAction::SetTrue)
                .long("no-status"),
        )
        .arg(
            Arg::new("verbose")
                .help("enable additional output")
                .short('v')
                .action(clap::ArgAction::SetTrue)
                .long("verbose"),
        )
        .arg(
            Arg::new("rev")
                .help("show difference from/to revision")
                .long("rev")
                .num_args(1)
                .action(clap::ArgAction::Append)
                .value_name("REV"),
        )
        .arg(
            Arg::new("change")
                .help("list the changed files of a revision")
                .long("change")
                .value_name("REV")
                .conflicts_with("rev"),
        )
}

fn parse_revpair(
    repo: &Repo,
    revs: Option<Vec<String>>,
) -> Result<Option<(Revision, Revision)>, CommandError> {
    let Some(revs) = revs else {
        return Ok(None);
    };
    match revs.as_slice() {
        [] => Ok(None),
        [rev1, rev2] => Ok(Some((
            hg::revset::resolve_single(rev1, repo)?,
            hg::revset::resolve_single(rev2, repo)?,
        ))),
        _ => Err(CommandError::unsupported("expected 0 or 2 --rev flags")),
    }
}

/// Pure data type allowing the caller to specify file states to display
#[derive(Copy, Clone, Debug)]
pub struct DisplayStates {
    pub modified: bool,
    pub added: bool,
    pub removed: bool,
    pub clean: bool,
    pub deleted: bool,
    pub unknown: bool,
    pub ignored: bool,
}

pub const DEFAULT_DISPLAY_STATES: DisplayStates = DisplayStates {
    modified: true,
    added: true,
    removed: true,
    clean: false,
    deleted: true,
    unknown: true,
    ignored: false,
};

pub const ALL_DISPLAY_STATES: DisplayStates = DisplayStates {
    modified: true,
    added: true,
    removed: true,
    clean: true,
    deleted: true,
    unknown: true,
    ignored: true,
};

impl DisplayStates {
    pub fn is_empty(&self) -> bool {
        !(self.modified
            || self.added
            || self.removed
            || self.clean
            || self.deleted
            || self.unknown
            || self.ignored)
    }
}

fn has_unfinished_merge(repo: &Repo) -> Result<bool, CommandError> {
    Ok(repo.dirstate_parents()?.is_merge())
}

fn has_unfinished_state(repo: &Repo) -> Result<bool, CommandError> {
    // These are all the known values for the [fname] argument of
    // [addunfinished] function in [state.py]
    let known_state_files: &[&str] = &[
        "bisect.state",
        "graftstate",
        "histedit-state",
        "rebasestate",
        "shelvedstate",
        "transplant/journal",
        "updatestate",
    ];
    if has_unfinished_merge(repo)? {
        return Ok(true);
    };
    for f in known_state_files {
        if repo.hg_vfs().join(f).exists() {
            return Ok(true);
        }
    }
    Ok(false)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    // TODO: lift these limitations
    if invocation
        .config
        .get(b"commands", b"status.terse")
        .is_some()
    {
        return Err(CommandError::unsupported(
            "status.terse is not yet supported with rhg status",
        ));
    }

    let ui = invocation.ui;
    let config = invocation.config;
    let args = invocation.subcommand_args;

    let revs = args.get_many::<String>("rev");
    let change = args.get_one::<String>("change");
    let print0 = args.get_flag("print0");
    let verbose = args.get_flag("verbose")
        || config.get_bool(b"ui", b"verbose")?
        || config.get_bool(b"commands", b"status.verbose")?;
    let verbose = verbose && !print0;

    let all = args.get_flag("all");
    let display_states = if all {
        // TODO when implementing `--quiet`: it excludes clean files
        // from `--all`
        ALL_DISPLAY_STATES
    } else {
        let requested = DisplayStates {
            modified: args.get_flag("modified"),
            added: args.get_flag("added"),
            removed: args.get_flag("removed"),
            clean: args.get_flag("clean"),
            deleted: args.get_flag("deleted"),
            unknown: args.get_flag("unknown"),
            ignored: args.get_flag("ignored"),
        };
        if requested.is_empty() {
            DEFAULT_DISPLAY_STATES
        } else {
            requested
        }
    };
    let no_status = args.get_flag("no-status");
    let list_copies = if args.get_flag("copies") {
        true
    } else if args.get_flag("no-copies") {
        false
    } else {
        config.get_bool(b"ui", b"statuscopies")?
    };
    let list_copies = (list_copies || all) && !no_status;

    let repo = invocation.repo?;
    let revpair = parse_revpair(repo, revs.map(|i| i.cloned().collect()))?;
    let change = change
        .map(|rev| hg::revset::resolve_single(rev, repo))
        .transpose()?;

    if verbose && has_unfinished_state(repo)? {
        return Err(CommandError::unsupported(
            "verbose status output is not supported by rhg (and is needed because we're in an unfinished operation)",
        ));
    }

    let mut dmap = repo.dirstate_map_mut()?;

    let check_exec = hg::checkexec::check_exec(repo.working_directory_path());

    let options = StatusOptions {
        check_exec,
        list_clean: display_states.clean,
        list_unknown: display_states.unknown,
        list_ignored: display_states.ignored,
        list_copies,
        collect_traversed_dirs: false,
    };

    type StatusResult<'a> =
        Result<(DirstateStatus<'a>, Vec<PatternFileWarning>), StatusError>;

    let relative_status = config
        .get_option(b"commands", b"status.relative")?
        .expect("commands.status.relative should have a default value");

    let relativize_paths = relative_status || {
        // See in Python code with `getuipathfn` usage in `commands.py`.
        let legacy_relative_behavior = args.contains_id("file");
        match relative_paths(invocation.config)? {
            RelativePaths::Legacy => legacy_relative_behavior,
            RelativePaths::Bool(v) => v,
        }
    };

    let mut output = DisplayStatusPaths {
        ui,
        no_status,
        relativize: if relativize_paths {
            Some(RelativizePaths::new(repo)?)
        } else {
            None
        },
        print0,
    };

    let after_status = |res: StatusResult| -> Result<_, CommandError> {
        let (mut ds_status, pattern_warnings) = res?;
        for warning in pattern_warnings {
            ui.write_stderr(&format_pattern_file_warning(&warning, repo))?;
        }

        for (path, error) in take(&mut ds_status.bad) {
            let error = match error {
                BadMatch::OsError(code) => {
                    std::io::Error::from_raw_os_error(code).to_string()
                }
                BadMatch::BadType(ty) => {
                    format!("unsupported file type (type is {})", ty)
                }
            };
            ui.write_stderr(&format_bytes!(
                b"{}: {}\n",
                path.as_bytes(),
                error.as_bytes()
            ))?
        }
        if !ds_status.unsure.is_empty() {
            info!(
                "Files to be rechecked by retrieval from filelog: {:?}",
                ds_status.unsure.iter().map(|s| &s.path).collect::<Vec<_>>()
            );
        }
        let mut fixup = Vec::new();
        if !ds_status.unsure.is_empty()
            && (display_states.modified || display_states.clean)
        {
            let p1 = repo.dirstate_parents()?.p1;
            let manifest = repo.manifest_for_node(p1)?;
            let working_directory_vfs = repo.working_directory_vfs();
            let store_vfs = repo.store_vfs();
            let filelog_open_options = default_revlog_options(
                repo.config(),
                repo.requirements(),
                RevlogType::Filelog,
            )?;
            let res: Vec<_> = take(&mut ds_status.unsure)
                .into_par_iter()
                .map(|to_check| {
                    // The compiler seems to get a bit confused with complex
                    // inference when using a parallel iterator + map
                    // + map_err + collect, so let's just inline some of the
                    // logic.
                    match unsure_is_modified(
                        &working_directory_vfs,
                        &store_vfs,
                        check_exec,
                        &manifest,
                        &to_check.path,
                        filelog_open_options,
                    ) {
                        Err(HgError::IoError { .. }) => {
                            // IO errors most likely stem from the file being
                            // deleted even though we know it's in the
                            // dirstate.
                            Ok((to_check, UnsureOutcome::Deleted))
                        }
                        Ok(outcome) => Ok((to_check, outcome)),
                        Err(e) => Err(e),
                    }
                })
                .collect::<Result<_, _>>()?;
            for (status_path, outcome) in res.into_iter() {
                match outcome {
                    UnsureOutcome::Clean => {
                        if display_states.clean {
                            ds_status.clean.push(status_path.clone());
                        }
                        fixup.push(status_path.path.into_owned())
                    }
                    UnsureOutcome::Modified => {
                        if display_states.modified {
                            ds_status.modified.push(status_path);
                        }
                    }
                    UnsureOutcome::Deleted => {
                        if display_states.deleted {
                            ds_status.deleted.push(status_path);
                        }
                    }
                }
            }
        }

        let dirstate_write_needed = ds_status.dirty;
        let filesystem_time_at_status_start =
            ds_status.filesystem_time_at_status_start;

        output.output(display_states, ds_status)?;

        Ok((
            fixup,
            dirstate_write_needed,
            filesystem_time_at_status_start,
        ))
    };

    let (narrow_matcher, narrow_warnings) = narrow::matcher(repo)?;
    let (sparse_matcher, sparse_warnings) = sparse::matcher(repo)?;
    // Sparse is only applicable for the working copy, not history.
    let sparse_is_applicable = revpair.is_none() && change.is_none();
    let matcher =
        match (repo.has_narrow(), repo.has_sparse() && sparse_is_applicable) {
            (true, true) => Box::new(IntersectionMatcher::new(
                narrow_matcher,
                sparse_matcher,
            )),
            (true, false) => narrow_matcher,
            (false, true) => sparse_matcher,
            (false, false) => Box::new(AlwaysMatcher),
        };
    let matcher = match args.get_many::<std::ffi::OsString>("file") {
        None => matcher,
        Some(files) => {
            let patterns: Vec<Vec<u8>> = files
                .filter(|s| !s.is_empty())
                .map(get_bytes_from_os_str)
                .collect();
            for file in &patterns {
                if file.starts_with(b"set:") {
                    return Err(CommandError::unsupported("fileset"));
                }
            }
            let cwd = hg::utils::current_dir()?;
            let root = repo.working_directory_path();
            let ignore_patterns = parse_pattern_args(patterns, &cwd, root)?;
            let files_matcher =
                hg::matchers::PatternMatcher::new(ignore_patterns)?;
            Box::new(IntersectionMatcher::new(
                Box::new(files_matcher),
                matcher,
            ))
        }
    };
    print_narrow_sparse_warnings(
        &narrow_warnings,
        &sparse_warnings,
        ui,
        repo,
    )?;

    if revpair.is_some() || change.is_some() {
        let mut ds_status = DirstateStatus::default();
        let list_copies = if list_copies {
            if config.get_bool(b"devel", b"copy-tracing.trace-all-files")? {
                Some(hg::operations::ListCopies::AddedOrModified)
            } else {
                Some(hg::operations::ListCopies::Added)
            }
        } else {
            None
        };
        let stat = if let Some((rev1, rev2)) = revpair {
            if list_copies.is_some() {
                return Err(CommandError::unsupported(
                    "status --rev --rev with copy information is not implemented yet",
                ));
            }
            hg::operations::status_rev_rev_no_copies(
                repo, rev1, rev2, matcher,
            )?
        } else if let Some(rev) = change {
            hg::operations::status_change(repo, rev, matcher, list_copies)?
        } else {
            unreachable!();
        };
        for entry in stat.iter() {
            let (path, status) = entry?;
            match status {
                hg::operations::DiffStatus::Removed => {
                    if display_states.removed {
                        ds_status.removed.push(path)
                    }
                }
                hg::operations::DiffStatus::Added => {
                    if display_states.added {
                        ds_status.added.push(path)
                    }
                }
                hg::operations::DiffStatus::Modified => {
                    if display_states.modified {
                        ds_status.modified.push(path)
                    }
                }
                hg::operations::DiffStatus::Matching => {
                    if display_states.clean {
                        ds_status.clean.push(path)
                    }
                }
            }
        }
        output.output(display_states, ds_status)?;
        return Ok(());
    }

    let (fixup, mut dirstate_write_needed, filesystem_time_at_status_start) =
        dmap.with_status(
            matcher.as_ref(),
            repo.working_directory_path().to_owned(),
            ignore_files(repo, config),
            options,
            after_status,
        )?;

    // Development config option to test write races
    if let Err(e) =
        debug_wait_for_file(config, "status.pre-dirstate-write-file")
    {
        ui.write_stderr(e.as_bytes()).ok();
    }

    if (fixup.is_empty() || filesystem_time_at_status_start.is_none())
        && !dirstate_write_needed
    {
        // Nothing to update
        return Ok(());
    }

    // Update the dirstate on disk if we can
    let with_lock_result =
        repo.try_with_wlock_no_wait(|| -> Result<(), CommandError> {
            if let Some(mtime_boundary) = filesystem_time_at_status_start {
                for hg_path in fixup {
                    use std::os::unix::fs::MetadataExt;
                    let fs_path = hg_path_to_path_buf(&hg_path)
                        .expect("HgPath conversion");
                    // Specifically do not reuse `fs_metadata` from
                    // `unsure_is_clean` which was needed before reading
                    // contents. Here we access metadata again after reading
                    // content, in case it changed in the meantime.
                    let metadata_res = repo
                        .working_directory_vfs()
                        .symlink_metadata(&fs_path);
                    let fs_metadata = match metadata_res {
                        Ok(meta) => meta,
                        Err(err) => match err {
                            HgError::IoError { .. } => {
                                // The file has probably been deleted. In any
                                // case, it was in the dirstate before, so
                                // let's ignore the error.
                                continue;
                            }
                            _ => return Err(err.into()),
                        },
                    };
                    if let Some(mtime) =
                        TruncatedTimestamp::for_reliable_mtime_of(
                            &fs_metadata,
                            &mtime_boundary,
                        )
                        .when_reading_file(&fs_path)?
                    {
                        let mode = fs_metadata.mode();
                        let size = fs_metadata.len();
                        dmap.set_clean(&hg_path, mode, size as u32, mtime)?;
                        dirstate_write_needed = true
                    }
                }
            }
            drop(dmap); // Avoid "already mutably borrowed" RefCell panics
            if dirstate_write_needed {
                repo.write_dirstate()?
            }
            Ok(())
        });
    match with_lock_result {
        Ok(closure_result) => closure_result?,
        Err(LockError::AlreadyHeld) => {
            // Not updating the dirstate is not ideal but not critical:
            // don’t keep our caller waiting until some other Mercurial
            // process releases the lock.
            log::info!("not writing dirstate from `status`: lock is held")
        }
        Err(LockError::Other(HgError::IoError { error, .. }))
            if error.kind() == io::ErrorKind::PermissionDenied
                || match error.raw_os_error() {
                    None => false,
                    Some(errno) => libc::EROFS == errno,
                } =>
        {
            // `hg status` on a read-only repository is fine
        }
        Err(LockError::Other(error)) => {
            // Report other I/O errors
            Err(error)?
        }
    }
    Ok(())
}

fn ignore_files(repo: &Repo, config: &Config) -> Vec<PathBuf> {
    let mut ignore_files = Vec::new();
    let repo_ignore = repo.working_directory_vfs().join(".hgignore");
    if repo_ignore.exists() {
        ignore_files.push(repo_ignore)
    }
    for (key, value) in config.iter_section(b"ui") {
        if key == b"ignore" || key.starts_with(b"ignore.") {
            let path = get_path_from_bytes(value);
            let path = shellexpand::path::full_with_context_no_errors(
                path,
                home::home_dir,
                |s| std::env::var(s).ok(),
            );
            let joined = repo.working_directory_path().join(path);
            ignore_files.push(joined);
        }
    }
    ignore_files
}

struct DisplayStatusPaths<'a> {
    ui: &'a Ui,
    no_status: bool,
    relativize: Option<RelativizePaths>,
    print0: bool,
}

impl DisplayStatusPaths<'_> {
    // Probably more elegant to use a Deref or Borrow trait rather than
    // harcode HgPathBuf, but probably not really useful at this point
    fn display(
        &self,
        status_prefix: &[u8],
        label: &'static str,
        mut paths: Vec<StatusPath<'_>>,
    ) -> Result<(), CommandError> {
        paths.sort_unstable();
        let mut stdout = self.ui.stdout_buffer();
        for StatusPath { path, copy_source } in paths {
            let relative_path;
            let relative_source;
            let (path, copy_source) = if let Some(relativize) =
                &self.relativize
            {
                relative_path = relativize.relativize(&path);
                relative_source =
                    copy_source.as_ref().map(|s| relativize.relativize(s));
                (&*relative_path, relative_source.as_deref())
            } else {
                (path.as_bytes(), copy_source.as_ref().map(|s| s.as_bytes()))
            };
            // TODO: Add a way to use `write_bytes!` instead of
            // `format_bytes!` in order to stream to stdout
            // instead of allocating an itermediate
            // `Vec<u8>`.
            if !self.no_status {
                stdout.write_stdout_labelled(status_prefix, label)?
            }
            let linebreak = if self.print0 { b"\x00" } else { b"\n" };
            stdout.write_stdout_labelled(
                &format_bytes!(b"{}{}", path, linebreak),
                label,
            )?;
            if let Some(source) = copy_source {
                let label = "status.copied";
                stdout.write_stdout_labelled(
                    &format_bytes!(b"  {}{}", source, linebreak),
                    label,
                )?
            }
        }
        stdout.flush()?;
        Ok(())
    }

    fn output(
        &mut self,
        display_states: DisplayStates,
        ds_status: DirstateStatus,
    ) -> Result<(), CommandError> {
        if display_states.modified {
            self.display(b"M ", "status.modified", ds_status.modified)?;
        }
        if display_states.added {
            self.display(b"A ", "status.added", ds_status.added)?;
        }
        if display_states.removed {
            self.display(b"R ", "status.removed", ds_status.removed)?;
        }
        if display_states.deleted {
            self.display(b"! ", "status.deleted", ds_status.deleted)?;
        }
        if display_states.unknown {
            self.display(b"? ", "status.unknown", ds_status.unknown)?;
        }
        if display_states.ignored {
            self.display(b"I ", "status.ignored", ds_status.ignored)?;
        }
        if display_states.clean {
            self.display(b"C ", "status.clean", ds_status.clean)?;
        }
        Ok(())
    }
}

/// Outcome of the additional check for an ambiguous tracked file
enum UnsureOutcome {
    /// The file is actually clean
    Clean,
    /// The file has been modified
    Modified,
    /// The file was deleted on disk (or became another type of fs entry)
    Deleted,
}

/// Check if a file is modified by comparing actual repo store and file system.
///
/// This meant to be used for those that the dirstate cannot resolve, due
/// to time resolution limits.
fn unsure_is_modified(
    working_directory_vfs: &hg::vfs::VfsImpl,
    store_vfs: &hg::vfs::VfsImpl,
    check_exec: bool,
    manifest: &Manifest,
    hg_path: &HgPath,
    revlog_open_options: RevlogOpenOptions,
) -> Result<UnsureOutcome, HgError> {
    let vfs = working_directory_vfs;
    let fs_path = hg_path_to_path_buf(hg_path).expect("HgPath conversion");
    let fs_metadata = vfs.symlink_metadata(&fs_path)?;
    let is_symlink = fs_metadata.file_type().is_symlink();

    let entry = manifest
        .find_by_path(hg_path)?
        .expect("ambgious file not in p1");

    // TODO: Also account for `FALLBACK_SYMLINK` and `FALLBACK_EXEC` from the
    // dirstate
    let fs_flags = if is_symlink {
        Some(b'l')
    } else if check_exec && has_exec_bit(&fs_metadata) {
        Some(b'x')
    } else {
        None
    };

    let entry_flags = if check_exec {
        entry.flags
    } else if entry.flags.map(|f| f.into()) == Some(b'x') {
        None
    } else {
        entry.flags
    };

    if entry_flags.map(|f| f.into()) != fs_flags {
        return Ok(UnsureOutcome::Modified);
    }
    let filelog = hg::revlog::filelog::Filelog::open_vfs(
        store_vfs,
        hg_path,
        revlog_open_options,
    )?;
    let fs_len = fs_metadata.len();
    let file_node = entry.node_id()?;
    let filelog_entry = filelog.entry_for_node(file_node).map_err(|_| {
        HgError::corrupted(format!(
            "filelog {:?} missing node {:?} from manifest",
            hg_path, file_node
        ))
    })?;
    if filelog_entry.file_data_len_not_equal_to(fs_len) {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(UnsureOutcome::Modified);
    }

    let p1_filelog_data = filelog_entry.data()?;
    let p1_contents = p1_filelog_data.file_data()?;
    if p1_contents.len() as u64 != fs_len {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(UnsureOutcome::Modified);
    }

    let fs_contents = if is_symlink {
        get_bytes_from_os_string(vfs.read_link(fs_path)?.into_os_string())
    } else {
        vfs.read(fs_path)?
    };

    Ok(if p1_contents != &*fs_contents {
        UnsureOutcome::Modified
    } else {
        UnsureOutcome::Clean
    })
}
