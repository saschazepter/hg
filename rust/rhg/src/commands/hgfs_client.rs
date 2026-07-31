//! `hgfs_client` is the client that interacts with the hg virtual-filesystem
//! control server (`hgfs_server`).

use vfs_api::DEFAULT_SOCKET_URI;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::vfs_control_client::VfsControlClient;

use crate::error::CommandError;

pub const HELP_TEXT: &str =
    "Query the hg virtual filesystem control server (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::hgfs-client").about(HELP_TEXT)
}

pub fn run(_invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    call_health().map_err(|e| {
        CommandError::abort(format!("abort: hgfs-client error: {e}"))
    })
}

#[tokio::main]
async fn call_health() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = VfsControlClient::connect(DEFAULT_SOCKET_URI).await?;
    let resp = client.health(HealthRequest {}).await?.into_inner();
    println!("Health: version={} pid={}", resp.version, resp.pid);
    Ok(())
}
