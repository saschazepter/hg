//! Rust "front-desk" for mercurial
//!
//! This executable offers a binary entry point for Mercurial's `hg` command
//! line tool. It currently doesn't do much but will grow to run low-latency
//! logic that needs to run before calling the main codebase in Python (or skip
//! doing so in some cases). Usages include:
//! - adjusting the module policy (e.g. using Rust extensions of not) based on
//!   config,
//! - using "deamonized" version of Mercurial where a pure binary thin client
//!   talks to a longer running Mercurial background process when configured to
//!   do so,
//! - using pure Rust fast path for some commands when applicable and configured
//!   to do so,
//! - adjusting how the Python process runs on Windows (e.g. binary IO mode).

use std::os::unix::process::CommandExt;

fn main() {
    let mut args = std::env::args_os();
    let _ = args.next().expect("No argv[0]?");
    let this_exec = std::env::current_exe()
        .expect("failed to retrieve current executable path");
    let exec_path = match this_exec.canonicalize() {
        Ok(p) => p,
        Err(err) => {
            eprintln!(
                "Failed to canonicalize hg-bin path: {}",
                this_exec.display()
            );
            eprintln!("{}", err);
            std::process::exit(254);
        }
    };
    let exec_dir = exec_path.parent().expect("binary not in a directory?");
    let hg_py = exec_dir.join(".__hg_internal__");
    let mut command = std::process::Command::new(&hg_py);
    command.args(args);
    let err = command.exec();
    eprintln!(
        "Could not start Python's Mercurial binary at: {}",
        hg_py.display()
    );
    eprintln!("{}", err);
    std::process::exit(254);
}
