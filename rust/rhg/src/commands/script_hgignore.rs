use clap::Arg;
use hg::matchers::ReSyntax;

use crate::error::CommandError;

use super::debugignorerhg::WhichPatterns;

pub const HELP_TEXT: &str = "
Show effective hgignore patterns used by rhg.

This is a pure Rust version of `hg debugignore`.

Some options might be missing, check the list below.
";

pub fn args() -> clap::Command {
    clap::command!("script::hgignore")
    .arg(
        Arg::new("print-re")
            .help("Print the regular expression that matches all ignored files.")
            .action(clap::ArgAction::SetTrue)
            .long("print-re"),
    ).about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let repo = invocation.repo?;
    let args = invocation.subcommand_args;
    let print_re = args.get_flag("print-re");
    if !print_re {
        return Err(CommandError::unsupported(
            "Unsupported invocation: flag --print-re is required",
        ));
    }

    crate::commands::debugignorerhg::work(
        repo,
        invocation.ui,
        WhichPatterns::All,
        ReSyntax::Tidy,
    )
}
