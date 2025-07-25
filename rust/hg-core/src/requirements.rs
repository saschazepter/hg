use std::collections::HashSet;

use crate::errors::HgError;
use crate::errors::HgResultExt;
use crate::utils::strings::join_display;
use crate::vfs::VfsImpl;

fn parse(bytes: &[u8]) -> Result<HashSet<String>, HgError> {
    // The Python code reading this file uses `str.splitlines`
    // which looks for a number of line separators (even including a couple of
    // non-ASCII ones), but Python code writing it always uses `\n`.
    let lines = bytes.split(|&byte| byte == b'\n');

    lines
        .filter(|line| !line.is_empty())
        .map(|line| {
            // Python uses Unicode `str.isalnum` but feature names are all
            // ASCII
            if line[0].is_ascii_alphanumeric() && line.is_ascii() {
                Ok(String::from_utf8(line.into()).unwrap())
            } else {
                Err(HgError::corrupted("parse error in 'requires' file"))
            }
        })
        .collect()
}

pub(crate) fn load(hg_vfs: VfsImpl) -> Result<HashSet<String>, HgError> {
    parse(&hg_vfs.read("requires")?)
}

pub(crate) fn load_if_exists(
    hg_vfs: &VfsImpl,
) -> Result<HashSet<String>, HgError> {
    if let Some(bytes) = hg_vfs.read("requires").io_not_found_as_none()? {
        parse(&bytes)
    } else {
        // Treat a missing file the same as an empty file.
        // From `mercurial/localrepo.py`:
        // > requires file contains a newline-delimited list of
        // > features/capabilities the opener (us) must have in order to use
        // > the repository. This file was introduced in Mercurial 0.9.2,
        // > which means very old repositories may not have one. We assume
        // > a missing file translates to no requirements.
        Ok(HashSet::new())
    }
}

pub(crate) fn check(reqs: &HashSet<String>) -> Result<(), HgError> {
    let mut repo_reqs = reqs.clone();

    // Check mutually exclusive, but required pairs
    let mut one_of_reqs_used = vec![];
    for (left, right) in ONE_OF {
        let has_left = repo_reqs.contains(*left);
        let has_right = repo_reqs.contains(*right);
        if !(has_left ^ has_right) {
            return Err(HgError::unsupported(format!(
                "bad requirements, need exactly one of {} or {}",
                left, right
            )));
        }
        if has_left {
            repo_reqs.remove(*left);
            one_of_reqs_used.push(left);
        } else {
            repo_reqs.remove(*right);
            one_of_reqs_used.push(right);
        }
    }

    let unknown: Vec<_> = repo_reqs
        .iter()
        .map(String::as_str)
        .filter(|feature| {
            // `ONE_OF` has been checked and relevant reqs removed
            !REQUIRED.contains(feature) && !SUPPORTED.contains(feature)
        })
        .collect();
    if !unknown.is_empty() {
        return Err(HgError::unsupported(format!(
            "repository requires feature unknown to this Mercurial: {}",
            join_display(&unknown, ", ")
        )));
    }
    let missing: Vec<_> = REQUIRED
        .iter()
        .filter(|feature| {
            !one_of_reqs_used.contains(feature)
                && !repo_reqs.contains(**feature)
        })
        .collect();
    if !missing.is_empty() {
        return Err(HgError::unsupported(format!(
            "repository is missing feature required by this Mercurial: {}",
            join_display(&missing, ", ")
        )));
    }
    Ok(())
}

/// rhg does not support repositories that are *missing* any of these features
const REQUIRED: &[&str] =
    &[REVLOGV1_REQUIREMENT, STORE_REQUIREMENT, FNCACHE_REQUIRMENT];

/// rhg supports repository with or without these
const SUPPORTED: &[&str] = &[
    GENERALDELTA_REQUIREMENT,
    SHARED_REQUIREMENT,
    SHARESAFE_REQUIREMENT,
    SPARSEREVLOG_REQUIREMENT,
    DELTA_INFO_REQUIREMENT,
    RELATIVE_SHARED_REQUIREMENT,
    REVLOG_COMPRESSION_ZSTD,
    DIRSTATE_V2_REQUIREMENT,
    DIRSTATE_TRACKED_HINT_V1,
    // As of this writing everything rhg does is read-only.
    // When it starts writing to the repository, it’ll need to either keep the
    // persistent nodemap up to date or remove this entry:
    NODEMAP_REQUIREMENT,
    // Not all commands support `sparse` and `narrow`. The commands that do
    // not should opt out by checking `has_sparse` and `has_narrow`.
    SPARSE_REQUIREMENT,
    NARROW_REQUIREMENT,
    // rhg doesn't care about bookmarks at all yet
    BOOKMARKS_IN_STORE_REQUIREMENT,
];

/// rhg supports repositories with exactly one within each pair
const ONE_OF: &[(&str, &str)] =
    &[(PLAIN_ENCODE_REQUIREMENT, DOTENCODE_REQUIREMENT)];

// Copied from mercurial/requirements.py:

pub const DIRSTATE_V2_REQUIREMENT: &str = "dirstate-v2";
pub const GENERALDELTA_REQUIREMENT: &str = "generaldelta";
pub const DOTENCODE_REQUIREMENT: &str = "dotencode";
pub const STORE_REQUIREMENT: &str = "store";
pub const FNCACHE_REQUIRMENT: &str = "fncache";
pub const PLAIN_ENCODE_REQUIREMENT: &str =
    "exp-very-fragile-and-unsafe-plain-store-encoding";

/// A repository that uses the tracked hint dirstate file
#[allow(unused)]
pub const DIRSTATE_TRACKED_HINT_V1: &str = "dirstate-tracked-key-v1";

/// When narrowing is finalized and no longer subject to format changes,
/// we should move this to just "narrow" or similar.
#[allow(unused)]
pub const NARROW_REQUIREMENT: &str = "narrowhg-experimental";

/// Bookmarks must be stored in the `store` part of the repository and will be
/// share accross shares
#[allow(unused)]
pub const BOOKMARKS_IN_STORE_REQUIREMENT: &str = "bookmarksinstore";

/// Enables sparse working directory usage
#[allow(unused)]
pub const SPARSE_REQUIREMENT: &str = "exp-sparse";

/// Enables the internal phase which is used to hide changesets instead
/// of stripping them
#[allow(unused)]
pub const INTERNAL_PHASE_REQUIREMENT: &str = "internal-phase";

/// Stores manifest in Tree structure
#[allow(unused)]
pub const TREEMANIFEST_REQUIREMENT: &str = "treemanifest";

/// Whether to use the "RevlogNG" or V1 of the revlog format
#[allow(unused)]
pub const REVLOGV1_REQUIREMENT: &str = "revlogv1";

/// Increment the sub-version when the revlog v2 format changes to lock out old
/// clients.
#[allow(unused)]
pub const REVLOGV2_REQUIREMENT: &str = "exp-revlogv2.1";

/// Increment the sub-version when the revlog v2 format changes to lock out old
/// clients.
#[allow(unused)]
pub const CHANGELOGV2_REQUIREMENT: &str = "exp-changelog-v2";

/// A repository with the sparserevlog feature will have delta chains that
/// can spread over a larger span. Sparse reading cuts these large spans into
/// pieces, so that each piece isn't too big.
/// Without the sparserevlog capability, reading from the repository could use
/// huge amounts of memory, because the whole span would be read at once,
/// including all the intermediate revisions that aren't pertinent for the
/// chain. This is why once a repository has enabled sparse-read, it becomes
/// required.
#[allow(unused)]
pub const SPARSEREVLOG_REQUIREMENT: &str = "sparserevlog";

/// The filelog uses explicit flag in the index to mark file revision that
/// contains metadata.
pub const FILELOG_METAFLAG_REQUIREMENT: &str = "exp-filelog-metaflag";

/// Revlog stores extra information about delta
#[allow(unused)]
pub const DELTA_INFO_REQUIREMENT: &str = "exp-delta-info-revlog";

/// A repository with the the copies-sidedata-changeset requirement will store
/// copies related information in changeset's sidedata.
#[allow(unused)]
pub const COPIESSDC_REQUIREMENT: &str = "exp-copies-sidedata-changeset";

/// The repository use persistent nodemap for the changelog and the manifest.
#[allow(unused)]
pub const NODEMAP_REQUIREMENT: &str = "persistent-nodemap";

/// Denotes that the current repository is a share
#[allow(unused)]
pub const SHARED_REQUIREMENT: &str = "shared";

/// Denotes that current repository is a share and the shared source path is
/// relative to the current repository root path
#[allow(unused)]
pub const RELATIVE_SHARED_REQUIREMENT: &str = "relshared";

/// A repository with share implemented safely. The repository has different
/// store and working copy requirements i.e. both `.hg/requires` and
/// `.hg/store/requires` are present.
#[allow(unused)]
pub const SHARESAFE_REQUIREMENT: &str = "share-safe";

/// A repository that use zstd compression inside its revlog
#[allow(unused)]
pub const REVLOG_COMPRESSION_ZSTD: &str = "revlog-compression-zstd";

#[cfg(test)]
mod tests {
    use super::*;

    fn create_reqs(reqs: &[&str]) -> HashSet<String> {
        let mut set = create_reqs_no_defaults(reqs);
        for req in REQUIRED {
            set.insert(req.to_string());
        }
        set
    }

    fn create_reqs_no_defaults(reqs: &[&str]) -> HashSet<String> {
        let mut set = HashSet::new();
        for &req in reqs {
            set.insert(req.to_string());
        }
        set
    }

    #[test]
    fn test_check() {
        // minimum reqs
        assert!(check(&create_reqs(&[PLAIN_ENCODE_REQUIREMENT])).is_ok());
        assert!(check(&create_reqs(&[DOTENCODE_REQUIREMENT])).is_ok());
        // all supported reqs
        let mut reqs = create_reqs(SUPPORTED);
        reqs.insert(DOTENCODE_REQUIREMENT.to_string());
        assert!(check(&reqs).is_ok());

        // no mutually exclusive reqs
        assert!(check(&create_reqs(&[
            DOTENCODE_REQUIREMENT,
            PLAIN_ENCODE_REQUIREMENT
        ]))
        .is_err());
        // no reqs is invalid
        assert!(check(&create_reqs_no_defaults(&[])).is_err());
        // missing from mutually exclusive pairs
        assert!(check(&create_reqs(&[])).is_err());
        // no reqs + mutually exclusive item is also wrong
        assert!(
            check(&create_reqs_no_defaults(&[DOTENCODE_REQUIREMENT])).is_err()
        );

        // no unknown req
        assert!(check(&create_reqs(&[
            DOTENCODE_REQUIREMENT,
            "thisdoesnotexist"
        ]))
        .is_err());
    }
}
