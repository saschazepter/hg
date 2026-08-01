//! `hgfs_client` is the client that interacts with the hg virtual-filesystem
//! control server (`hgfs_server`).

use std::ffi::OsString;
use std::os::unix::ffi::OsStrExt;

use clap::Arg;
use clap::ArgMatches;
use clap::Command;
use hg::utils::files::get_path_from_bytes;
use vfs_api::DEFAULT_SOCKET_URI;
use vfs_api::vfs::HealthRequest;
use vfs_api::vfs::ListMountsRequest;
use vfs_api::vfs::MountRequest;
use vfs_api::vfs::UnmountRequest;
use vfs_api::vfs::UnmountResponse;
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
                        .value_parser(clap::value_parser!(OsString))
                        .help("path to the clone to serve"),
                )
                .arg(
                    Arg::new("mount")
                        .long("mount")
                        .required(true)
                        .value_parser(clap::value_parser!(OsString))
                        .help("path to mount the virtual filesystem at"),
                ),
        )
        .subcommand(
            Command::new("unmount").about("unmount a virtual filesystem").arg(
                Arg::new("mount")
                    .long("mount")
                    .required(true)
                    .value_parser(clap::value_parser!(OsString))
                    .help("mount point to unmount"),
            ),
        )
        .subcommand(Command::new("list").about("list current mounts"))
}

pub fn run(invocation: &crate::CliInvocation) -> Result<(), CommandError> {
    let (name, sub_args) = invocation
        .subcommand_args
        .subcommand()
        .expect("subcommand is required");

    dispatch(name, sub_args).map_err(|e| {
        CommandError::abort(format!("abort: hgfs-client error: {e}"))
    })
}

#[tokio::main]
async fn dispatch(
    name: &str,
    sub_args: &ArgMatches,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut client =
        VfsControlClient::connect(DEFAULT_SOCKET_URI).await.map_err(|e| {
            format!("cannot reach hgfs-server (is it running?): {e}")
        })?;

    match name {
        "health" => {
            let resp = client
                .health(HealthRequest {})
                .await
                .map_err(map_status)?
                .into_inner();
            println!("Health: version={} pid={}", resp.version, resp.pid);
        }
        "mount" => {
            let clone = get_arg(sub_args, "clone");
            let mount = get_arg(sub_args, "mount");
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
        "unmount" => {
            let mount_point = get_arg(sub_args, "mount");
            let request =
                UnmountRequest { mount_point: mount_point.as_bytes().to_vec() };
            let UnmountResponse {} =
                client.unmount(request).await.map_err(map_status)?.into_inner();
            println!("unmounted {}", mount_point.display());
        }
        "list" => {
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
        other => return Err(format!("unknown subcommand: {other}").into()),
    }
    Ok(())
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

fn get_arg(matches: &ArgMatches, name: &str) -> OsString {
    matches
        .get_one::<OsString>(name)
        .cloned()
        .expect("required argument is present")
}
