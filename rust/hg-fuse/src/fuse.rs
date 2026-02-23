use std::path::Path;
use std::time::Duration;
use std::time::SystemTime;

use fuser::Config;
use fuser::Filesystem;
use fuser::INodeNo;
use fuser::MountOption;
use hg::errors::HgError;
use hg::errors::IoResultExt;

use crate::server::Server;

/// A virtual filesystem in user-space (FUSE) for Mercurial
pub struct HgFuse {
    server: Server,
}

impl HgFuse {
    /// Mount an instance of this FUSE to `destination`.
    /// This function will not try to create the destination folder.
    /// This function will only exit when the filesystem is unmounted.
    pub fn mount(
        server: Server,
        destination: impl AsRef<Path>,
    ) -> Result<(), HgError> {
        let mountpoint = destination.as_ref();
        let mut config = Config::default();
        config.mount_options.extend([
            MountOption::FSName("hgvfs".to_string()),
            MountOption::RO,
            MountOption::NoAtime,
        ]);
        let filesystem = Self { server };
        Ok(fuser::mount2(filesystem, mountpoint, &config)
            .when_writing_file(mountpoint)?)
    }
}

/// Everything we expose is read-only (for now), the kernel can cache it all
const TTL: Duration = Duration::MAX;

impl Filesystem for HgFuse {
    fn access(
        &self,
        _req: &fuser::Request,
        _ino: INodeNo,
        _mask: fuser::AccessFlags,
        reply: fuser::ReplyEmpty,
    ) {
        reply.ok();
    }

    fn getattr(
        &self,
        _req: &fuser::Request,
        ino: fuser::INodeNo,
        _fh: Option<fuser::FileHandle>,
        reply: fuser::ReplyAttr,
    ) {
        match self.server.attributes(ino) {
            Some(attributes) => {
                reply.attr(&TTL, &attributes);
            }
            None => reply.error(fuser::Errno::ENOENT),
        }
    }

    fn readdir(
        &self,
        _req: &fuser::Request,
        ino: INodeNo,
        _fh: fuser::FileHandle,
        _offset: u64,
        reply: fuser::ReplyDirectory,
    ) {
        match self.server.get_entry(ino) {
            Some(_entry) => {
                // TODO actually list the entries
                reply.ok();
            }
            None => reply.error(fuser::Errno::ENOENT),
        }
    }
}

/// Contains information about an entry of the [`HgFuse`]
pub enum Entry {
    /// A normal directory
    Dir { timestamp: SystemTime },
}

impl Entry {
    /// Returns a [`Self::Dir`]
    pub fn dir(start_time: SystemTime) -> Self {
        Self::Dir { timestamp: start_time }
    }
}
