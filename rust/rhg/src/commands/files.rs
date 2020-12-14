use crate::commands::Command;
use crate::error::{CommandError, CommandErrorKind};
use crate::ui::utf8_to_local;
use crate::ui::Ui;
use hg::operations::{
    list_rev_tracked_files, ListRevTrackedFilesError,
    ListRevTrackedFilesErrorKind,
};
use hg::operations::{
    Dirstate, ListDirstateTrackedFilesError, ListDirstateTrackedFilesErrorKind,
};
use hg::repo::Repo;
use hg::utils::files::{get_bytes_from_path, relativize_path};
use hg::utils::hg_path::{HgPath, HgPathBuf};

pub const HELP_TEXT: &str = "
List tracked files.

Returns 0 on success.
";

pub struct FilesCommand<'a> {
    rev: Option<&'a str>,
}

impl<'a> FilesCommand<'a> {
    pub fn new(rev: Option<&'a str>) -> Self {
        FilesCommand { rev }
    }

    fn display_files(
        &self,
        ui: &Ui,
        repo: &Repo,
        files: impl IntoIterator<Item = &'a HgPath>,
    ) -> Result<(), CommandError> {
        let cwd = std::env::current_dir()
            .or_else(|e| Err(CommandErrorKind::CurrentDirNotFound(e)))?;
        let rooted_cwd = cwd
            .strip_prefix(repo.working_directory_path())
            .expect("cwd was already checked within the repository");
        let rooted_cwd = HgPathBuf::from(get_bytes_from_path(rooted_cwd));

        let mut stdout = ui.stdout_buffer();

        for file in files {
            stdout.write_all(relativize_path(file, &rooted_cwd).as_ref())?;
            stdout.write_all(b"\n")?;
        }
        stdout.flush()?;
        Ok(())
    }
}

impl<'a> Command for FilesCommand<'a> {
    fn run(&self, ui: &Ui) -> Result<(), CommandError> {
        let repo = Repo::find()?;
        repo.check_requirements()?;
        if let Some(rev) = self.rev {
            let files = list_rev_tracked_files(&repo, rev)
                .map_err(|e| map_rev_error(rev, e))?;
            self.display_files(ui, &repo, files.iter())
        } else {
            let distate = Dirstate::new(&repo).map_err(map_dirstate_error)?;
            let files = distate.tracked_files().map_err(map_dirstate_error)?;
            self.display_files(ui, &repo, files)
        }
    }
}

/// Convert `ListRevTrackedFilesErrorKind` to `CommandError`
fn map_rev_error(rev: &str, err: ListRevTrackedFilesError) -> CommandError {
    CommandError {
        kind: match err.kind {
            ListRevTrackedFilesErrorKind::IoError(err) => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!("abort: {}\n", err)).into(),
                ))
            }
            ListRevTrackedFilesErrorKind::InvalidRevision => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!(
                        "abort: invalid revision identifier {}\n",
                        rev
                    ))
                    .into(),
                ))
            }
            ListRevTrackedFilesErrorKind::AmbiguousPrefix => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!(
                        "abort: ambiguous revision identifier {}\n",
                        rev
                    ))
                    .into(),
                ))
            }
            ListRevTrackedFilesErrorKind::UnsuportedRevlogVersion(version) => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!(
                        "abort: unsupported revlog version {}\n",
                        version
                    ))
                    .into(),
                ))
            }
            ListRevTrackedFilesErrorKind::CorruptedRevlog => {
                CommandErrorKind::Abort(Some(
                    "abort: corrupted revlog\n".into(),
                ))
            }
            ListRevTrackedFilesErrorKind::UnknowRevlogDataFormat(format) => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!(
                        "abort: unknow revlog dataformat {:?}\n",
                        format
                    ))
                    .into(),
                ))
            }
        },
    }
}

/// Convert `ListDirstateTrackedFilesError` to `CommandError`
fn map_dirstate_error(err: ListDirstateTrackedFilesError) -> CommandError {
    CommandError {
        kind: match err.kind {
            ListDirstateTrackedFilesErrorKind::IoError(err) => {
                CommandErrorKind::Abort(Some(
                    utf8_to_local(&format!("abort: {}\n", err)).into(),
                ))
            }
            ListDirstateTrackedFilesErrorKind::ParseError(_) => {
                CommandErrorKind::Abort(Some(
                    // TODO find a better error message
                    b"abort: parse error\n".to_vec(),
                ))
            }
        },
    }
}
