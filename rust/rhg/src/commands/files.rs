use clap::Arg;
use hg::filepatterns::parse_pattern_args;
use hg::matchers::IntersectionMatcher;
use hg::narrow;
use hg::operations::list_revset_tracked_files;
use hg::repo::Repo;
use hg::utils::files::get_bytes_from_os_str;
use hg::utils::filter_map_results;
use hg::utils::hg_path::HgPath;
use hg::warnings::format::write_warning;
use hg::warnings::HgWarningContext;
use rayon::prelude::*;

use crate::error::CommandError;
use crate::ui::relative_paths;
use crate::ui::RelativePaths;
use crate::ui::Ui;
use crate::utils::path_utils::RelativizePaths;

pub const HELP_TEXT: &str = "
List tracked files.

Returns 0 on success.
";

pub fn args() -> clap::Command {
    clap::command!("files")
        .args_override_self(true)
        .arg(
            Arg::new("rev")
                .help("search the repository as it is in REV")
                .short('r')
                .long("rev")
                .value_name("REV"),
        )
        .arg(
            Arg::new("file")
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("show only these files")
                .action(clap::ArgAction::Append),
        )
        .arg(
            Arg::new("print0")
                .required(false)
                .short('0')
                .long("print0")
                .action(clap::ArgAction::SetTrue)
                .help("end filenames with NUL, for use with xargs"),
        )
        .about(HELP_TEXT)
}

#[tracing::instrument(level = "debug", skip_all, name = "rhg files")]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let relative_paths = match relative_paths(invocation.config)? {
        RelativePaths::Legacy => true,
        RelativePaths::Bool(v) => v,
    };

    let args = invocation.subcommand_args;
    let rev = args.get_one::<String>("rev");
    let delimiter = if args.get_flag("print0") {
        b"\0"
    } else {
        b"\n"
    };

    let repo = invocation.repo?;

    // It seems better if this check is removed: this would correspond to
    // automatically enabling the extension if the repo requires it.
    // However we need this check to be in sync with vanilla hg so hg tests
    // pass.
    if repo.has_sparse()
        && invocation.config.get(b"extensions", b"sparse").is_none()
    {
        return Err(CommandError::unsupported(
            "repo is using sparse, but sparse extension is not enabled",
        ));
    }

    let warning_context = HgWarningContext::new();
    let matcher = narrow::matcher(repo, warning_context.sender())?;

    let mut stderr = invocation.ui.stderr_locked();
    // Can't really do anything if writing to stderr failed
    let _ = warning_context.finish(|warning| {
        write_warning(&warning, &mut stderr, repo.working_directory_path())
    });

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
            let file_patterns = parse_pattern_args(patterns, &cwd, root)?;
            let files_matcher =
                hg::matchers::PatternMatcher::new(file_patterns)?;
            Box::new(IntersectionMatcher::new(Box::new(files_matcher), matcher))
        }
    };

    if let Some(rev) = rev {
        let files = list_revset_tracked_files(repo, rev, matcher)?;
        display_files(
            invocation.ui,
            repo,
            relative_paths,
            delimiter,
            files.iter().map::<Result<_, CommandError>, _>(|f| {
                let (f, _, _) = f?;
                Ok(f)
            }),
        )
    } else {
        // The dirstate always reflects the sparse narrowspec.
        let dirstate = repo.dirstate_map()?;
        let files_res: Result<Vec<_>, _> =
            filter_map_results(dirstate.iter(), |(path, entry)| {
                Ok(if entry.tracked() && matcher.matches(path) {
                    Some(path)
                } else {
                    None
                })
            })
            .collect();

        let mut files = files_res?;
        files.par_sort_unstable();

        display_files(
            invocation.ui,
            repo,
            relative_paths,
            delimiter,
            files.into_iter().map::<Result<_, CommandError>, _>(Ok),
        )
    }
}

fn display_files<'a, E>(
    ui: &Ui,
    repo: &Repo,
    relative_paths: bool,
    delimiter: &[u8],
    files: impl IntoIterator<Item = Result<&'a HgPath, E>>,
) -> Result<(), CommandError>
where
    CommandError: From<E>,
{
    let mut stdout = ui.stdout_buffer();
    let mut any = false;

    let relativize = RelativizePaths::new(repo)?;
    for result in files {
        let path = result?;
        if relative_paths {
            stdout.write_all(&relativize.relativize(path))?;
        } else {
            stdout.write_all(path.as_bytes())?;
        }
        stdout.write_all(delimiter)?;
        any = true;
    }

    stdout.flush()?;
    if any {
        Ok(())
    } else {
        Err(CommandError::Unsuccessful)
    }
}
