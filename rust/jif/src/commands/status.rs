use std::convert::Infallible;
use std::io;
use std::mem::take;

use format_bytes::Utf8;
use format_bytes::message;
use hg::dirstate::status::BadMatch;
use hg::dirstate::status::BadType;
use hg::dirstate::status::DirstateStatus;
use hg::dirstate::status::StatusError;
use hg::dirstate::status::StatusOptions;
use hg::dirstate::status::StatusPath;
use hg::matchers::AlwaysMatcher;
use hg::matchers::get_ignore_files;
use hg::revlog::RevlogError;
use hg::revlog::RevlogType;
use hg::revlog::filelog::FileCompOutcome;
use hg::revlog::filelog::is_file_modified;
use hg::revlog::options::default_revlog_options;
use hg::warnings::HgWarningContext;
use hg::{self};
use rayon::iter::IntoParallelIterator;
use rayon::iter::ParallelIterator;
use tracing::info;

use crate::output::Output;
use crate::record;
use crate::utils::RepoInvocation;
use crate::warning::Warning;

#[derive(clap::Args)]
pub struct Args {}

pub fn run(invocation: RepoInvocation, _args: Args, output: &Output) {
    let repo = invocation.repo;

    let matcher = Box::new(AlwaysMatcher);
    let mut dmap =
        repo.dirstate_map_mut().expect("dirstate_map_mut needs error handling");

    let check_exec = hg::checkexec::check_exec(repo.working_directory_path());

    let options = StatusOptions {
        check_exec,
        list_clean: false,
        list_unknown: true,
        list_ignored: false,
        list_copies: true,
        collect_traversed_dirs: false,
        empty_dirs_keep_files: false,
    };

    type StatusResult<'a> = Result<DirstateStatus<'a>, StatusError>;

    let after_status = |res: StatusResult, hg_warnings: HgWarningContext| {
        let Ok(()) = hg_warnings.finish(|warning| {
            output.warn(warning.into());
            Ok::<_, Infallible>(())
        });
        let mut ds_status = res.expect("status failed");
        for (path, error) in take(&mut ds_status.bad) {
            let path = path.as_bytes().to_vec();
            let message = match error {
                BadMatch::OsError(code) => {
                    let error = Utf8(io::Error::from_raw_os_error(code));
                    message!("{path}: {error}")
                }
                BadMatch::BadType(kind) => {
                    let kind = match kind {
                        BadType::CharacterDevice => "character device",
                        BadType::BlockDevice => "block device",
                        BadType::FIFO => "fifo",
                        BadType::Socket => "socket",
                        BadType::Directory => "directory",
                        BadType::Unknown => "unknown",
                    };
                    message!(
                        "{path}: unsupported file type (type is {kind})",
                        kind = Utf8(kind)
                    )
                }
            };
            output.warn(Warning::new(message));
        }
        if !ds_status.unsure.is_empty() {
            info!(
                "Must recheck {} files by retrieval from filelog",
                ds_status.unsure.len()
            );
        }

        let mut fixup = Vec::new();
        if !ds_status.unsure.is_empty() {
            let p1 =
                repo.dirstate_parents().expect("can't get dirstate parents").p1;
            let manifest =
                repo.manifest_for_node(p1).expect("can't find p1 node");
            let working_directory_vfs = repo.working_directory_vfs();
            let store_vfs = repo.store_vfs();
            let filelog_open_options = default_revlog_options(
                repo.config(),
                repo.requirements(),
                RevlogType::Filelog,
            )
            .expect("can't open revlog");
            let res: Vec<_> = take(&mut ds_status.unsure)
                .into_par_iter()
                .map(|to_check| {
                    // The compiler seems to get a bit confused with complex
                    // inference when using a parallel iterator + map
                    // + map_err + collect, so let's just inline some of the
                    // logic.

                    // Check we are unsure if the file has changed because
                    // our filesystem is not precise enough and the rest of
                    // the metadata was ambiguous, so check the data for real.
                    match is_file_modified(
                        &working_directory_vfs,
                        &store_vfs,
                        check_exec,
                        &manifest,
                        &to_check.path,
                        &filelog_open_options,
                    ) {
                        Err(RevlogError::IO(_)) => {
                            // IO errors most likely stem from the file being
                            // deleted even though we know it's in the
                            // dirstate.
                            Ok((to_check, FileCompOutcome::Deleted))
                        }
                        Ok(outcome) => Ok((to_check, outcome)),
                        Err(e) => Err(e),
                    }
                })
                .collect::<Result<_, _>>()
                .expect("collect failed");
            for (status_path, outcome) in res.into_iter() {
                match outcome {
                    FileCompOutcome::Clean => {
                        ds_status.clean.push(status_path.clone());
                        fixup.push(status_path.path.into_owned())
                    }
                    FileCompOutcome::Modified { .. } => {
                        ds_status.modified.push(status_path);
                    }
                    FileCompOutcome::Deleted => {
                        ds_status.deleted.push(status_path);
                    }
                }
            }
        }

        display(output, b"R", ds_status.removed);
        display(output, b"A", ds_status.added);
        display(output, b"!", ds_status.deleted);
        display(output, b"M", ds_status.modified);
        display(output, b"?", ds_status.unknown);
    };

    dmap.with_status(
        &matcher,
        repo.working_directory_path().to_owned(),
        get_ignore_files(&repo),
        options,
        after_status,
    );
}

fn display(output: &Output, status: &[u8], mut paths: Vec<StatusPath<'_>>) {
    paths.sort_unstable();
    for StatusPath { path, copy_source } in paths {
        let path = path.as_bytes();
        match copy_source {
            None => record!(output, "status", "{status} {path}\n"),
            Some(source) => record!(
                output,
                "status",
                "{status} {path}\n  {copy_source}\n",
                copy_source = source.as_bytes()
            ),
        }
        .expect("write failed");
    }
}
