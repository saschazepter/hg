// list_tracked_files.rs
//
// Copyright 2020 Antoine Cezar <antoine.cezar@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::errors::HgError;
use crate::matchers::Matcher;
use crate::repo::Repo;
use crate::revlog::manifest::Manifest;
use crate::revlog::RevlogError;
use crate::utils::filter_map_results;
use crate::utils::hg_path::HgPath;

/// List files under Mercurial control at a given revision.
pub fn list_rev_tracked_files(
    repo: &Repo,
    revset: &str,
    narrow_matcher: Box<dyn Matcher>,
) -> Result<FilesForRev, RevlogError> {
    let rev = crate::revset::resolve_single(revset, repo)?;
    Ok(FilesForRev {
        manifest: repo.manifest_for_rev(rev)?,
        narrow_matcher,
    })
}

pub struct FilesForRev {
    manifest: Manifest,
    narrow_matcher: Box<dyn Matcher>,
}

impl FilesForRev {
    pub fn iter(&self) -> impl Iterator<Item = Result<&HgPath, HgError>> {
        filter_map_results(self.manifest.iter(), |entry| {
            let path = entry.path;
            Ok(if self.narrow_matcher.matches(path) {
                Some(path)
            } else {
                None
            })
        })
    }
}
