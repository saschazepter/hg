use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;
use std::time::Duration;

use clap::Arg;
use clap::builder::EnumValueParser;
use fuser::SessionACL;
use hg::errors::IoResultExt;
use hg::repo::Repo;
use hg_fuse::fuse::HgFuse;
use hg_fuse::server::store::BackendMode;
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
                .long("user-id")
                .value_parser(clap::value_parser!(u32))
                .help("override the uid"),
        )
        .arg(
            Arg::new("group-id")
                .long("group-id")
                .value_parser(clap::value_parser!(u32))
                .help("override the gid"),
        )
        .arg(
            Arg::new("max-revisions-loaded")
                .long("max-revisions-loaded")
                .value_parser(clap::value_parser!(usize))
                .help("maximum number of revisions to keep loaded"),
        )
        .arg(
            Arg::new("open-to-all")
                .long("open-to-all")
                .action(clap::ArgAction::SetTrue)
                .help("allow requests from any user"),
        )
        .arg(
            Arg::new("open-to-root")
                .long("open-to-root")
                .action(clap::ArgAction::SetTrue)
                .help("allow requests from the filesystem owner and root")
                .conflicts_with("open-to-all"),
        )
        .arg(
            Arg::new("backend-mode")
                .long("backend-mode")
                .value_parser(EnumValueParser::<BackendMode>::new())
                .help("what type of working copy to present"),
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
    let group_id = invocation.subcommand_args.get_one("group-id").copied();
    let max_revisions_loaded =
        invocation.subcommand_args.get_one("max-revisions-loaded").copied();
    let open_to_all = invocation.subcommand_args.get_flag("open-to-all");
    let open_to_root = invocation.subcommand_args.get_flag("open-to-root");
    let backend_mode: BackendMode = invocation
        .subcommand_args
        .get_one::<BackendMode>("backend-mode")
        .copied()
        .unwrap_or_default();
    let session_acl = if open_to_all {
        SessionACL::All
    } else if open_to_root {
        SessionACL::RootAndOwner
    } else {
        SessionACL::Owner
    };
    // Recreate an owned repo for the backend
    let backend_repo = Repo::find(
        repo.config(),
        Some(repo.working_directory_path().to_path_buf()),
    )?;
    // Set up non-fatal signals to break our loop
    let should_terminate = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(SIGINT, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");
    signal_hook::flag::register(SIGTERM, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");
    signal_hook::flag::register(SIGHUP, Arc::clone(&should_terminate))
        .expect("signal should be valid to register");

    // Dropping this handle will unmount the filesystem
    let session = HgFuse::mount_all_revs(
        backend_repo,
        destination,
        backend_mode,
        user_id,
        group_id,
        max_revisions_loaded,
        session_acl,
    )?;
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
