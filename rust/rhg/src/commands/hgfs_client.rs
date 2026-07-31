//! `hgfs_client` is the client that interacts with the hg virtual-filesystem
//! control server (`hgfs_server`).

use clap::Arg;
use clap::Command;
use vfs_api::DEFAULT_SOCKET_URI;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::vfs_control_client::VfsControlClient;

use crate::error::CommandError;

pub const HELP_TEXT: &str =
    "Query the hg virtual filesystem control server (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::hgfs-client")
        .about(HELP_TEXT)
        .subcommand_required(true)
        .subcommand(Command::new("health").about("ping the server"))
        .subcommand(
            Command::new("mount")
                .about("mount a clone's virtual filesystem")
                .arg(
                    Arg::new("clone")
                        .long("clone")
                        .required(true)
                        .help("path to the clone to serve"),
                )
                .arg(
                    Arg::new("mount")
                        .long("mount")
                        .required(true)
                        .help("path to mount the virtual filesystem at"),
                ),
        )
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let (name, _sub_args) = invocation
        .subcommand_args
        .subcommand()
        .expect("subcommand is required");

    dispatch(name).map_err(|e| {
        CommandError::abort(format!("abort: hgfs-client error: {e}"))
    })
}

#[tokio::main]
async fn dispatch(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    match name {
        "health" => {
            let mut client =
                VfsControlClient::connect(DEFAULT_SOCKET_URI).await?;
            let resp = client.health(HealthRequest {}).await?.into_inner();
            println!("Health: version={} pid={}", resp.version, resp.pid);
        }
        "mount" => {
            println!("hgfs-client mount: not implemented yet");
        }
        other => return Err(format!("unknown subcommand: {other}").into()),
    }
    Ok(())
}
