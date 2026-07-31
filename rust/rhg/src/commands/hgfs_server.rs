//! `hgfs_server` is the hg virtual-filesystem control server.

use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::Request;
use tonic::Response;
use tonic::Status;
use tonic::transport::Server;
use vfs_api::DEFAULT_SOCKET;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::HealthResponse;
use vfs_api::vfs::vfs_control_server::VfsControl;
use vfs_api::vfs::vfs_control_server::VfsControlServer;

use crate::error::CommandError;

pub const HELP_TEXT: &str =
    "Run the hg virtual filesystem control server (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::hgfs-server").about(HELP_TEXT)
}

/// gRPC service implementing the `VfsControl` interface.
struct VfsControlService;

#[tonic::async_trait]
impl VfsControl for VfsControlService {
    async fn health(
        &self,
        _req: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse {
            version: env!("CARGO_PKG_VERSION").to_string(),
            pid: std::process::id(),
        }))
    }
}

pub fn run(_invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    serve().map_err(|e| {
        CommandError::abort(format!("abort: hgfs-server error: {e}"))
    })
}

#[tokio::main]
async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let listener = UnixListener::bind(DEFAULT_SOCKET)?;
    println!("hgfs-server listening on {DEFAULT_SOCKET}");

    Server::builder()
        .add_service(VfsControlServer::new(VfsControlService))
        .serve_with_incoming(UnixListenerStream::new(listener))
        .await?;

    Ok(())
}
