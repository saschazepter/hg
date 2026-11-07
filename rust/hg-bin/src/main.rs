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
//!
//! The `HGDAEMONIZEPOLICY` environment variable and the `[policy] daemonize`
//! configuration control the use of a long running command server through
//! the chg client logic (see the `chg` module). The configuration is only
//! read below the repository level (system and user level). The possible
//! values are:
//!
//! - `never`:   always start a fresh Python process,
//! - `always`:  use daemonization, but abort when chg support is missing,
//! - `auto`:    use daemonization when available,
//! - `default`: defer to the next policy source: the environment defers to the
//!   configuration, the configuration to the built-in default (`never`, for
//!   now).
//!
//! An unset or empty environment variable, like a missing or empty
//! configuration item, is read as `default`; an unrecognized value is read
//! as `never`.

mod chg;
mod policy;

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

    // The features read their policies from the non-repository configuration
    // (system and user levels). One that cannot be loaded reads as empty:
    // every feature then falls back to its built-in default, and the Python
    // code reports the error in due time.
    let config = hg::config::Config::load_non_repo()
        .unwrap_or_else(|_| hg::config::Config::empty());

    // run chg according to policy and availability
    if chg::enabled(&config) {
        chg::run(&hg_py)
    }

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
