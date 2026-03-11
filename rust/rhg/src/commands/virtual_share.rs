use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;

use clap::Arg;
use hg::errors::IoResultExt;
use hg_fuse::fuse::HgFuse;
use hg_fuse::server::Server;
use libc::SIGHUP;
use libc::SIGINT;
use libc::SIGTERM;

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
        .arg(
            Arg::new("pid-file")
                .long("pid-file")
                .value_parser(clap::value_parser!(std::ffi::OsString))
                .help("path to write this process' ID to"),
        )
        .arg(
            Arg::new("user-id")
                .long("public-fuse-user-id")
                .value_parser(clap::value_parser!(u32))
                .help("override the uid/gid and session ACL"),
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

    if let Some(pid_file) =
        invocation.subcommand_args.get_one::<std::ffi::OsString>("pid-file")
    {
        let pid_line = format!("{}\n", std::process::id());
        std::fs::write(pid_file, pid_line).when_writing_file(pid_file)?
    };

    let user_id = invocation.subcommand_args.get_one("user-id").copied();
    let server = Server::new(repo, user_id)?;

    // Set up non-fatal signals to break our loop
    let should_terminate = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(SIGINT, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");
    signal_hook::flag::register(SIGTERM, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");
    signal_hook::flag::register(SIGHUP, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");

    // Dropping this handle will unmount the filesystem
    let session = HgFuse::mount(server, destination, user_id.is_some())?;
    loop {
        std::thread::sleep(Duration::from_millis(250));
        let was_unmounted = session.guard.is_finished();
        let was_terminated = should_terminate.load(Ordering::Relaxed);
        if was_unmounted || was_terminated {
            break;
        }
    }
    Ok(())
}
