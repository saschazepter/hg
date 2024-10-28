// debugdata.rs
//
// Copyright 2020 Antoine Cezar <antoine.cezar@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::Revlog;
use crate::{exit_codes, RevlogError, RevlogType};

/// Dump the contents data of a revision.
pub fn debug_data(
    repo: &Repo,
    revset: &str,
    kind: RevlogType,
) -> Result<Vec<u8>, RevlogError> {
    let index_file = match kind {
        RevlogType::Changelog => "00changelog.i",
        RevlogType::Manifestlog => "00manifest.i",
        _ => {
            return Err(RevlogError::Other(HgError::abort(
                format!("invalid revlog type {}", kind),
                exit_codes::ABORT,
                None,
            )))
        }
    };
    let revlog = Revlog::open(
        &repo.store_vfs(),
        index_file,
        None,
        repo.default_revlog_options(RevlogType::Changelog)?,
    )?;
    let rev =
        crate::revset::resolve_rev_number_or_hex_prefix(revset, &revlog)?;
    let data = revlog.get_rev_data_for_checked_rev(rev)?;
    Ok(data.into_owned())
}
