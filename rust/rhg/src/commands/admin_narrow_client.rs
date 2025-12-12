use clap::Arg;
use hg::narrow::shape::ShardTreeNode;
use hg::narrow::store_patterns;
use hg::utils::strings::SliceExt;
use hg::warnings::HgWarningContext;

use crate::error::CommandError;
use crate::ui::print_warnings;

pub const HELP_TEXT: &str = "
Narrow-related administration utils (EXPERIMENTAL)
";

pub fn args() -> clap::Command {
    clap::command!("admin::narrow-client")
        .arg(
            Arg::new("store-fingerprint")
                .long("store-fingerprint")
                .help("get the fingerprint for this repo's store narrospec")
                .action(clap::ArgAction::SetTrue),
        )
        .about(HELP_TEXT)
}

#[tracing::instrument(
    level = "debug",
    skip_all,
    name = "rhg admin::narrow-client"
)]
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
            "abort: this command only makes sense in a narrow clone",
        ));
    }

    let warning_context = HgWarningContext::new();
    let patterns = store_patterns(warning_context.sender(), repo)?;
    let (includes, excludes) = patterns.unwrap_or((vec![], vec![]));
    let tree = ShardTreeNode::from_patterns(&includes, &excludes)?;

    print_warnings(
        invocation.ui,
        warning_context,
        repo.working_directory_path(),
    );

    let mut stdout = invocation.ui.stdout_buffer();
    stdout.write_all(&tree.fingerprint().to_hex_bytes())?;
    stdout.write_all(b"\n")?;
    stdout.flush()?;

    Ok(())
}
