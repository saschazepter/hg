use crate::error::CommandError;
use clap::Arg;
use format_bytes::format_bytes;
use hg::errors::HgError;
use hg::utils::strings::SliceExt;

pub const HELP_TEXT: &str = "
With one argument of the form section.name, print just the value of that config item.
";

pub fn args() -> clap::Command {
    clap::command!("config")
        .arg(
            Arg::new("name")
                .help("the section.name to print")
                .value_name("NAME")
                .required(true),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let (section, name) = invocation
        .subcommand_args
        .get_one::<String>("name")
        .expect("missing required CLI argument")
        .as_bytes()
        .split_2(b'.')
        .ok_or_else(|| HgError::unsupported("hg config <section>"))?;

    if let Some(value) = invocation.config.get(section, name) {
        invocation.ui.write_stdout(&format_bytes!(b"{}\n", value))?;
        Ok(())
    } else {
        Err(CommandError::Unsuccessful)
    }
}
