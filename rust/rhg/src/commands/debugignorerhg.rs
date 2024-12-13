use crate::error::CommandError;
use crate::ui::Ui;
use clap::Arg;
use hg::dirstate::status::StatusError;
use hg::filepatterns::RegexCompleteness;
use hg::matchers::{get_ignore_matcher_pre, ReSyntax};
use hg::repo::Repo;
use log::warn;

pub const HELP_TEXT: &str = "
Show effective hgignore patterns used by rhg.

This is a pure Rust version of `hg debugignore`.

Some options might be missing, check the list below.
";

pub fn args() -> clap::Command {
    clap::command!("debugignorerhg")
    .arg(
        Arg::new("all-patterns")
            .help("include all patterns, including ones for exact file matches")
            .short('a')
            .action(clap::ArgAction::SetTrue)
            .long("all-patterns"),
    ).about(HELP_TEXT)
}

pub enum WhichPatterns {
    All,
    SlowPathOnly,
}

pub fn work(
    repo: &Repo,
    ui: &Ui,
    which: WhichPatterns,
    syntax: ReSyntax,
) -> Result<(), CommandError> {
    let ignore_file = repo.working_directory_vfs().join(".hgignore"); // TODO hardcoded
    let all_patterns = matches!(which, WhichPatterns::All);

    let (ignore_matcher, warnings) = get_ignore_matcher_pre(
        vec![ignore_file],
        repo.working_directory_path(),
        &mut |_source, _pattern_bytes| (),
    )
    .map_err(StatusError::from)?;

    let regex_config = if all_patterns {
        RegexCompleteness::Complete
    } else {
        RegexCompleteness::ExcludeExactFiles
    };
    let ignore_matcher = ignore_matcher
        .build_debug_matcher(regex_config)
        .map_err(StatusError::from)?;

    if !warnings.is_empty() {
        warn!("Pattern warnings: {:?}", &warnings);
    }

    let patterns = ignore_matcher.debug_get_patterns(syntax);
    ui.write_stdout(&patterns)?;
    ui.write_stdout(b"\n")?;
    Ok(())
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let repo = invocation.repo?;
    let args = invocation.subcommand_args;

    let all_patterns = args.get_flag("all-patterns");
    let patterns = if all_patterns {
        WhichPatterns::All
    } else {
        WhichPatterns::SlowPathOnly
    };

    work(repo, invocation.ui, patterns, ReSyntax::Internal)
}
