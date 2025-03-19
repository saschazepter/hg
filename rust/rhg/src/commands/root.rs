use crate::error::CommandError;
use clap::Arg;
use format_bytes::format_bytes;
use hg::errors::{IoErrorContext, IoResultExt};
use hg::utils::files::get_bytes_from_path;

pub const HELP_TEXT: &str = "
Print the root directory of the current repository.

Returns 0 on success.
";

pub fn args() -> clap::Command {
    clap::command!("root")
        .arg(
            Arg::new("share-source")
                .long("share-source")
                .action(clap::ArgAction::SetTrue)
                .help("print the share source root instead"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let share_source = invocation.subcommand_args.get_flag("share-source");
    let repo = invocation.repo?;
    let shared_repo;
    let working_directory = (if share_source {
        let store_path = repo.store_path();
        let shared_path = crate::Repo::find_repo_root_from(store_path)?;
        shared_repo = crate::Repo::find(repo.config(), Some(shared_path))?;
        &shared_repo
    } else {
        repo
    })
    .working_directory_path();
    let working_directory = std::fs::canonicalize(working_directory)
        .with_context(|| {
            IoErrorContext::CanonicalizingPath(working_directory.to_owned())
        })?;
    let bytes = get_bytes_from_path(working_directory);
    invocation
        .ui
        .write_stdout(&format_bytes!(b"{}\n", bytes.as_slice()))?;
    Ok(())
}
