use std::io::Read;

use hg::errors::IoResultExt;
use hg::narrow::patterns_from_spec;
use hg::narrow::shape::ShardTreeNode;
use hg::utils::strings::SliceExt;
use hg::warnings::HgWarningContext;

use crate::error::CommandError;

pub const HELP_TEXT: &str = "
Temporary debug command to help the transition from old narrow to new
shape-based narrow
";

pub fn args() -> clap::Command {
    clap::command!("debug::narrow-fingerprint").about(HELP_TEXT)
}

#[tracing::instrument(
    level = "debug",
    skip_all,
    name = "rhg debug::narrow-fingerprint"
)]
pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let warning_context = HgWarningContext::new();

    let mut spec = vec![];
    std::io::stdin().read_to_end(&mut spec).when_reading_file("stdin")?;
    if spec.is_empty() {
        return Err(CommandError::abort("empty narrowspec given"));
    }
    let mut stdout = invocation.ui.stdout_buffer();

    let patterns = patterns_from_spec(warning_context.sender(), &spec)?;
    let (includes, excludes) = patterns.unwrap_or((vec![], vec![]));
    let tree = ShardTreeNode::from_patterns(&includes, &excludes)?;
    stdout.write_all(&tree.fingerprint().to_hex_bytes())?;
    stdout.write_all(b"\n")?;

    stdout.flush()?;

    Ok(())
}
