use std::path::PathBuf;

/// Returns `None` when there is no per-user runtime dir. Users must then pass
/// an explicit socket path.
pub fn default_socket_path() -> Option<PathBuf> {
    dirs::runtime_dir().map(|dir| dir.join("hgfs-control.sock"))
}

pub mod vfs {
    tonic::include_proto!("vfs");
}
