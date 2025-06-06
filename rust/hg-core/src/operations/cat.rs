// list_tracked_files.rs
//
// Copyright 2020 Antoine Cezar <antoine.cezar@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::cmp::Ordering;

use itertools::put_back;
use itertools::PutBack;

use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::manifest::Manifest;
use crate::revlog::manifest::ManifestEntry;
use crate::revlog::Node;
use crate::revlog::RevlogError;
use crate::utils::hg_path::HgPath;

pub struct CatOutput<'a> {
    /// Whether any file in the manifest matched the paths given as CLI
    /// arguments
    pub found_any: bool,
    /// The contents of matching files, in manifest order
    pub results: Vec<(&'a HgPath, Vec<u8>)>,
    /// Which of the CLI arguments did not match any manifest file
    pub missing: Vec<&'a HgPath>,
    /// The node ID that the given revset was resolved to
    pub node: Node,
}

// Find an item in an iterator over a sorted collection.
fn find_item<'a>(
    i: &mut PutBack<impl Iterator<Item = Result<ManifestEntry<'a>, HgError>>>,
    needle: &HgPath,
) -> Result<Option<Node>, HgError> {
    loop {
        match i.next() {
            None => return Ok(None),
            Some(result) => {
                let entry = result?;
                match needle.as_bytes().cmp(entry.path.as_bytes()) {
                    Ordering::Less => {
                        i.put_back(Ok(entry));
                        return Ok(None);
                    }
                    Ordering::Greater => continue,
                    Ordering::Equal => return Ok(Some(entry.node_id()?)),
                }
            }
        }
    }
}

// Tuple of (missing, found) paths in the manifest
type ManifestQueryResponse<'a> = (Vec<(&'a HgPath, Node)>, Vec<&'a HgPath>);

fn find_files_in_manifest<'query>(
    manifest: &Manifest,
    query: impl Iterator<Item = &'query HgPath>,
) -> Result<ManifestQueryResponse<'query>, HgError> {
    let mut manifest = put_back(manifest.iter());
    let mut res = vec![];
    let mut missing = vec![];

    for file in query {
        match find_item(&mut manifest, file)? {
            None => missing.push(file),
            Some(item) => res.push((file, item)),
        }
    }
    Ok((res, missing))
}

/// Output the given revision of files
///
/// * `root`: Repository root
/// * `rev`: The revision to cat the files from.
/// * `files`: The files to output.
pub fn cat<'a>(
    repo: &Repo,
    revset: &str,
    mut files: Vec<&'a HgPath>,
) -> Result<CatOutput<'a>, RevlogError> {
    let Some(rev) = crate::revset::resolve_single(revset, repo)?.exclude_wdir()
    else {
        return Err(HgError::unsupported("cat wdir not implemented").into());
    };
    let manifest = repo.manifest_for_rev(rev.into())?;
    let mut results: Vec<(&'a HgPath, Vec<u8>)> = vec![];
    let node = *repo.changelog()?.node_from_rev(rev);
    let mut found_any = false;

    files.sort_unstable();

    let (found, missing) =
        find_files_in_manifest(&manifest, files.into_iter())?;

    for (file_path, file_node) in found {
        found_any = true;
        let file_log = repo.filelog(file_path)?;
        results.push((
            file_path,
            file_log.data_for_node(file_node)?.into_file_data()?,
        ));
    }

    Ok(CatOutput { found_any, results, missing, node })
}
