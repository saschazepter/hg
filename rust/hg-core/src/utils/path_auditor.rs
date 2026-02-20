// path_auditor.rs
//
// Copyright 2020
// Raphaël Gomès <rgomes@octobus.net>,
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::collections::HashSet;
use std::path::Path;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::RwLock;

use crate::utils::files::lower_clean;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathError;
use crate::utils::hg_path::HgPathErrorKind;
use crate::utils::hg_path::hg_path_to_path_buf;
use crate::utils::strings::find_slice_in_slice;

/// Ensures that a path is valid for use in the repository i.e. does not use
/// any banned components, does not traverse a symlink, etc.
#[derive(Debug, Default)]
pub struct PathAuditor {
    audited: Mutex<HashSet<HgPathBuf>>,
    audited_dirs: RwLock<HashSet<HgPathBuf>>,
    root: PathBuf,
}

impl PathAuditor {
    pub fn new(root: impl AsRef<Path>) -> Self {
        Self { root: root.as_ref().to_owned(), ..Default::default() }
    }
    pub fn audit_path(
        &self,
        path: impl AsRef<HgPath>,
    ) -> Result<(), HgPathError> {
        // TODO windows "localpath" normalization
        let path = path.as_ref();
        if path.is_empty() {
            return Ok(());
        }
        // TODO case normalization
        if self.audited.lock().unwrap().contains(path) {
            return Ok(());
        }
        // AIX ignores "/" at end of path, others raise EISDIR.
        let last_byte = path.as_bytes()[path.len() - 1];
        if last_byte == b'/' || last_byte == b'\\' {
            return Err(HgPathErrorKind::EndsWithSlash(path.to_owned()).into());
        }
        let parts: Vec<_> = path
            .as_bytes()
            .split(|b| std::path::is_separator(*b as char))
            .collect();

        let first_component = lower_clean(parts[0]);
        let first_component = first_component.as_slice();
        if !path.split_drive().0.is_empty()
            || (first_component == b".hg"
                || first_component == b".hg."
                || first_component == b"")
            || parts.iter().any(|c| c == b"..")
        {
            return Err(HgPathErrorKind::InsideDotHg(path.to_owned()).into());
        }

        // Windows shortname aliases
        for part in parts.iter() {
            if part.contains(&b'~') {
                let mut split = part.splitn(2, |b| *b == b'~');
                let first =
                    split.next().unwrap().to_owned().to_ascii_uppercase();
                let last = split.next().unwrap();
                if last.iter().all(u8::is_ascii_digit)
                    && (first == b"HG" || first == b"HG8B6C")
                {
                    return Err(HgPathErrorKind::ContainsIllegalComponent(
                        path.to_owned(),
                    )
                    .into());
                }
            }
        }
        let lower_path = lower_clean(path.as_bytes());
        if find_slice_in_slice(&lower_path, b".hg").is_some() {
            let lower_parts: Vec<_> = path
                .as_bytes()
                .split(|b| std::path::is_separator(*b as char))
                .collect();
            for pattern in [b".hg".to_vec(), b".hg.".to_vec()].iter() {
                if let Some(pos) = lower_parts[1..]
                    .iter()
                    .position(|part| part == &pattern.as_slice())
                {
                    let base = lower_parts[..=pos]
                        .iter()
                        .fold(HgPathBuf::new(), |acc, p| {
                            acc.join(HgPath::new(p))
                        });
                    return Err(HgPathErrorKind::IsInsideNestedRepo {
                        path: path.to_owned(),
                        nested_repo: base,
                    }
                    .into());
                }
            }
        }

        let parts = &parts[..parts.len().saturating_sub(1)];

        // We don't want to add "foo/bar/baz" to `audited_dirs` before checking
        // if there's a "foo/.hg" directory. This also means we won't
        // accidentally traverse a symlink into some other filesystem (which
        // is potentially expensive to access).
        for index in 0..parts.len() {
            let prefix = &parts[..=index].join(&b'/');
            let prefix = HgPath::new(prefix);
            if self.audited_dirs.read().unwrap().contains(prefix) {
                continue;
            }
            self.check_filesystem(prefix, path)?;
            self.audited_dirs.write().unwrap().insert(prefix.to_owned());
        }

        self.audited.lock().unwrap().insert(path.to_owned());

        Ok(())
    }

    pub fn check_filesystem(
        &self,
        prefix: impl AsRef<HgPath>,
        path: impl AsRef<HgPath>,
    ) -> Result<(), HgPathError> {
        let prefix = prefix.as_ref();
        let path = path.as_ref();
        let current_path =
            self.root.join(hg_path_to_path_buf(prefix).map_err(|_| {
                HgPathErrorKind::NotFsCompliant(path.to_owned())
            })?);
        check_filesystem_single(current_path, prefix, path)?;

        Ok(())
    }

    pub fn check(&self, path: impl AsRef<HgPath>) -> bool {
        self.audit_path(path).is_ok()
    }
}

/// Check a single path for filesystem rules:
///     - Is not a valid representation on this filesystem
///     - Traverses a symlink
///     - Is inside a nested repository
///
/// This is only useful in the context of checking ancestor directories of
/// `full_path`.
///
/// # Arguments
///
/// Both `path` and `hg_path` are passed in for performance reasons.
///
/// * `ancestor`: The current ancestor of the filesystem path to check
/// * `hg_ancestor`: The `HgPath` that corresponds to `ancestor`
/// * `full_path`: The hg path that the overall logic wants to check
pub fn check_filesystem_single(
    ancestor: impl AsRef<Path>,
    hg_ancestor: &HgPath,
    full_path: &HgPath,
) -> Result<(), HgPathError> {
    let ancestor = ancestor.as_ref();
    match std::fs::symlink_metadata(ancestor) {
        Err(e) => {
            // EINVAL can be raised as invalid path syntax under win32.
            if e.kind() != std::io::ErrorKind::NotFound
                && e.kind() != std::io::ErrorKind::InvalidInput
                && e.raw_os_error() != Some(20)
            {
                // Rust does not yet have an `ErrorKind` for
                // `NotADirectory` (errno 20)
                // It happens if the dirstate contains `foo/bar` and
                // foo is not a directory
                return Err(HgPathErrorKind::NotFsCompliant(
                    full_path.to_owned(),
                )
                .into());
            }
        }
        Ok(meta) => {
            if meta.file_type().is_symlink() {
                return Err(HgPathErrorKind::TraversesSymbolicLink {
                    path: full_path.to_owned(),
                    symlink: hg_ancestor.to_owned(),
                }
                .into());
            }
            if meta.file_type().is_dir() && ancestor.join(".hg").is_dir() {
                return Err(HgPathErrorKind::IsInsideNestedRepo {
                    path: full_path.to_owned(),
                    nested_repo: hg_ancestor.to_owned(),
                }
                .into());
            }
        }
    };
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::fs::create_dir;
    use std::fs::create_dir_all;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn test_path_auditor() {
        let base_dir = tempdir().unwrap();
        let base_dir_path = base_dir.path();
        let auditor = PathAuditor::new(base_dir_path);

        let path = HgPath::new(b".hg/00changelog.i");
        assert_eq!(
            auditor.audit_path(path),
            Err(HgPathErrorKind::InsideDotHg(path.to_owned()).into())
        );
        let path = HgPath::new(b"this/is/nested/.hg/thing.txt");
        assert_eq!(
            auditor.audit_path(path),
            Err(HgPathErrorKind::IsInsideNestedRepo {
                path: path.to_owned(),
                nested_repo: HgPathBuf::from_bytes(b"this/is/nested")
            }
            .into())
        );

        create_dir_all(base_dir_path.join("this/is/nested/.hg")).unwrap();
        let path = HgPath::new(b"this/is/nested/repo");
        assert_eq!(
            auditor.audit_path(path),
            Err(HgPathErrorKind::IsInsideNestedRepo {
                path: path.to_owned(),
                nested_repo: HgPathBuf::from_bytes(b"this/is/nested")
            }
            .into())
        );

        create_dir(base_dir_path.join("realdir")).unwrap();
        File::create(base_dir_path.join("realdir/realfile")).unwrap();
        // TODO make portable
        std::os::unix::fs::symlink(
            base_dir_path.join("realdir"),
            base_dir_path.join("symlink"),
        )
        .unwrap();
        let path = HgPath::new(b"symlink/realfile");
        assert_eq!(
            auditor.audit_path(path),
            Err(HgPathErrorKind::TraversesSymbolicLink {
                path: path.to_owned(),
                symlink: HgPathBuf::from_bytes(b"symlink"),
            }
            .into())
        );
    }
}
