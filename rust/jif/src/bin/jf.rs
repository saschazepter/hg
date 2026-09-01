use std::io::Write;

use clap::Parser;
use format_bytes::format_bytes;
use hg::exit_codes;
use jif::commands;
use jif::error::CommandError;
use jif::utils::RepoInvocation;

#[derive(clap::Subcommand)]
enum Command {
    Status(commands::status::Args),
}

#[derive(clap::Parser)]
#[command(infer_subcommands = true)]
struct Args {
    #[command(subcommand)]
    command: Command,
}

fn main() {
    let args = Args::parse();
    let result = match args.command {
        Command::Status(args) => {
            let invocation = RepoInvocation::new();
            // TODO status should return a `CommandError` instead of panicking
            commands::status::run(invocation, args);
            Ok(())
        }
    };
    exit(result)
}

/// Report `result` on stderr, if there is anything to report, and exit with the
/// relevant exit code.
fn exit(result: Result<(), CommandError>) -> ! {
    match &result {
        Ok(()) => {}
        Err(CommandError::Abort { message, hint, .. }) => {
            // Ignore errors when writing to stderr, we’re already exiting with
            // failure code so there’s not much more we can do.
            if !message.is_empty() {
                // TODO use `ui` to write to stderr
                let _ = std::io::stderr()
                    .write_all(&format_bytes!(b"abort: {}\n", message));
            }
            if let Some(hint) = hint {
                let _ = std::io::stderr()
                    .write_all(&format_bytes!(b"({})\n", hint));
            }
        }
    }
    std::process::exit(exit_code(&result))
}

fn exit_code(result: &Result<(), CommandError>) -> i32 {
    match result {
        Ok(()) => exit_codes::OK,
        Err(CommandError::Abort { .. }) => {
            // Ignore `detailed_exit_code` for now since we aren't reading the
            // `ui.detailed-exit-code` config yet.
            exit_codes::ABORT
        }
    }
}
