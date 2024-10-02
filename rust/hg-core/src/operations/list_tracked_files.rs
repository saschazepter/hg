// list_tracked_files.rs
//
// Copyright 2020 Antoine Cezar <antoine.cezar@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::num::NonZeroU8;

use crate::errors::HgError;
use crate::matchers::{Matcher, VisitChildrenSet};
use crate::repo::Repo;
use crate::revlog::manifest::Manifest;
use crate::revlog::RevlogError;
use crate::utils::filter_map_results;
use crate::utils::hg_path::HgPath;
use crate::{Node, UncheckedRevision};

/// List files under Mercurial control at a given revset.
pub fn list_revset_tracked_files(
    repo: &Repo,
    revset: &str,
    narrow_matcher: Box<dyn Matcher + Sync>,
) -> Result<FilesForRev, RevlogError> {
    let rev = crate::revset::resolve_single(revset, repo)?;
    list_rev_tracked_files(repo, rev.into(), narrow_matcher)
}

/// List files under Mercurial control at a given revision.
pub fn list_rev_tracked_files(
    repo: &Repo,
    rev: UncheckedRevision,
    narrow_matcher: Box<dyn Matcher + Sync>,
) -> Result<FilesForRev, RevlogError> {
    // TODO move this to the repo itself
    // This implies storing the narrow matcher in the repo, bubbling up the
    // errors and warnings, so it's a bit of churn. In the meantime, the repo
    // method will error out on narrowed manifests.
    let manifest = match repo.manifest_for_rev(rev) {
        Ok(manifest) => manifest,
        Err(e) => match e {
            RevlogError::InvalidRevision(_) => {
                let outside_of_current_narrow_spec = narrow_matcher
                    .visit_children_set(HgPath::new(""))
                    == VisitChildrenSet::Empty;
                if outside_of_current_narrow_spec {
                    // Fake a manifest for a manifest whose node is known, but
                    // which doesn't exist because it's empty after narrowing
                    Manifest::empty()
                } else {
                    return Err(e);
                }
            }
            _ => return Err(e),
        },
    };
    Ok(FilesForRev {
        manifest,
        narrow_matcher,
    })
}

pub struct FilesForRev {
    manifest: Manifest,
    narrow_matcher: Box<dyn Matcher + Sync>,
}

/// Like [`crate::revlog::manifest::ManifestEntry`], but with the `Node`
/// already checked.
pub type ExpandedManifestEntry<'a> = (&'a HgPath, Node, Option<NonZeroU8>);

impl FilesForRev {
    pub fn iter(
        &self,
    ) -> impl Iterator<Item = Result<ExpandedManifestEntry, HgError>> {
        filter_map_results(self.manifest.iter(), |entry| {
            let path = entry.path;
            Ok(if self.narrow_matcher.matches(path) {
                Some((path, entry.node_id()?, entry.flags))
            } else {
                None
            })
        })
    }
}
