use std::ffi::OsStr;
use std::ffi::OsString;
use std::os::unix::prelude::OsStrExt;

use hg::utils::hg_path::HgPath;
use hg::warnings::HgWarningContext;
use hg::{self};

use crate::error::CommandError;
use crate::ui::print_warnings;

pub const HELP_TEXT: &str = "";

pub fn args() -> clap::Command {
    clap::command!("debugrhgsparse")
        .arg(
            clap::Arg::new("files")
                .value_name("FILES")
                .required(true)
                .num_args(1..)
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("Files to check against sparse profile"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let repo = invocation.repo?;

    let warning_context = HgWarningContext::new();
    let matcher =
        hg::sparse::matcher(repo, None, warning_context.sender()).unwrap();

    print_warnings(
        invocation.ui,
        warning_context,
        repo.working_directory_path(),
    );
    let files = invocation.subcommand_args.get_many::<OsString>("files");
    if let Some(files) = files {
        let files: Vec<&OsStr> =
            files.filter(|s| !s.is_empty()).map(|s| s.as_os_str()).collect();
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
