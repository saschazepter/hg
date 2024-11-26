use crate::error::CommandError;
use clap::Arg;
use clap::ArgGroup;
use hg::operations::debug_data;
use hg::revlog::RevlogType;

pub const HELP_TEXT: &str = "
Dump the contents of a data file revision
";

pub fn args() -> clap::Command {
    clap::command!("debugdata")
        .arg(
            Arg::new("changelog")
                .help("open changelog")
                .short('c')
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            Arg::new("manifest")
                .help("open manifest")
                .short('m')
                .action(clap::ArgAction::SetTrue),
        )
        .group(
            ArgGroup::new("revlog")
                .args(["changelog", "manifest"])
                .required(true),
        )
        .arg(
            Arg::new("rev")
                .help("revision")
                .required(true)
                .value_name("REV"),
        )
        .about(HELP_TEXT)
}

#[logging_timer::time("trace")]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let args = invocation.subcommand_args;
    let rev = args
        .get_one::<String>("rev")
        .expect("rev should be a required argument");
    let kind = match (
        args.get_one::<bool>("changelog").unwrap(),
        args.get_one::<bool>("manifest").unwrap(),
    ) {
        (true, false) => RevlogType::Changelog,
        (false, true) => RevlogType::Manifestlog,
        (true, true) => {
            unreachable!("Should not happen since options are exclusive")
        }
        (false, false) => {
            unreachable!("Should not happen since options are required")
        }
    };

    let repo = invocation.repo?;
    if repo.has_narrow() {
        return Err(CommandError::unsupported(
            "support for ellipsis nodes is missing and repo has narrow enabled",
        ));
    }
    let data = debug_data(repo, rev, kind)?;

    let mut stdout = invocation.ui.stdout_buffer();
    stdout.write_all(&data)?;
    stdout.flush()?;

    Ok(())
}
