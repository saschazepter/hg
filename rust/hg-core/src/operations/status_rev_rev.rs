use std::borrow::Cow;

use crate::dirstate::status::StatusPath;
use crate::errors::HgError;
use crate::matchers::Matcher;
use crate::repo::Repo;
use crate::revlog::manifest::{Manifest, ManifestEntry};
use crate::utils::filter_map_results;
use crate::utils::hg_path::{HgPath, HgPathBuf};
use crate::utils::merge_join_results_by;

use crate::{Revision, NULL_REVISION};

use itertools::EitherOrBoth;

#[derive(Debug, Copy, Clone)]
pub enum DiffStatus {
    Removed,
    Added,
    Matching,
    Modified,
}

/// What copy/rename information to report.
pub enum ListCopies {
    /// Report copies only for added files.
    Added,
    /// Report copies for files that are added or modified.
    AddedOrModified,
}

/// Strategy for determining a file's copy source.
enum CopyStrategy<'a> {
    /// Use the [`Repo`] to look up copy information in filelog metadata.
    /// Assumes we are producing the status for a single changeset.
    Change(&'a Repo),
    // TODO: For --rev --rev --copies use a precomputed copy map
}

pub struct StatusRevRev<'a> {
    manifest1: Manifest,
    manifest2: Manifest,
    narrow_matcher: Box<dyn Matcher>,
    copies: Option<(ListCopies, CopyStrategy<'a>)>,
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
    Ok(StatusRevRev {
        manifest1: manifest_for_rev(repo, rev1)?,
        manifest2: manifest_for_rev(repo, rev2)?,
        narrow_matcher,
        copies: None,
    })
}

/// Computes the status of `rev` against its first parent.
pub fn status_change(
    repo: &Repo,
    rev: Revision,
    narrow_matcher: Box<dyn Matcher>,
    list_copies: Option<ListCopies>,
) -> Result<StatusRevRev, HgError> {
    let parent = repo.changelog()?.revlog.get_entry(rev)?.p1();
    let parent = parent.unwrap_or(NULL_REVISION);
    Ok(StatusRevRev {
        manifest1: manifest_for_rev(repo, parent)?,
        manifest2: manifest_for_rev(repo, rev)?,
        narrow_matcher,
        copies: list_copies.map(|list| (list, CopyStrategy::Change(repo))),
    })
}

impl StatusRevRev<'_> {
    pub fn iter(
        &self,
    ) -> impl Iterator<Item = Result<(StatusPath<'_>, DiffStatus), HgError>>
    {
        let iter1 = self.manifest1.iter();
        let iter2 = self.manifest2.iter();

        let merged =
            merge_join_results_by(iter1, iter2, |i1, i2| i1.path.cmp(i2.path));

        filter_map_results(merged, |entry| {
            let (path, status) = match &entry {
                EitherOrBoth::Left(entry) => (entry.path, DiffStatus::Removed),
                EitherOrBoth::Right(entry) => (entry.path, DiffStatus::Added),
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
            if !self.narrow_matcher.matches(path) {
                return Ok(None);
            }
            let path = StatusPath {
                path: Cow::Borrowed(path),
                copy_source: self
                    .find_copy_source(path, status, entry.right().as_ref())?
                    .map(Cow::Owned),
            };
            Ok(Some((path, status)))
        })
    }

    /// Returns the path that a file was copied from, if it should be reported.
    fn find_copy_source(
        &self,
        path: &HgPath,
        status: DiffStatus,
        entry: Option<&ManifestEntry>,
    ) -> Result<Option<HgPathBuf>, HgError> {
        let Some(entry) = entry else { return Ok(None) };
        let Some((list, strategy)) = &self.copies else {
            return Ok(None);
        };
        match (list, status) {
            (ListCopies::Added, DiffStatus::Added) => {}
            (
                ListCopies::AddedOrModified,
                DiffStatus::Added | DiffStatus::Modified,
            ) => {}
            _ => return Ok(None),
        }
        match strategy {
            CopyStrategy::Change(repo) => {
                let data = repo
                    .filelog(path)?
                    .data_for_node(entry.node_id().unwrap())?;
                if let Some(copy) = data.metadata()?.parse()?.copy {
                    if self.manifest1.find_by_path(copy)?.is_some() {
                        return Ok(Some(copy.to_owned()));
                    }
                }
            }
        }
        Ok(None)
    }
}
