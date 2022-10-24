use std::os::unix::prelude::OsStrExt;

use crate::error::CommandError;
use clap::SubCommand;
use hg::{self, utils::hg_path::HgPath};

pub const HELP_TEXT: &str = "";

pub fn args() -> clap::App<'static, 'static> {
    SubCommand::with_name("debugrhgsparse")
        .arg(
            clap::Arg::with_name("files")
                .required(true)
                .multiple(true)
                .empty_values(false)
                .value_name("FILES")
                .help("Files to check against sparse profile"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let repo = invocation.repo?;

    let (matcher, _warnings) = hg::sparse::matcher(&repo).unwrap();
    let files = invocation.subcommand_args.values_of_os("files");
    if let Some(files) = files {
        for file in files {
            invocation.ui.write_stdout(b"matches: ")?;
            invocation.ui.write_stdout(
                if matcher.matches(HgPath::new(file.as_bytes())) {
                    b"yes"
                } else {
                    b"no"
                },
            )?;
            invocation.ui.write_stdout(b" | file: ")?;
            invocation.ui.write_stdout(file.as_bytes())?;
            invocation.ui.write_stdout(b"\n")?;
        }
    }
    Ok(())
}
