#[cfg(not(feature = "full-tracing"))]
use std::io::IsTerminal;

use clap::Parser;
use hg::exit_codes;
use jif::commands;
use jif::error::CommandError;
use jif::output::Format;
use jif::output::Output;
use jif::utils::RepoInvocation;
#[cfg(feature = "full-tracing")]
use tracing_chrome::ChromeLayerBuilder;
#[cfg(feature = "full-tracing")]
use tracing_chrome::FlushGuard;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::filter::LevelFilter;
#[cfg(not(feature = "full-tracing"))]
use tracing_subscriber::fmt::format::FmtSpan;
use tracing_subscriber::prelude::*;

#[derive(clap::Subcommand)]
enum Command {
    HgfsClient(commands::hgfs_client::Args),
    HgfsServer(commands::hgfs_server::Args),
    Status(commands::status::Args),
}

#[derive(clap::Parser)]
#[command(infer_subcommands = true)]
struct Args {
    /// Write output in this format, for machines
    /// XXX Structured output will be limited to namespaced `tool::` commands
    /// in the future, but this is useful to show the scaffolding.
    #[arg(long, global = true, value_enum)]
    do_not_use_format: Option<Format>,
    #[command(subcommand)]
    command: Command,
}

fn main() {
    let args = Args::parse();
    let output = Output::std(args.do_not_use_format);

    #[cfg(feature = "full-tracing")]
    let chrome_layer_guard = setup_tracing();
    #[cfg(not(feature = "full-tracing"))]
    setup_tracing();

    let result = match args.command {
        Command::HgfsClient(args) => commands::hgfs_client::run(args, &output),
        Command::HgfsServer(args) => commands::hgfs_server::run(args, &output),
        Command::Status(args) => RepoInvocation::new()
            .map(|invocation| commands::status::run(invocation, args, &output)),
    };

    #[cfg(feature = "full-tracing")]
    // The `Drop` implementation doesn't flush, probably because it would be
    // too expensive in the general case? Not sure, but we want it.
    chrome_layer_guard.flush();
    #[cfg(feature = "full-tracing")]
    // Explicitly run `drop` here to wait for the writing thread to join
    // because `drop` may not be called when `std::process::exit` is called.
    drop(chrome_layer_guard);
    exit(result, &output)
}

/// Report `result` if it is an error, and exit with the relevant exit code.
fn exit(result: Result<(), CommandError>, output: &Output) -> ! {
    if let Err(error) = &result {
        output.error(error);
    }
    std::process::exit(exit_code(&result))
}

fn exit_code(result: &Result<(), CommandError>) -> i32 {
    match result {
        Ok(()) => exit_codes::OK,
        Err(_) => exit_codes::ABORT,
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
    tracing_subscriber::registry().with(env_filter()).with(chrome_layer).init();
    chrome_layer_guard
}

#[cfg(not(feature = "full-tracing"))]
/// Enable an env-filtered logger to stderr
#[allow(clippy::disallowed_methods)] // Logs are for developers, not machines
fn setup_tracing() {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .with_ansi(std::io::stderr().is_terminal())
                .with_span_events(FmtSpan::CLOSE),
        )
        .with(env_filter())
        .init()
}

/// Logs are for developers, so they are off unless `RUST_LOG` asks for them
fn env_filter() -> EnvFilter {
    EnvFilter::builder()
        .with_default_directive(LevelFilter::OFF.into())
        .from_env_lossy()
}
