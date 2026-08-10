use std::io::Write;

use clap::Parser;
use format_bytes::format_bytes;
use hg::exit_codes;
use jif::commands;
use jif::error::CommandError;
use jif::utils::RepoInvocation;
#[cfg(feature = "full-tracing")]
use tracing_chrome::ChromeLayerBuilder;
#[cfg(feature = "full-tracing")]
use tracing_chrome::FlushGuard;
use tracing_subscriber::EnvFilter;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::fmt::format::FmtSpan;
use tracing_subscriber::prelude::*;

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

    #[cfg(feature = "full-tracing")]
    let chrome_layer_guard = setup_tracing();
    #[cfg(not(feature = "full-tracing"))]
    setup_tracing();

    let result = match args.command {
        Command::Status(args) => {
            let invocation = RepoInvocation::new();
            // TODO status should return a `CommandError` instead of panicking
            commands::status::run(invocation, args);
            Ok(())
        }
    };

    #[cfg(feature = "full-tracing")]
    // The `Drop` implementation doesn't flush, probably because it would be
    // too expensive in the general case? Not sure, but we want it.
    chrome_layer_guard.flush();
    #[cfg(feature = "full-tracing")]
    // Explicitly run `drop` here to wait for the writing thread to join
    // because `drop` may not be called when `std::process::exit` is called.
    drop(chrome_layer_guard);
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

#[cfg(feature = "full-tracing")]
/// Enable an env-filtered chrome-trace logger to a file.
/// Defaults to writing to `./trace-{unix epoch in micros}.json`, but can
/// be overridden via the `HG_TRACE_PATH` environment variable.
fn setup_tracing() -> FlushGuard {
    let mut chrome_layer_builder = ChromeLayerBuilder::new();
    // /!\ Keep in sync with rhg and hg-pyo3
    if let Ok(path) = std::env::var("HG_TRACE_PATH") {
        chrome_layer_builder =
            chrome_layer_builder.writer(hg::logging::SafeWriter::create(path));
    }
    let (chrome_layer, chrome_layer_guard) = chrome_layer_builder.build();
    tracing_subscriber::registry()
        .with(EnvFilter::from_default_env())
        .with(chrome_layer)
        .init();
    chrome_layer_guard
}

#[cfg(not(feature = "full-tracing"))]
/// Enable an env-filtered logger to stderr
fn setup_tracing() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .with_span_events(FmtSpan::CLOSE),
        )
        .with(EnvFilter::from_default_env())
        .init()
}
