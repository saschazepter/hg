use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::revlog::{Revlog, RevlogError};
use crate::revlog::Revision;
use crate::revlog::{Node, NodePrefix};

/// A specialized `Revlog` to work with `changelog` data format.
pub struct Changelog {
    /// The generic `revlog` format.
    pub(crate) revlog: Revlog,
}

impl Changelog {
    /// Open the `changelog` of a repository given by its root.
    pub fn open(repo: &Repo) -> Result<Self, RevlogError> {
        let revlog = Revlog::open(repo, "00changelog.i", None)?;
        Ok(Self { revlog })
    }

    /// Return the `ChangelogEntry` a given node id.
    pub fn get_node(
        &self,
        node: NodePrefix,
    ) -> Result<ChangelogEntry, RevlogError> {
        let rev = self.revlog.get_node_rev(node)?;
        self.get_rev(rev)
    }

    /// Return the `ChangelogEntry` of a given node revision.
    pub fn get_rev(
        &self,
        rev: Revision,
    ) -> Result<ChangelogEntry, RevlogError> {
        let bytes = self.revlog.get_rev_data(rev)?;
        Ok(ChangelogEntry { bytes })
    }

    pub fn node_from_rev(&self, rev: Revision) -> Option<&Node> {
        Some(self.revlog.index.get_entry(rev)?.hash())
    }
}

/// `Changelog` entry which knows how to interpret the `changelog` data bytes.
#[derive(Debug)]
pub struct ChangelogEntry {
    /// The data bytes of the `changelog` entry.
    bytes: Vec<u8>,
}

impl ChangelogEntry {
    /// Return an iterator over the lines of the entry.
    pub fn lines(&self) -> impl Iterator<Item = &[u8]> {
        self.bytes
            .split(|b| b == &b'\n')
            .filter(|line| !line.is_empty())
    }

    /// Return the node id of the `manifest` referenced by this `changelog`
    /// entry.
    pub fn manifest_node(&self) -> Result<&[u8], RevlogError> {
        self.lines()
            .next()
            .ok_or_else(|| HgError::corrupted("empty changelog entry").into())
    }
}
