//! `hgfs_server` is the hg virtual-filesystem control server.

use std::sync::Arc;

use hg::config::Config;
use hg::errors::HgError;
use hg::repo::Repo;
use hg::utils::files::get_path_from_bytes;
use hg_vfs::BackendMode;
use hg_vfs::MountError;
use hg_vfs::MountManager;
use hg_vfs::MountOptions;
use hg_vfs::SessionACL;
use tokio::net::UnixListener;
use tokio::signal::unix::Signal;
use tokio::signal::unix::SignalKind;
use tokio::signal::unix::signal;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::Request;
use tonic::Response;
use tonic::Status;
use tonic::transport::Server;
use vfs_api::DEFAULT_SOCKET;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::HealthResponse;
use vfs_api::vfs::MountRequest;
use vfs_api::vfs::MountResponse;
use vfs_api::vfs::vfs_control_server::VfsControl;
use vfs_api::vfs::vfs_control_server::VfsControlServer;

use crate::error::CommandError;

pub const HELP_TEXT: &str =
    "Run the hg virtual filesystem control server (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::hgfs-server").about(HELP_TEXT)
}

/// gRPC service implementing the `VfsControl` interface.
struct VfsControlService {
    /// Shared registry of live mounts.
    manager: Arc<MountManager>,
    /// Non-repo config, loaded once at startup and reused for every mount.
    config: Arc<Config>,
}

#[tonic::async_trait]
impl VfsControl for VfsControlService {
    async fn health(
        &self,
        _req: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        tracing::info!("Health requested");
        Ok(Response::new(HealthResponse {
            version: env!("CARGO_PKG_VERSION").to_string(),
            pid: std::process::id(),
        }))
    }

    async fn mount(
        &self,
        req: Request<MountRequest>,
    ) -> Result<Response<MountResponse>, Status> {
        let request = req.into_inner();
        let clone_path = get_path_from_bytes(&request.clone_path).to_path_buf();
        let mount_point =
            get_path_from_bytes(&request.mount_point).to_path_buf();
        tracing::info!(
            clone_path = %clone_path.display(),
            mount_point = %mount_point.display(),
            "Mount requested"
        );

        let manager = Arc::clone(&self.manager);
        let config = Arc::clone(&self.config);
        let info = tokio::task::spawn_blocking(
            move || -> Result<hg_vfs::MountInfo, Status> {
                let repo = Repo::find(&config, Some(clone_path)).map_err(
                    |e| match e {
                        HgError::RepoNotFound { .. } => Status::not_found(
                            format!("no repository at clone path: {e}"),
                        ),
                        _ => Status::internal(format!("opening clone: {e}")),
                    },
                )?;
                manager
                    .mount_all_revs(repo, mount_point, default_mount_options())
                    .map_err(mount_error_to_status)
            },
        )
        .await
        .map_err(|e| Status::internal(format!("mount: {e}")))??;

        Ok(Response::new(to_proto_mount_info(info)))
    }
}

fn to_proto_mount_info(info: hg_vfs::MountInfo) -> MountResponse {
    MountResponse { created_at: info.created_at }
}

fn mount_error_to_status(e: MountError) -> Status {
    match e {
        MountError::AlreadyMounted(path, _) => Status::already_exists(format!(
            "already mounted at {}",
            path.display()
        )),
        MountError::Hg(e) => Status::internal(e.to_string()),
    }
}

fn default_mount_options() -> MountOptions {
    MountOptions {
        backend_mode: BackendMode::default(),
        session_acl: SessionACL::Owner,
        user_id: None,
        group_id: None,
        max_revisions_loaded: None,
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

    // Load the non-repo config once; every mount request reuses it.
    let config = Arc::new(
        Config::load_non_repo()
            .map_err(|e| format!("loading config: {e:?}"))?,
    );
    let manager = Arc::new(MountManager::new());
    let service = VfsControlService { manager, config };

    Server::builder()
        .add_service(VfsControlServer::new(service))
        .serve_with_incoming_shutdown(
            UnixListenerStream::new(listener),
            shutdown_signal(),
        )
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    fn listen(kind: SignalKind, name: &str) -> Option<Signal> {
        match signal(kind) {
            Ok(s) => Some(s),
            Err(e) => {
                tracing::error!("failed to create a listener for {name}: {e}");
                None
            }
        }
    }
    let (Some(mut sigterm), Some(mut sigint), Some(mut sighup)) = (
        listen(SignalKind::terminate(), "SIGTERM"),
        listen(SignalKind::interrupt(), "SIGINT"),
        listen(SignalKind::hangup(), "SIGHUP"),
    ) else {
        return;
    };
    tokio::select! {
        _ = sigterm.recv() => {}
        _ = sigint.recv() => {}
        _ = sighup.recv() => {}
    }
}
