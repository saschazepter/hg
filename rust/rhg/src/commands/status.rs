// status.rs
//
// Copyright 2020, Georges Racinet <georges.racinets@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::error::CommandError;
use crate::ui::Ui;
use crate::utils::path_utils::RelativizePaths;
use clap::{Arg, SubCommand};
use format_bytes::format_bytes;
use hg;
use hg::config::Config;
use hg::dirstate::has_exec_bit;
use hg::dirstate::status::StatusPath;
use hg::dirstate::TruncatedTimestamp;
use hg::dirstate::RANGE_MASK_31BIT;
use hg::errors::{HgError, IoResultExt};
use hg::lock::LockError;
use hg::manifest::Manifest;
use hg::matchers::AlwaysMatcher;
use hg::repo::Repo;
use hg::utils::files::get_bytes_from_os_string;
use hg::utils::files::get_bytes_from_path;
use hg::utils::files::get_path_from_bytes;
use hg::utils::hg_path::{hg_path_to_path_buf, HgPath};
use hg::StatusOptions;
use log::info;
use std::io;
use std::path::PathBuf;

pub const HELP_TEXT: &str = "
Show changed files in the working directory

This is a pure Rust version of `hg status`.

Some options might be missing, check the list below.
";

pub fn args() -> clap::App<'static, 'static> {
    SubCommand::with_name("status")
        .alias("st")
        .about(HELP_TEXT)
        .arg(
            Arg::with_name("all")
                .help("show status of all files")
                .short("-A")
                .long("--all"),
        )
        .arg(
            Arg::with_name("modified")
                .help("show only modified files")
                .short("-m")
                .long("--modified"),
        )
        .arg(
            Arg::with_name("added")
                .help("show only added files")
                .short("-a")
                .long("--added"),
        )
        .arg(
            Arg::with_name("removed")
                .help("show only removed files")
                .short("-r")
                .long("--removed"),
        )
        .arg(
            Arg::with_name("clean")
                .help("show only clean files")
                .short("-c")
                .long("--clean"),
        )
        .arg(
            Arg::with_name("deleted")
                .help("show only deleted files")
                .short("-d")
                .long("--deleted"),
        )
        .arg(
            Arg::with_name("unknown")
                .help("show only unknown (not tracked) files")
                .short("-u")
                .long("--unknown"),
        )
        .arg(
            Arg::with_name("ignored")
                .help("show only ignored files")
                .short("-i")
                .long("--ignored"),
        )
        .arg(
            Arg::with_name("copies")
                .help("show source of copied files (DEFAULT: ui.statuscopies)")
                .short("-C")
                .long("--copies"),
        )
        .arg(
            Arg::with_name("no-status")
                .help("hide status prefix")
                .short("-n")
                .long("--no-status"),
        )
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

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    // TODO: lift these limitations
    if invocation.config.get_bool(b"ui", b"tweakdefaults")? {
        return Err(CommandError::unsupported(
            "ui.tweakdefaults is not yet supported with rhg status",
        ));
    }
    if invocation.config.get_bool(b"ui", b"statuscopies")? {
        return Err(CommandError::unsupported(
            "ui.statuscopies is not yet supported with rhg status",
        ));
    }
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

    let verbose = !ui.plain(None)
        && !args.is_present("print0")
        && (config.get_bool(b"ui", b"verbose")?
            || config.get_bool(b"commands", b"status.verbose")?);
    if verbose {
        return Err(CommandError::unsupported(
            "verbose status is not supported yet",
        ));
    }

    let all = args.is_present("all");
    let display_states = if all {
        // TODO when implementing `--quiet`: it excludes clean files
        // from `--all`
        ALL_DISPLAY_STATES
    } else {
        let requested = DisplayStates {
            modified: args.is_present("modified"),
            added: args.is_present("added"),
            removed: args.is_present("removed"),
            clean: args.is_present("clean"),
            deleted: args.is_present("deleted"),
            unknown: args.is_present("unknown"),
            ignored: args.is_present("ignored"),
        };
        if requested.is_empty() {
            DEFAULT_DISPLAY_STATES
        } else {
            requested
        }
    };
    let no_status = args.is_present("no-status");
    let list_copies = all
        || args.is_present("copies")
        || config.get_bool(b"ui", b"statuscopies")?;

    let repo = invocation.repo?;

    if repo.has_sparse() || repo.has_narrow() {
        return Err(CommandError::unsupported(
            "rhg status is not supported for sparse checkouts or narrow clones yet"
        ));
    }

    let mut dmap = repo.dirstate_map_mut()?;

    let options = StatusOptions {
        // we're currently supporting file systems with exec flags only
        // anyway
        check_exec: true,
        list_clean: display_states.clean,
        list_unknown: display_states.unknown,
        list_ignored: display_states.ignored,
        list_copies,
        collect_traversed_dirs: false,
    };
    let (mut ds_status, pattern_warnings) = dmap.status(
        &AlwaysMatcher,
        repo.working_directory_path().to_owned(),
        ignore_files(repo, config),
        options,
    )?;
    for warning in pattern_warnings {
        match warning {
            hg::PatternFileWarning::InvalidSyntax(path, syntax) => ui
                .write_stderr(&format_bytes!(
                    b"{}: ignoring invalid syntax '{}'\n",
                    get_bytes_from_path(path),
                    &*syntax
                ))?,
            hg::PatternFileWarning::NoSuchFile(path) => {
                let path = if let Ok(relative) =
                    path.strip_prefix(repo.working_directory_path())
                {
                    relative
                } else {
                    &*path
                };
                ui.write_stderr(&format_bytes!(
                    b"skipping unreadable pattern file '{}': \
                      No such file or directory\n",
                    get_bytes_from_path(path),
                ))?
            }
        }
    }

    for (path, error) in ds_status.bad {
        let error = match error {
            hg::BadMatch::OsError(code) => {
                std::io::Error::from_raw_os_error(code).to_string()
            }
            hg::BadMatch::BadType(ty) => {
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
        let manifest = repo.manifest_for_node(p1).map_err(|e| {
            CommandError::from((e, &*format!("{:x}", p1.short())))
        })?;
        for to_check in ds_status.unsure {
            if unsure_is_modified(repo, &manifest, &to_check.path)? {
                if display_states.modified {
                    ds_status.modified.push(to_check);
                }
            } else {
                if display_states.clean {
                    ds_status.clean.push(to_check.clone());
                }
                fixup.push(to_check.path.into_owned())
            }
        }
    }
    let relative_paths = (!ui.plain(None))
        && config
            .get_option(b"commands", b"status.relative")?
            .unwrap_or(config.get_bool(b"ui", b"relative-paths")?);
    let output = DisplayStatusPaths {
        ui,
        no_status,
        relativize: if relative_paths {
            Some(RelativizePaths::new(repo)?)
        } else {
            None
        },
    };
    if display_states.modified {
        output.display(b"M ", "status.modified", ds_status.modified)?;
    }
    if display_states.added {
        output.display(b"A ", "status.added", ds_status.added)?;
    }
    if display_states.removed {
        output.display(b"R ", "status.removed", ds_status.removed)?;
    }
    if display_states.deleted {
        output.display(b"! ", "status.deleted", ds_status.deleted)?;
    }
    if display_states.unknown {
        output.display(b"? ", "status.unknown", ds_status.unknown)?;
    }
    if display_states.ignored {
        output.display(b"I ", "status.ignored", ds_status.ignored)?;
    }
    if display_states.clean {
        output.display(b"C ", "status.clean", ds_status.clean)?;
    }

    let mut dirstate_write_needed = ds_status.dirty;
    let filesystem_time_at_status_start =
        ds_status.filesystem_time_at_status_start;

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
                    let fs_metadata = repo
                        .working_directory_vfs()
                        .symlink_metadata(&fs_path)?;
                    if let Some(mtime) =
                        TruncatedTimestamp::for_reliable_mtime_of(
                            &fs_metadata,
                            &mtime_boundary,
                        )
                        .when_reading_file(&fs_path)?
                    {
                        let mode = fs_metadata.mode();
                        let size = fs_metadata.len() as u32 & RANGE_MASK_31BIT;
                        let mut entry = dmap
                            .get(&hg_path)?
                            .expect("ambiguous file not in dirstate");
                        entry.set_clean(mode, size, mtime);
                        dmap.add_file(&hg_path, entry)?;
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
        }
        Err(LockError::Other(HgError::IoError { error, .. }))
            if error.kind() == io::ErrorKind::PermissionDenied =>
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
            // TODO: expand "~/" and environment variable here, like Python
            // does with `os.path.expanduser` and `os.path.expandvars`

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
        // TODO: get the stdout lock once for the whole loop
        // instead of in each write
        for StatusPath { path, copy_source } in paths {
            let relative;
            let path = if let Some(relativize) = &self.relativize {
                relative = relativize.relativize(&path);
                &*relative
            } else {
                path.as_bytes()
            };
            // TODO: Add a way to use `write_bytes!` instead of `format_bytes!`
            // in order to stream to stdout instead of allocating an
            // itermediate `Vec<u8>`.
            if !self.no_status {
                self.ui.write_stdout_labelled(status_prefix, label)?
            }
            self.ui
                .write_stdout_labelled(&format_bytes!(b"{}\n", path), label)?;
            if let Some(source) = copy_source {
                let label = "status.copied";
                self.ui.write_stdout_labelled(
                    &format_bytes!(b"  {}\n", source.as_bytes()),
                    label,
                )?
            }
        }
        Ok(())
    }
}

/// Check if a file is modified by comparing actual repo store and file system.
///
/// This meant to be used for those that the dirstate cannot resolve, due
/// to time resolution limits.
fn unsure_is_modified(
    repo: &Repo,
    manifest: &Manifest,
    hg_path: &HgPath,
) -> Result<bool, HgError> {
    let vfs = repo.working_directory_vfs();
    let fs_path = hg_path_to_path_buf(hg_path).expect("HgPath conversion");
    let fs_metadata = vfs.symlink_metadata(&fs_path)?;
    let is_symlink = fs_metadata.file_type().is_symlink();
    // TODO: Also account for `FALLBACK_SYMLINK` and `FALLBACK_EXEC` from the
    // dirstate
    let fs_flags = if is_symlink {
        Some(b'l')
    } else if has_exec_bit(&fs_metadata) {
        Some(b'x')
    } else {
        None
    };

    let entry = manifest
        .find_by_path(hg_path)?
        .expect("ambgious file not in p1");
    if entry.flags != fs_flags {
        return Ok(true);
    }
    let filelog = repo.filelog(hg_path)?;
    let fs_len = fs_metadata.len();
    let filelog_entry =
        filelog.entry_for_node(entry.node_id()?).map_err(|_| {
            HgError::corrupted("filelog missing node from manifest")
        })?;
    if filelog_entry.file_data_len_not_equal_to(fs_len) {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(true);
    }

    let p1_filelog_data = filelog_entry.data()?;
    let p1_contents = p1_filelog_data.file_data()?;
    if p1_contents.len() as u64 != fs_len {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(true);
    }

    let fs_contents = if is_symlink {
        get_bytes_from_os_string(vfs.read_link(fs_path)?.into_os_string())
    } else {
        vfs.read(fs_path)?
    };
    Ok(p1_contents != &*fs_contents)
}
