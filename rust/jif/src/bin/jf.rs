use clap::Parser;
use jif::commands;
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
    match args.command {
        Command::Status(args) => {
            let invocation = RepoInvocation::new();
            commands::status::run(invocation, args)
        }
    }
}
