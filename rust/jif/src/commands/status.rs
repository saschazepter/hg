use std::io::Write;
use std::mem::take;

use format_bytes::format_bytes;
use hg::dirstate::status::BadMatch;
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
use hg::{self};
use rayon::iter::IntoParallelIterator;
use rayon::iter::ParallelIterator;
use tracing::info;

// use std::ffi::OsString;
// use std::io::stdout;
// use std::io::Write;
// use std::path::PathBuf;
//
// use hg::revlog::filelog::FilelogRevisionData;
// use hg::revlog::RevisionOrWdir;
// use hg::utils::hg_path::path_to_hg_path_buf;
use crate::utils::RepoInvocation;

#[derive(clap::Args)]
pub struct Args {}

pub fn run(invocation: RepoInvocation, _args: Args) {
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

    let mut stderr = std::io::stderr();

    let after_status = |res: StatusResult, _warnings| {
        let mut ds_status = res.expect("status failed");
        for (path, error) in take(&mut ds_status.bad) {
            let error = match error {
                BadMatch::OsError(code) => {
                    std::io::Error::from_raw_os_error(code).to_string()
                }
                BadMatch::BadType(ty) => {
                    format!("unsupported file type (type is {})", ty)
                }
            };
            stderr
                .write_all(&format_bytes!(
                    b"{}: {}\n",
                    path.as_bytes(),
                    error.as_bytes()
                ))
                .expect("bad bad");
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
                    FileCompOutcome::Modified => {
                        ds_status.modified.push(status_path);
                    }
                    FileCompOutcome::Deleted => {
                        ds_status.deleted.push(status_path);
                    }
                }
            }
        }

        display(b"R ", ds_status.removed);
        display(b"A ", ds_status.added);
        display(b"! ", ds_status.deleted);
        display(b"M ", ds_status.modified);
        display(b"? ", ds_status.unknown);
    };

    dmap.with_status(
        &matcher,
        repo.working_directory_path().to_owned(),
        get_ignore_files(&repo),
        options,
        after_status,
    );
}

fn display(status_prefix: &[u8], mut paths: Vec<StatusPath<'_>>) {
    paths.sort_unstable();
    let mut stdout = std::io::stdout();
    for StatusPath { path, copy_source } in paths {
        let (path, copy_source) =
            (path.as_bytes(), copy_source.as_ref().map(|s| s.as_bytes()));
        // TODO: Add a way to use `write_bytes!` instead of
        // `format_bytes!` in order to stream to stdout
        // instead of allocating an itermediate
        // `Vec<u8>`.
        stdout.write_all(status_prefix).expect("write_failed");
        let linebreak = b"\n";
        stdout
            .write_all(&format_bytes!(b"{}{}", path, linebreak))
            .expect("write_failed");
        if let Some(source) = copy_source {
            stdout
                .write_all(&format_bytes!(b"  {}{}", source, linebreak))
                .expect("write_failed");
        }
    }
    stdout.flush().expect("flush failed");
}
