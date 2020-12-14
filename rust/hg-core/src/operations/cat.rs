// list_tracked_files.rs
//
// Copyright 2020 Antoine Cezar <antoine.cezar@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::convert::From;
use std::path::PathBuf;

use crate::repo::Repo;
use crate::revlog::changelog::Changelog;
use crate::revlog::manifest::Manifest;
use crate::revlog::path_encode::path_encode;
use crate::revlog::revlog::Revlog;
use crate::revlog::revlog::RevlogError;
use crate::revlog::Node;
use crate::revlog::NodePrefix;
use crate::revlog::Revision;
use crate::utils::files::get_path_from_bytes;
use crate::utils::hg_path::{HgPath, HgPathBuf};

const METADATA_DELIMITER: [u8; 2] = [b'\x01', b'\n'];

/// Kind of error encountered by `CatRev`
#[derive(Debug)]
pub enum CatRevErrorKind {
    /// Error when reading a `revlog` file.
    IoError(std::io::Error),
    /// The revision has not been found.
    InvalidRevision,
    /// Found more than one revision whose ID match the requested prefix
    AmbiguousPrefix,
    /// A `revlog` file is corrupted.
    CorruptedRevlog,
    /// The `revlog` format version is not supported.
    UnsuportedRevlogVersion(u16),
    /// The `revlog` data format is not supported.
    UnknowRevlogDataFormat(u8),
}

/// A `CatRev` error
#[derive(Debug)]
pub struct CatRevError {
    /// Kind of error encountered by `CatRev`
    pub kind: CatRevErrorKind,
}

impl From<CatRevErrorKind> for CatRevError {
    fn from(kind: CatRevErrorKind) -> Self {
        CatRevError { kind }
    }
}

impl From<RevlogError> for CatRevError {
    fn from(err: RevlogError) -> Self {
        match err {
            RevlogError::IoError(err) => CatRevErrorKind::IoError(err),
            RevlogError::UnsuportedVersion(version) => {
                CatRevErrorKind::UnsuportedRevlogVersion(version)
            }
            RevlogError::InvalidRevision => CatRevErrorKind::InvalidRevision,
            RevlogError::AmbiguousPrefix => CatRevErrorKind::AmbiguousPrefix,
            RevlogError::Corrupted => CatRevErrorKind::CorruptedRevlog,
            RevlogError::UnknowDataFormat(format) => {
                CatRevErrorKind::UnknowRevlogDataFormat(format)
            }
        }
        .into()
    }
}

/// List files under Mercurial control at a given revision.
///
/// * `root`: Repository root
/// * `rev`: The revision to cat the files from.
/// * `files`: The files to output.
pub fn cat(
    repo: &Repo,
    rev: &str,
    files: &[HgPathBuf],
) -> Result<Vec<u8>, CatRevError> {
    let changelog = Changelog::open(repo)?;
    let manifest = Manifest::open(repo)?;

    let changelog_entry = match rev.parse::<Revision>() {
        Ok(rev) => changelog.get_rev(rev)?,
        _ => {
            let changelog_node = NodePrefix::from_hex(&rev)
                .map_err(|_| CatRevErrorKind::InvalidRevision)?;
            changelog.get_node(changelog_node.borrow())?
        }
    };
    let manifest_node = Node::from_hex(&changelog_entry.manifest_node()?)
        .map_err(|_| CatRevErrorKind::CorruptedRevlog)?;

    let manifest_entry = manifest.get_node((&manifest_node).into())?;
    let mut bytes = vec![];

    for (manifest_file, node_bytes) in manifest_entry.files_with_nodes() {
        for cat_file in files.iter() {
            if cat_file.as_bytes() == manifest_file.as_bytes() {
                let index_path = store_path(manifest_file, b".i");
                let data_path = store_path(manifest_file, b".d");

                let file_log =
                    Revlog::open(repo, &index_path, Some(&data_path))?;
                let file_node = Node::from_hex(node_bytes)
                    .map_err(|_| CatRevErrorKind::CorruptedRevlog)?;
                let file_rev = file_log.get_node_rev((&file_node).into())?;
                let data = file_log.get_rev_data(file_rev)?;
                if data.starts_with(&METADATA_DELIMITER) {
                    let end_delimiter_position = data
                        [METADATA_DELIMITER.len()..]
                        .windows(METADATA_DELIMITER.len())
                        .position(|bytes| bytes == METADATA_DELIMITER);
                    if let Some(position) = end_delimiter_position {
                        let offset = METADATA_DELIMITER.len() * 2;
                        bytes.extend(data[position + offset..].iter());
                    }
                } else {
                    bytes.extend(data);
                }
            }
        }
    }

    Ok(bytes)
}

fn store_path(hg_path: &HgPath, suffix: &[u8]) -> PathBuf {
    let encoded_bytes =
        path_encode(&[b"data/", hg_path.as_bytes(), suffix].concat());
    get_path_from_bytes(&encoded_bytes).into()
}
