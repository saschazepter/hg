use clap::Arg;
use hg::narrow::patterns_from_spec;
use hg::narrow::shape::ShardTreeNode;
use hg::narrow::store_spec;
use hg::utils::strings::SliceExt;
use hg::warnings::HgWarningContext;

use crate::error::CommandError;
use crate::ui::print_warnings;

pub const HELP_TEXT: &str = "
Narrow-related administration utils
";

pub fn args() -> clap::Command {
    clap::command!("admin::narrow")
        .arg(
            Arg::new("store-fingerprint")
                .long("store-fingerprint")
                .help("get the fingerprint for this repo's store narrospec")
                .action(clap::ArgAction::SetTrue),
        )
        .about(HELP_TEXT)
}

#[tracing::instrument(level = "debug", skip_all, name = "rhg admin::narrow")]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let args = invocation.subcommand_args;
    let store_fingerprint = args.get_one::<bool>("store-fingerprint");
    if store_fingerprint.is_none() {
        return Err(CommandError::unsupported(
            "rhg only supports --store-fingerprint",
        ));
    }

    let repo = invocation.repo?;
    if !repo.has_narrow() {
        return Err(CommandError::abort(
            "abort: repo does not have narrow enabled",
        ));
    }
    let spec = store_spec(repo)?;

    let warning_context = HgWarningContext::new();
    let patterns = patterns_from_spec(warning_context.sender(), &spec)?;
    let (includes, excludes) = patterns.unwrap_or((vec![], vec![]));
    let tree = ShardTreeNode::from_patterns(&includes, &excludes)?;

    print_warnings(
        invocation.ui,
        warning_context,
        repo.working_directory_path(),
    );

    let mut stdout = invocation.ui.stdout_buffer();
    stdout.write_all(&tree.fingerprint().to_hex_bytes())?;
    stdout.flush()?;

    Ok(())
}
