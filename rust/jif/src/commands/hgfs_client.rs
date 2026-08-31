//! `hgfs_client` is the client that interacts with the hg virtual-filesystem
//! control server (`hgfs_server`).

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::path::PathBuf;

use hg::utils::files::get_path_from_bytes;
use hyper_util::rt::TokioIo;
use tokio::net::UnixStream;
use tonic::transport::Channel;
use tonic::transport::Endpoint;
use tonic::transport::Uri;
use tower::service_fn;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::ListMountsRequest;
use vfs_api::vfs::MountRequest;
use vfs_api::vfs::UnmountRequest;
use vfs_api::vfs::UnmountResponse;
use vfs_api::vfs::vfs_control_client::VfsControlClient;

use crate::error::CommandError;

/// Query the hg virtual filesystem control server (EXPERIMENTAL)
#[derive(clap::Args)]
pub struct Args {
    /// path to the control socket to connect to
    #[arg(long, global = true)]
    socket: Option<OsString>,
    #[command(subcommand)]
    command: ClientCommand,
}

#[derive(clap::Subcommand)]
enum ClientCommand {
    /// ping the server
    Health,
    /// mount a clone's virtual filesystem
    Mount {
        /// path to the clone to serve
        #[arg(long)]
        clone: OsString,
        /// path to mount the virtual filesystem at
        #[arg(long)]
        mount: OsString,
    },
    /// unmount a virtual filesystem
    Unmount {
        /// mount point to unmount
        #[arg(long)]
        mount: OsString,
    },
    /// list current mounts
    List,
}

pub fn run(args: Args) -> Result<(), CommandError> {
    let socket = match args.socket {
        Some(socket) => PathBuf::from(socket),
        None => vfs_api::default_socket_path().ok_or_else(|| {
            CommandError::abort(
                "no $XDG_RUNTIME_DIR to derive a socket path; pass --socket",
            )
        })?,
    };

    dispatch(socket, args.command)
        .map_err(|e| CommandError::abort(e.to_string()))
}

#[tokio::main]
async fn dispatch(
    socket: PathBuf,
    command: ClientCommand,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut client = VfsControlClient::new(connect_channel(&socket).await?);

    match command {
        ClientCommand::Health => {
            let resp = client
                .health(HealthRequest {})
                .await
                .map_err(map_status)?
                .into_inner();
            println!("Health: version={} pid={}", resp.version, resp.pid);
        }
        ClientCommand::Mount { clone, mount } => {
            let request = MountRequest {
                clone_path: clone.as_bytes().to_vec(),
                mount_point: mount.as_bytes().to_vec(),
            };
            let resp =
                client.mount(request).await.map_err(map_status)?.into_inner();
            println!(
                "mounted {} at {} (created {})",
                clone.display(),
                mount.display(),
                format_time(resp.created_at)
            );
        }
        ClientCommand::Unmount { mount } => {
            let request =
                UnmountRequest { mount_point: mount.as_bytes().to_vec() };
            let UnmountResponse {} =
                client.unmount(request).await.map_err(map_status)?.into_inner();
            println!("unmounted {}", mount.display());
        }
        ClientCommand::List => {
            let resp = client
                .list_mounts(ListMountsRequest {})
                .await
                .map_err(map_status)?
                .into_inner();
            if resp.mounts.is_empty() {
                println!("no mounts");
            } else {
                for m in resp.mounts {
                    println!(
                        "{} clone={} created={}",
                        get_path_from_bytes(&m.mount_point).display(),
                        get_path_from_bytes(&m.clone_path).display(),
                        format_time(m.created_at)
                    );
                }
            }
        }
    }
    Ok(())
}

/// Connect to the hgfs-server listening on `socket`.
///
/// We use a custom connector rather than a `unix://<path>` URI because tonic
/// requires a connection URI to be UTF-8.
async fn connect_channel(
    socket: &Path,
) -> Result<Channel, Box<dyn std::error::Error>> {
    let socket = socket.to_path_buf();
    let display = socket.display().to_string();
    // `http://hgfs` is a placeholder that gets ignored.
    Endpoint::from_static("http://hgfs")
        .connect_with_connector(service_fn(move |_: Uri| {
            let socket = socket.clone();
            async move {
                Ok::<_, std::io::Error>(TokioIo::new(
                    UnixStream::connect(socket).await?,
                ))
            }
        }))
        .await
        .map_err(|e| {
            format!(
                "cannot reach hgfs-server at {display} (is it running?): {e}"
            )
            .into()
        })
}

/// Map a gRPC failure to the bare message without tonic's verbose wrapper.
fn map_status(status: tonic::Status) -> Box<dyn std::error::Error> {
    status.message().to_string().into()
}

/// Format an epoch-seconds mount time as a UTC timestamp for display.
fn format_time(secs: u64) -> String {
    chrono::DateTime::from_timestamp(secs as i64, 0)
        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S UTC").to_string())
        .unwrap_or_else(|| secs.to_string())
}
