use crate::errors::HgError;
use crate::matchers::Matcher;
use crate::repo::Repo;
use crate::revlog::manifest::Manifest;
use crate::utils::filter_map_results;
use crate::utils::hg_path::HgPath;
use crate::utils::merge_join_results_by;

use crate::Revision;

use itertools::EitherOrBoth;

#[derive(Debug, Copy, Clone)]
pub enum DiffStatus {
    Removed,
    Added,
    Matching,
    Modified,
}

pub struct StatusRevRev {
    manifest1: Manifest,
    manifest2: Manifest,
    narrow_matcher: Box<dyn Matcher>,
}

fn manifest_for_rev(repo: &Repo, rev: Revision) -> Result<Manifest, HgError> {
    repo.manifest_for_rev(rev.into()).map_err(|e| {
        HgError::corrupted(format!(
            "manifest lookup failed for revision {}: {}",
            rev, e
        ))
    })
}

pub fn status_rev_rev_no_copies(
    repo: &Repo,
    rev1: Revision,
    rev2: Revision,
    narrow_matcher: Box<dyn Matcher>,
) -> Result<StatusRevRev, HgError> {
    let manifest1 = manifest_for_rev(repo, rev1)?;
    let manifest2 = manifest_for_rev(repo, rev2)?;
    Ok(StatusRevRev {
        manifest1,
        manifest2,
        narrow_matcher,
    })
}

impl StatusRevRev {
    pub fn iter(
        &self,
    ) -> impl Iterator<Item = Result<(&HgPath, DiffStatus), HgError>> {
        let iter1 = self.manifest1.iter();
        let iter2 = self.manifest2.iter();

        let merged =
            merge_join_results_by(iter1, iter2, |i1, i2| i1.path.cmp(i2.path));

        filter_map_results(merged, |entry| {
            let (path, status) = match entry {
                EitherOrBoth::Left(entry) => {
                    let path = entry.path;
                    (path, DiffStatus::Removed)
                }
                EitherOrBoth::Right(entry) => {
                    let path = entry.path;
                    (path, DiffStatus::Added)
                }
                EitherOrBoth::Both(entry1, entry2) => {
                    let path = entry1.path;
                    if entry1.node_id().unwrap() == entry2.node_id().unwrap()
                        && entry1.flags == entry2.flags
                    {
                        (path, DiffStatus::Matching)
                    } else {
                        (path, DiffStatus::Modified)
                    }
                }
            };
            Ok(if self.narrow_matcher.matches(path) {
                Some((path, status))
            } else {
                None
            })
        })
    }
}
