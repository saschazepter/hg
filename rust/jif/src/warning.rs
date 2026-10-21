//! Warnings that `jf` commands can report.

use format_bytes::Message;
use format_bytes::Utf8;
use format_bytes::message;
use hg::file_patterns::PatternFileWarning;
use hg::sparse::SparseNarrowWarning;
use hg::update::UpdateWarning;
use hg::utils::files::get_bytes_from_path;
use hg::warnings::HgWarning;

/// What users should know about, without the command failing
#[derive(Debug)]
pub struct Warning {
    /// What is wrong, worded for users
    pub message: Message,
}

impl Warning {
    /// A warning saying `message`
    pub fn new(message: Message) -> Self {
        Self { message }
    }
}

/// We do our own formatting of `HgWarning`, like [`crate::error::hg_message`].
impl From<HgWarning> for Warning {
    fn from(warning: HgWarning) -> Self {
        // Matched exhaustively, so that new warnings make us think about how
        // to show them.
        let message = match warning {
            HgWarning::SparseNarrow(warning) => match warning {
                SparseNarrowWarning::RootWarning { context, line } => message!(
                    "{context} profile cannot use paths starting with /, \
                    ignoring {line}"
                ),
                SparseNarrowWarning::ProfileNotFound { profile, node } => {
                    match node {
                        Some(node) => message!(
                            "sparse profile '{profile}' not found in rev \
                            {node} - ignoring it",
                            node = Utf8(format!("{:x}", node.short()))
                        ),
                        None => message!(
                            "sparse profile '{profile}' not found - ignoring it"
                        ),
                    }
                }
            },
            HgWarning::PatternFile(warning) => match warning {
                PatternFileWarning::InvalidSyntax(path, syntax) => message!(
                    "{path}: ignoring invalid syntax '{syntax}'",
                    path = get_bytes_from_path(path)
                ),
                PatternFileWarning::NoSuchFile(path) => message!(
                    "skipping unreadable pattern file '{path}': \
                    no such file or directory",
                    path = get_bytes_from_path(path)
                ),
                PatternFileWarning::IncludeInSubinclude(path, include) => {
                    message!(
                        "{path}: include is not allowed inside a subincluded \
                        file; skipping 'include:{include}'",
                        path = get_bytes_from_path(path)
                    )
                }
                PatternFileWarning::SubincludeEscapesDirectory(subinclude) => {
                    message!(
                        "subinclude '{subinclude}' escapes its directory; \
                        skipping"
                    )
                }
            },
            HgWarning::Update(warning) => match warning {
                // TODO render the error once `hg-core` gives it structure
                UpdateWarning::UnlinkFailure(path, error) => message!(
                    "update failed to remove {path}: {error}",
                    path = get_bytes_from_path(path),
                    error = Utf8(format!("{error:?}"))
                ),
                UpdateWarning::CwdRemoved => {
                    message!("current directory was removed")
                }
                UpdateWarning::UntrackedConflict(path) => message!(
                    "{path}: untracked file differs",
                    path = path.into_vec()
                ),
                UpdateWarning::ReplacingUntracked(path) => message!(
                    "{path}: replacing untracked file",
                    path = path.into_vec()
                ),
            },
        };
        Self::new(message)
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;
    use std::path::PathBuf;

    use hg::utils::hg_path::HgPathBuf;
    use serde_json::json;

    use super::*;
    use crate::terminal::render;

    fn path(bytes: &[u8]) -> PathBuf {
        OsStr::from_bytes(bytes).into()
    }

    #[test]
    fn hg_warning_escapes_user_data() {
        let warning =
            Warning::from(HgWarning::from(PatternFileWarning::InvalidSyntax(
                path(b"/repo/.hgignore"),
                b"caf\xe9".to_vec(),
            )));
        assert_eq!(
            render(&warning.message),
            "/repo/.hgignore: ignoring invalid syntax 'caf\\xe9'"
        );
        let warning =
            Warning::from(HgWarning::from(UpdateWarning::ReplacingUntracked(
                HgPathBuf::from_bytes(b"\x1b[31m"),
            )));
        assert_eq!(
            render(&warning.message),
            "\\u{1b}[31m: replacing untracked file"
        );
    }

    #[test]
    fn hg_warning_keeps_user_data_as_arguments() {
        let warning =
            Warning::from(HgWarning::from(PatternFileWarning::InvalidSyntax(
                path(b"/caf\xe9/.hgignore"),
                b"foo".to_vec(),
            )));
        let args = &crate::json::warning(&warning)["message"]["args"];
        assert_eq!(
            *args,
            json!({"path": {"base64": "L2NhZukvLmhnaWdub3Jl"}, "syntax": "foo"})
        );
    }

    #[test]
    fn hg_warning_without_node() {
        let warning = Warning::from(HgWarning::from(
            SparseNarrowWarning::ProfileNotFound {
                profile: b"base.sparse".to_vec(),
                node: None,
            },
        ));
        assert_eq!(
            render(&warning.message),
            "sparse profile 'base.sparse' not found - ignoring it"
        );
    }
}
