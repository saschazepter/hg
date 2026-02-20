use core::str;

use clap::Arg;
use format_bytes::format_bytes;
use hg::dirstate::status::DirstateStatus;
use hg::dirstate::status::StatusError;
use hg::dirstate::status::StatusOptions;
use hg::matchers::AlwaysMatcher;
use hg::matchers::IntersectionMatcher;
use hg::matchers::get_ignore_files;
use hg::narrow;
use hg::sparse;
use hg::utils::hg_path::hg_path_to_path_buf;
use hg::vfs::Vfs;
use hg::warnings::HgWarningContext;
use hg::{self};

use crate::error::CommandError;
use crate::ui::print_warnings;

pub const HELP_TEXT: &str = "
removes files not tracked by Mercurial

Delete files not known to Mercurial. This is useful to test local and
uncommitted changes in an otherwise-clean source tree.

This means that purge will delete the following by default:

- Unknown files: files marked with \"?\" by 'hg status'
- Empty directories: in fact Mercurial ignores directories unless they contain
  files under source control management

But it will leave untouched:

- Modified and unmodified tracked files
- Ignored files (unless -i or --all is specified)
- New files added to the repository (with 'hg add')

The --files and --dirs options can be used to direct purge to delete only
files, only directories, or both. If neither option is given, both will be
deleted.

If directories are given on the command line, only files in these directories
are considered.

Be careful with purge, as you could irreversibly delete some files you forgot
to add to the repository. If you only want to print the list of files that
this program would delete, use the --print option.
";

pub fn args() -> clap::Command {
    clap::command!("purge")
        .alias("clean")
        .arg(
            Arg::new("abort_on_error")
                .help("abort if an error occurs")
                .short('a')
                .long("abort-on-error")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("all")
                .help("purge ignored files too")
                .long("all")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("ignored")
                .help("purge only ignored files")
                .short('i')
                .long("ignored")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("dirs")
                .help("purge empty directories")
                .long("dirs")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("files")
                .help("purge files")
                .long("files")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("print")
                .help("print filenames instead of deleting them")
                .short('p')
                .long("print")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("print0")
                .help("end filenames with NUL, for use with xargs (implies -p/--print)")
                .short('0')
                .long("print0")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("confirm")
                .help("ask before permanently deleting files")
                .long("confirm")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("no-confirm")
                .help("don't ask before permanently deleting files")
                .long("no-confirm")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("verbose")
                .help("enable additional output")
                .short('v')
                .action(clap::ArgAction::SetTrue)
                .long("verbose"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let ui = invocation.ui;
    let args = invocation.subcommand_args;

    let repo = invocation.repo?;

    let abort_on_error = args.get_flag("abort_on_error");
    let all = args.get_flag("all");
    let ignored = args.get_flag("ignored");
    let mut remove_dirs = args.get_flag("dirs");
    let mut remove_files = args.get_flag("files");
    let print = args.get_flag("print");
    let print0 = args.get_flag("print0");
    let verbose = args.get_flag("verbose");

    let confirm = if args.get_flag("confirm") {
        true
    } else if args.get_flag("no-confirm") {
        false
    } else {
        invocation.config.get(b"extensions", b"purge").is_none()
    };

    if confirm {
        return Err(CommandError::unsupported(
            "rhg purge does not support --confirm",
        ));
    }

    let act = !(print || print0);

    let unknown = !ignored || all;
    let ignored = ignored || all;

    if !(remove_dirs || remove_files) {
        remove_dirs = true;
        remove_files = true;
    }

    let mut dmap = repo.dirstate_map_mut()?;

    let check_exec = hg::checkexec::check_exec(repo.working_directory_path());

    let options = StatusOptions {
        check_exec,
        list_clean: false,
        list_unknown: unknown,
        list_ignored: ignored,
        list_copies: false,
        collect_traversed_dirs: true,
        empty_dirs_keep_files: !remove_files,
    };

    type StatusResult<'a> = Result<DirstateStatus<'a>, StatusError>;
    let after_status = |res: StatusResult,
                        warnings: HgWarningContext|
     -> Result<_, CommandError> {
        print_warnings(ui, warnings, repo.working_directory_path());

        let ds_status = res?;

        let mut files_to_remove = ds_status
            .ignored
            .into_iter()
            .chain(ds_status.unknown)
            .collect::<Vec<_>>();

        let mut dirs_to_remove = ds_status.empty_dirs;

        files_to_remove.sort();

        dirs_to_remove.sort();
        dirs_to_remove.reverse();

        if remove_files {
            // TODO: This loop can be parallelized.
            for file in files_to_remove {
                if act {
                    let path = hg_path_to_path_buf(&*file.path)?;

                    if verbose {
                        ui.write_stdout(&format_bytes!(
                            b"removing file {}\n",
                            file.path.as_bytes()
                        ))?;
                    }

                    match repo.working_directory_vfs().unlink(&path) {
                        Ok(()) => {}
                        Err(e) if abort_on_error => {
                            return Err(CommandError::abort(e.to_string()));
                        }
                        Err(e) => {
                            ui.write_stderr(&format_bytes!(
                                b"{}\n",
                                e.to_string().as_bytes()
                            ))?;
                        }
                    }
                } else {
                    ui.write_stdout(&format_bytes!(
                        b"{}\n",
                        file.path.as_bytes()
                    ))?;
                }
            }
        }

        if remove_dirs {
            for dir in dirs_to_remove {
                if act {
                    let path = hg_path_to_path_buf(&*dir)?;

                    if verbose {
                        ui.write_stdout(&format_bytes!(
                            b"removing directory {}\n",
                            *dir.as_bytes()
                        ))?;
                    }

                    match std::fs::remove_dir(
                        repo.working_directory_path().join(path),
                    ) {
                        Ok(()) => {}
                        Err(e) if abort_on_error => {
                            return Err(CommandError::abort(e.to_string()));
                        }
                        Err(e) => {
                            ui.write_stderr(&format_bytes!(
                                b"{}\n",
                                e.to_string().as_bytes()
                            ))?;
                        }
                    }
                } else {
                    ui.write_stdout(&format_bytes!(b"{}\n", *dir.as_bytes()))?;
                }
            }
        }

        Ok(())
    };

    let warning_context = HgWarningContext::new();
    let warnings_sender = warning_context.sender();

    let narrow_matcher = narrow::matcher(repo, warnings_sender)?;
    let sparse_matcher = sparse::matcher(repo, None, warnings_sender)?;
    // Sparse is only applicable for the working copy, not history.

    let matcher = match (repo.has_narrow(), repo.has_sparse()) {
        (true, true) => {
            Box::new(IntersectionMatcher::new(narrow_matcher, sparse_matcher))
        }
        (true, false) => narrow_matcher,
        (false, true) => sparse_matcher,
        (false, false) => Box::new(AlwaysMatcher),
    };

    dmap.with_status(
        &matcher,
        repo.working_directory_path().to_owned(),
        get_ignore_files(repo),
        options,
        after_status,
    )?;

    Ok(())
}
