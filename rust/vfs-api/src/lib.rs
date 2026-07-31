// TODO: use $XDG_RUNTIME_DIR instead of hardcoded /tmp
pub const DEFAULT_SOCKET: &str = "/tmp/hgfs.sock";
pub const DEFAULT_SOCKET_URI: &str = "unix:///tmp/hgfs.sock";

pub mod vfs {
    tonic::include_proto!("vfs");
}
