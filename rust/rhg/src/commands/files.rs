use crate::error::CommandError;
use crate::ui::{print_narrow_sparse_warnings, Ui};
use crate::utils::path_utils::RelativizePaths;
use clap::Arg;
use hg::narrow;
use hg::operations::list_rev_tracked_files;
use hg::repo::Repo;
use hg::utils::filter_map_results;
use hg::utils::hg_path::HgPath;
use rayon::prelude::*;

pub const HELP_TEXT: &str = "
List tracked files.

Returns 0 on success.
";

pub fn args() -> clap::Command {
    clap::command!("files")
        .arg(
            Arg::new("rev")
                .help("search the repository as it is in REV")
                .short('r')
                .long("revision")
                .value_name("REV"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let relative = invocation.config.get(b"ui", b"relative-paths");
    if relative.is_some() {
        return Err(CommandError::unsupported(
            "non-default ui.relative-paths",
        ));
    }

    let rev = invocation.subcommand_args.get_one::<String>("rev");

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

    let (narrow_matcher, narrow_warnings) = narrow::matcher(repo)?;
    print_narrow_sparse_warnings(&narrow_warnings, &[], invocation.ui, repo)?;

    if let Some(rev) = rev {
        let files = list_rev_tracked_files(repo, rev, narrow_matcher)
            .map_err(|e| (e, rev.as_ref()))?;
        display_files(invocation.ui, repo, files.iter())
    } else {
        // The dirstate always reflects the sparse narrowspec.
        let dirstate = repo.dirstate_map()?;
        let files_res: Result<Vec<_>, _> =
            filter_map_results(dirstate.iter(), |(path, entry)| {
                Ok(if entry.tracked() && narrow_matcher.matches(path) {
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
            files.into_iter().map::<Result<_, CommandError>, _>(Ok),
        )
    }
}

fn display_files<'a, E>(
    ui: &Ui,
    repo: &Repo,
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
        stdout.write_all(&relativize.relativize(path))?;
        stdout.write_all(b"\n")?;
        any = true;
    }

    stdout.flush()?;
    if any {
        Ok(())
    } else {
        Err(CommandError::Unsuccessful)
    }
}
