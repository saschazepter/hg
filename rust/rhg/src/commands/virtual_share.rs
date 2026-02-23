use clap::Arg;
use hg_fuse::fuse::HgFuse;
use hg_fuse::server::Server;

use crate::error::CommandError;

pub const HELP_TEXT: &str = "Mount a virtual hg filesystem (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::virtual-share")
        .args_override_self(true)
        .arg(
            Arg::new("destination")
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("Path to mount the virtual share to"),
        )
        .about(HELP_TEXT)
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let repo = invocation.repo?;
    let Some(destination) =
        invocation.subcommand_args.get_one::<std::ffi::OsString>("destination")
    else {
        return Err(CommandError::abort("abort: destination not provided"));
    };

    let server = Server::new(repo)?;
    HgFuse::mount(server, destination)?;
    // TODO umount if SIGTERM
    Ok(())
}
