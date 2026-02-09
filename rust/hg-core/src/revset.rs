//! The revset query language
//!
//! <https://www.mercurial-scm.org/repo/hg/help/revsets>

use crate::Node;
use crate::WORKING_DIRECTORY_REVISION;
use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::NULL_REVISION;
use crate::revlog::NodePrefix;
use crate::revlog::Revision;
use crate::revlog::RevisionOrWdir;
use crate::revlog::Revlog;
use crate::revlog::RevlogError;
use crate::revlog::WORKING_DIRECTORY_HEX;

/// Resolve a query string into a single revision.
///
/// Only some of the revset language is implemented yet.
pub fn resolve_single(
    input: &str,
    repo: &Repo,
) -> Result<RevisionOrWdir, RevlogError> {
    let changelog = repo.changelog()?;

    match input {
        "." => {
            let p1 = repo.dirstate_parents()?.p1;
            return Ok(changelog.revlog.rev_from_node(p1.into())?.into());
        }
        "null" => return Ok(NULL_REVISION.into()),
        "wdir()" => return Ok(RevisionOrWdir::wdir()),
        _ => {}
    }

    match resolve(input, &changelog.revlog) {
        Err(RevlogError::InvalidRevision(revision)) => {
            // TODO: support for the rest of the language here.
            let msg = format!("cannot parse revset '{}'", revision);
            Err(HgError::unsupported(msg).into())
        }
        result => result,
    }
}

/// Resolve the small subset of the language suitable for revlogs other than
/// the changelog, such as in `hg debugdata --manifest` CLI argument.
///
/// * A non-negative decimal integer for a revision number, or
/// * A hexadecimal string, for the unique node ID that starts with this prefix
pub fn resolve_rev_number_or_hex_prefix(
    input: &str,
    revlog: &Revlog,
) -> Result<Revision, RevlogError> {
    match resolve(input, revlog)?.exclude_wdir() {
        Some(rev) => Ok(rev),
        None => Err(RevlogError::WDirUnsupported),
    }
}

fn resolve(
    input: &str,
    revlog: &Revlog,
) -> Result<RevisionOrWdir, RevlogError> {
    // The Python equivalent of this is part of `revsymbol` in
    // `mercurial/scmutil.py`
    if let Ok(integer) = input.parse::<i32>() {
        if integer.to_string() == input && integer >= 0 {
            if integer == WORKING_DIRECTORY_REVISION.0 {
                return Ok(RevisionOrWdir::wdir());
            }
            if revlog.has_rev(integer.into()) {
                // This is fine because we've just checked that the revision is
                // valid for the given revlog.
                return Ok(Revision(integer).into());
            }
        }
    }
    if let Ok(prefix) = NodePrefix::from_hex(input) {
        let wdir_node =
            Node::from_hex(WORKING_DIRECTORY_HEX).expect("wdir hex is valid");
        if prefix.is_prefix_of(&wdir_node) {
            return Ok(RevisionOrWdir::wdir());
        }
        return Ok(revlog.rev_from_node(prefix)?.into());
    }
    Err(RevlogError::InvalidRevision(input.to_string()))
}
