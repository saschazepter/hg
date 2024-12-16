// path utils module
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use hg::errors::HgError;
use hg::repo::Repo;
use hg::utils::current_dir;
use hg::utils::files::{get_bytes_from_path, relativize_path};
use hg::utils::hg_path::HgPath;
use hg::utils::hg_path::HgPathBuf;
use std::borrow::Cow;
use std::ffi::OsString;

use crate::error::CommandError;

pub struct RelativizePaths {
    repo_root: HgPathBuf,
    cwd: HgPathBuf,
    outside_repo: bool,
}

impl RelativizePaths {
    pub fn new(repo: &Repo) -> Result<Self, HgError> {
        let cwd = current_dir()?;
        let repo_root = repo.working_directory_path();
        let repo_root = cwd.join(repo_root); // Make it absolute
        let repo_root_hgpath =
            HgPathBuf::from(get_bytes_from_path(&repo_root));

        if let Ok(cwd_relative_to_repo) = cwd.strip_prefix(&repo_root) {
            // The current directory is inside the repo, so we can work with
            // relative paths
            Ok(Self {
                repo_root: repo_root_hgpath,
                cwd: HgPathBuf::from(get_bytes_from_path(
                    cwd_relative_to_repo,
                )),
                outside_repo: false,
            })
        } else {
            Ok(Self {
                repo_root: repo_root_hgpath,
                cwd: HgPathBuf::from(get_bytes_from_path(cwd)),
                outside_repo: true,
            })
        }
    }

    pub fn relativize<'a>(&self, path: &'a HgPath) -> Cow<'a, [u8]> {
        if self.outside_repo {
            let joined = self.repo_root.join(path);
            Cow::Owned(relativize_path(&joined, &self.cwd).into_owned())
        } else {
            relativize_path(path, &self.cwd)
        }
    }
}

/// Resolves `FILE ...` arguments to a list of paths in the repository.
pub fn resolve_file_args<'a>(
    repo: &Repo,
    file_args: impl Iterator<Item = &'a OsString>,
) -> Result<Vec<HgPathBuf>, CommandError> {
    let cwd = hg::utils::current_dir()?;
    let root = cwd.join(repo.working_directory_path());
    let mut result = Vec::new();
    for pattern in file_args {
        // TODO: Support all the formats in `hg help patterns`.
        if pattern.as_encoded_bytes().contains(&b':') {
            return Err(CommandError::unsupported(
                "rhg does not support file patterns",
            ));
        }
        // TODO: use hg::utils::files::canonical_path (currently doesn't work).
        let path = cwd.join(pattern);
        let dotted = path.components().any(|c| c.as_os_str() == "..");
        if pattern.as_encoded_bytes() == b"." || dotted {
            let message = "`..` or `.` path segment";
            return Err(CommandError::unsupported(message));
        }
        let relative_path = root.strip_prefix(&cwd).unwrap_or(&root);
        let stripped = path.strip_prefix(&root).map_err(|_| {
            CommandError::abort(format!(
                "abort: {} not under root '{}'\n(consider using '--cwd {}')",
                String::from_utf8_lossy(pattern.as_encoded_bytes()),
                root.display(),
                relative_path.display(),
            ))
        })?;
        let hg_file = HgPathBuf::try_from(stripped.to_path_buf())
            .map_err(|e| CommandError::abort(e.to_string()))?;
        result.push(hg_file);
    }
    Ok(result)
}
