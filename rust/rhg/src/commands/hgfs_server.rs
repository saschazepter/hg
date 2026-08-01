//! `hgfs_server` is the hg virtual-filesystem control server.

use std::ffi::OsString;
use std::fs::File;
use std::fs::OpenOptions;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Arc;

use clap::Arg;
use hg::config::Config;
use hg::errors::HgError;
use hg::repo::Repo;
use hg::utils::files::get_bytes_from_path;
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
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::HealthResponse;
use vfs_api::vfs::ListMountsRequest;
use vfs_api::vfs::ListMountsResponse;
use vfs_api::vfs::MountInfo;
use vfs_api::vfs::MountRequest;
use vfs_api::vfs::UnmountRequest;
use vfs_api::vfs::UnmountResponse;
use vfs_api::vfs::vfs_control_server::VfsControl;
use vfs_api::vfs::vfs_control_server::VfsControlServer;

use crate::error::CommandError;

pub const HELP_TEXT: &str =
    "Run the hg virtual filesystem control server (EXPERIMENTAL)";

pub fn args() -> clap::Command {
    clap::command!("debug::hgfs-server").about(HELP_TEXT).arg(
        Arg::new("socket")
            .long("socket")
            .value_parser(clap::value_parser!(OsString))
            .help("path to the control socket to bind"),
    )
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
    ) -> Result<Response<MountInfo>, Status> {
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

    async fn unmount(
        &self,
        req: Request<UnmountRequest>,
    ) -> Result<Response<UnmountResponse>, Status> {
        let mount_point =
            get_path_from_bytes(&req.into_inner().mount_point).to_path_buf();
        tracing::info!(mount_point = %mount_point.display(), "Unmount requested");
        let manager = Arc::clone(&self.manager);
        tokio::task::spawn_blocking(move || manager.unmount(&mount_point))
            .await
            .map_err(|e| Status::internal(format!("unmount: {e}")))?
            .map_err(mount_error_to_status)?;
        Ok(Response::new(UnmountResponse {}))
    }

    async fn list_mounts(
        &self,
        _req: Request<ListMountsRequest>,
    ) -> Result<Response<ListMountsResponse>, Status> {
        let manager = Arc::clone(&self.manager);
        let mounts = tokio::task::spawn_blocking(move || {
            manager
                .list_mounts()
                .into_iter()
                .map(to_proto_mount_info)
                .collect::<Vec<MountInfo>>()
        })
        .await
        .map_err(|e| Status::internal(format!("list mounts: {e}")))?;
        Ok(Response::new(ListMountsResponse { mounts }))
    }
}

fn to_proto_mount_info(info: hg_vfs::MountInfo) -> MountInfo {
    MountInfo {
        created_at: info.created_at,
        clone_path: get_bytes_from_path(&info.clone_path),
        mount_point: get_bytes_from_path(&info.mount_point),
    }
}

fn mount_error_to_status(e: MountError) -> Status {
    match e {
        MountError::AlreadyMounted(path, _) => Status::already_exists(format!(
            "already mounted at {}",
            path.display()
        )),
        MountError::Hg(e) => Status::internal(e.to_string()),
        MountError::NotMounted(path, _) => {
            Status::not_found(format!("nothing mounted at {}", path.display()))
        }
        MountError::Unmount(e, _) => {
            Status::internal(format!("unmount failed: {e}"))
        }
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

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let socket_path =
        match invocation.subcommand_args.get_one::<OsString>("socket") {
            Some(s) => PathBuf::from(s),
            None => vfs_api::default_socket_path().ok_or_else(|| {
                CommandError::abort(
                    "abort: no $XDG_RUNTIME_DIR to derive a socket path; \
                     pass --socket",
                )
            })?,
        };

    serve(socket_path).map_err(|e| {
        CommandError::abort(format!("abort: hgfs-server error: {e}"))
    })
}

#[tokio::main]
async fn serve(socket_path: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let lock = take_socket_lock(&socket_path)?;
    match std::fs::remove_file(&socket_path) {
        Ok(()) => {
            tracing::warn!(
                "removed stale socket file {}",
                socket_path.display()
            )
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e.into()),
    }

    let listener = UnixListener::bind(&socket_path)?;
    println!(
        "hgfs-server listening on {} (pid {})",
        socket_path.display(),
        std::process::id()
    );

    // Load the non-repo config once; every mount request reuses it.
    let config = Arc::new(
        Config::load_non_repo()
            .map_err(|e| format!("loading config: {e:?}"))?,
    );
    let manager = Arc::new(MountManager::new());
    let service = VfsControlService { manager, config };

    let serve_result = Server::builder()
        .add_service(VfsControlServer::new(service))
        .serve_with_incoming_shutdown(
            UnixListenerStream::new(listener),
            shutdown_signal(),
        )
        .await;

    let () = std::fs::remove_file(&socket_path)?;
    let () = lock.unlock()?;
    serve_result?;
    Ok(())
}

/// Take an exclusive advisory lock on the socket's lock file, proving we're the
/// only server for this socket. It is released automatically if the server
/// dies, so a lock file that exists but isn't held means the previous owner is
/// gone.
fn take_socket_lock(
    socket_path: &Path,
) -> Result<File, Box<dyn std::error::Error>> {
    let lock_path = socket_lock_file(socket_path);
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(&lock_path)?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(std::fs::TryLockError::WouldBlock) => Err(format!(
            "another hgfs-server already holds {}",
            lock_path.display()
        )
        .into()),
        Err(std::fs::TryLockError::Error(e)) => Err(e.into()),
    }
}

fn socket_lock_file(socket_path: &Path) -> PathBuf {
    socket_path.with_extension("lock")
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
