//! Tools for moving the repository to a given revision

use std::{
    fs::Permissions,
    io::Write,
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::Path,
    sync::atomic::Ordering,
    time::Duration,
};

use crate::{
    dirstate::entry::{ParentFileData, TruncatedTimestamp},
    dirstate::{dirstate_map::DirstateEntryReset, on_disk::write_tracked_key},
    errors::{HgError, IoResultExt},
    exit_codes, narrow,
    operations::{list_rev_tracked_files, ExpandedManifestEntry},
    progress::Progress,
    repo::Repo,
    revlog::filelog::Filelog,
    revlog::node::NULL_NODE,
    revlog::options::{default_revlog_options, RevlogOpenOptions},
    revlog::RevlogError,
    sparse,
    utils::{
        cap_default_rayon_threads,
        files::{filesystem_now, get_path_from_bytes},
        hg_path::{hg_path_to_path_buf, HgPath, HgPathError},
        path_auditor::PathAuditor,
    },
    vfs::{is_on_nfs_mount, VfsImpl},
    DirstateParents, UncheckedRevision, INTERRUPT_RECEIVED,
};
use crossbeam_channel::{Receiver, Sender};
use rayon::prelude::*;

fn write_dirstate(repo: &Repo) -> Result<(), HgError> {
    repo.write_dirstate()
        .map_err(|e| HgError::abort(e.to_string(), exit_codes::ABORT, None))?;
    write_tracked_key(repo)
}

/// Update the current working copy of `repo` to the given revision `to`, from
/// the null revision and set + write out the dirstate to reflect that.
///
/// Do not call this outside of a Python context. This does *not* handle any
/// of the checks, hooks, lock taking needed to setup and get out of this
/// update from the null revision.
pub fn update_from_null(
    repo: &Repo,
    to: UncheckedRevision,
    progress: &dyn Progress,
    workers: Option<usize>,
) -> Result<usize, HgError> {
    // Ignore the warnings, they've been displayed by Python already
    // TODO non-Python clients: display narrow warnings
    let (narrow_matcher, _) = narrow::matcher(repo)?;

    let files_for_rev = list_rev_tracked_files(repo, to, narrow_matcher)
        .map_err(handle_revlog_error)?;
    repo.manually_set_parents(DirstateParents {
        p1: repo.node(to).expect("update target should exist"),
        p2: NULL_NODE,
    })?;

    // Filter the working copy according to the sparse spec
    let tracked_files: Result<Vec<_>, _> = if !repo.has_sparse() {
        files_for_rev.iter().collect()
    } else {
        // Ignore the warnings, they've been displayed by Python already
        // TODO non-Python clients: display sparse warnings
        let (sparse_matcher, _) = sparse::matcher(repo)?;
        files_for_rev
            .iter()
            .filter(|f| {
                match f {
                    Ok(f) => sparse_matcher.matches(f.0),
                    Err(_) => true, // Errors stop the update, include them
                }
            })
            .collect()
    };
    let tracked_files = tracked_files?;

    if tracked_files.is_empty() {
        // Still write the dirstate because we might not be in the null
        // revision.
        // This can happen in narrow repos where all paths are excluded in
        // this revision.
        write_dirstate(repo)?;
        return Ok(0);
    }
    let store_vfs = &repo.store_vfs();
    let options = default_revlog_options(
        repo.config(),
        repo.requirements(),
        crate::revlog::RevlogType::Filelog,
    )?;
    let (errors_sender, errors_receiver) = crossbeam_channel::unbounded();
    let (files_sender, files_receiver) = crossbeam_channel::unbounded();
    let working_directory_path = &repo.working_directory_path();

    let files_count = tracked_files.len();
    let chunks = chunk_tracked_files(tracked_files);
    progress.update(0, Some(files_count as u64));

    // TODO find a way (with `nix` or `signal-hook`?) of resetting the
    // previous signal handler directly after. Currently, this is Python's
    // job, but:
    //     - it introduces a (small) race between catching and resetting
    //     - it would break signal handlers in other contexts like `rhg``
    let _ = ctrlc::set_handler(|| {
        INTERRUPT_RECEIVED.store(true, Ordering::Relaxed)
    });

    create_working_copy(
        chunks,
        working_directory_path,
        store_vfs,
        options,
        files_sender,
        errors_sender,
        progress,
        workers,
    );

    // Reset the global interrupt now that we're done
    if INTERRUPT_RECEIVED.swap(false, Ordering::Relaxed) {
        // The threads have all exited early, let's re-raise
        return Err(HgError::InterruptReceived);
    }

    let errors: Vec<HgError> = errors_receiver.iter().collect();
    if !errors.is_empty() {
        log::debug!("{} errors during update (see trace logs)", errors.len());
        for error in errors.iter() {
            log::trace!("{}", error);
        }
        // Best we can do is raise the first error (in order of the channel)
        return Err(errors.into_iter().next().expect("can never be empty"));
    }

    // TODO try to run this concurrently to update the dirstate while we're
    // still writing out the working copy to see if that improves performance.
    let total = update_dirstate(repo, files_receiver)?;

    write_dirstate(repo)?;

    Ok(total)
}

fn handle_revlog_error(e: RevlogError) -> HgError {
    match e {
        crate::revlog::RevlogError::Other(hg_error) => hg_error,
        e => HgError::abort(
            format!("revlog error: {}", e),
            exit_codes::ABORT,
            None,
        ),
    }
}

/// Preallocated size of Vec holding directory contents. This aims at
/// preventing the need for re-allocating the Vec in most cases.
///
/// The value is arbitrarily picked as a little over an average number of files
/// per directory done by looking at a few larger open-source repos.
/// Most of the runtime is IO anyway, so this doesn't matter too much.
const FILES_PER_DIRECTORY: usize = 16;

/// Chunk files per directory prefix, so almost every directory is handled
/// in a separate thread, which works around the FS inode mutex.
/// Chunking less (and doing approximately `files_count`/`threads`) actually
/// ends up being less performant: my hypothesis is `rayon`'s work stealing
/// being more efficient with tasks of varying lengths.
#[logging_timer::time("trace")]
fn chunk_tracked_files(
    tracked_files: Vec<ExpandedManifestEntry>,
) -> Vec<(&HgPath, Vec<ExpandedManifestEntry>)> {
    let files_count = tracked_files.len();

    let mut chunks = Vec::with_capacity(files_count / FILES_PER_DIRECTORY);

    let mut current_chunk = Vec::with_capacity(FILES_PER_DIRECTORY);
    let mut last_directory = tracked_files[0].0.parent();

    for file_info in tracked_files {
        let current_directory = file_info.0.parent();
        let different_directory = current_directory != last_directory;
        if different_directory {
            chunks.push((last_directory, current_chunk));
            current_chunk = Vec::with_capacity(FILES_PER_DIRECTORY);
        }
        current_chunk.push(file_info);
        last_directory = current_directory;
    }
    chunks.push((last_directory, current_chunk));
    chunks
}

#[logging_timer::time("trace")]
#[allow(clippy::too_many_arguments)]
fn create_working_copy<'a: 'b, 'b>(
    chunks: Vec<(&HgPath, Vec<ExpandedManifestEntry<'a>>)>,
    working_directory_path: &Path,
    store_vfs: &VfsImpl,
    options: RevlogOpenOptions,
    files_sender: Sender<(&'b HgPath, u32, usize, TruncatedTimestamp)>,
    error_sender: Sender<HgError>,
    progress: &dyn Progress,
    workers: Option<usize>,
) {
    let auditor = PathAuditor::new(working_directory_path);

    let work_closure = |(dir_path, chunk)| -> Result<(), HgError> {
        if let Err(e) = working_copy_worker(
            dir_path,
            chunk,
            working_directory_path,
            store_vfs,
            options,
            &files_sender,
            progress,
            &auditor,
        ) {
            error_sender
                .send(e)
                .expect("channel should not be disconnected")
        }
        Ok(())
    };
    if let Some(workers) = workers {
        if workers > 1 {
            // Work in parallel, potentially restricting the number of threads
            match rayon::ThreadPoolBuilder::new().num_threads(workers).build()
            {
                Err(error) => error_sender
                    .send(HgError::abort(
                        error.to_string(),
                        exit_codes::ABORT,
                        None,
                    ))
                    .expect("channel should not be disconnected"),
                Ok(pool) => {
                    log::trace!("restricting update to {} threads", workers);
                    pool.install(|| {
                        let _ =
                            chunks.into_par_iter().try_for_each(work_closure);
                    });
                }
            }
        } else {
            // Work sequentially, don't even invoke rayon
            let _ = chunks.into_iter().try_for_each(work_closure);
        }
    } else {
        // Work in parallel by default in the global threadpool
        let _ = cap_default_rayon_threads();
        let _ = chunks.into_par_iter().try_for_each(work_closure);
    }
}

/// Represents a work unit for a single thread, responsible for this set of
/// files and restoring them to the working copy.
#[allow(clippy::too_many_arguments)]
fn working_copy_worker<'a: 'b, 'b>(
    dir_path: &HgPath,
    chunk: Vec<ExpandedManifestEntry<'a>>,
    working_directory_path: &Path,
    store_vfs: &VfsImpl,
    options: RevlogOpenOptions,
    files_sender: &Sender<(&'b HgPath, u32, usize, TruncatedTimestamp)>,
    progress: &dyn Progress,
    auditor: &PathAuditor,
) -> Result<(), HgError> {
    let dir_path =
        hg_path_to_path_buf(dir_path).expect("invalid path in manifest");
    let dir_path = working_directory_path.join(dir_path);
    std::fs::create_dir_all(&dir_path).when_writing_file(&dir_path)?;

    if INTERRUPT_RECEIVED.load(Ordering::Relaxed) {
        // Stop working, the user has requested that we stop
        return Err(HgError::InterruptReceived);
    }

    for (file, file_node, flags) in chunk {
        auditor.audit_path(file)?;
        let flags = flags.map(|f| f.into());
        let path =
            working_directory_path.join(get_path_from_bytes(file.as_bytes()));

        // Treemanifest is not supported
        assert!(flags != Some(b't'));

        let filelog = Filelog::open_vfs(store_vfs, file, options)?;
        let filelog_revision_data = &filelog
            .data_for_node(file_node)
            .map_err(handle_revlog_error)?;
        let file_data = filelog_revision_data.file_data()?;

        if flags == Some(b'l') {
            let target = get_path_from_bytes(file_data);
            if let Err(e) = std::os::unix::fs::symlink(target, &path) {
                // If the path already exists either:
                //   - another process created this file while ignoring the
                //     lock => error
                //   - our check for the fast path is incorrect => error
                //   - this is a malicious repo/bundle and this is symlink that
                //     tries to write things where it shouldn't be able to.
                match e.kind() {
                    std::io::ErrorKind::AlreadyExists => {
                        let metadata = std::fs::symlink_metadata(&path)
                            .when_reading_file(&path)?;
                        if metadata.is_dir() {
                            return Err(HgError::Path(
                                HgPathError::TraversesSymbolicLink {
                                    // Technically it should be one of the
                                    // children, but good enough
                                    path: file
                                        .join(HgPath::new(b"*"))
                                        .to_owned(),
                                    symlink: file.to_owned(),
                                },
                            ));
                        }
                        return Err(e).when_writing_file(&path);
                    }
                    _ => return Err(e).when_writing_file(&path),
                }
            }
        } else {
            let mut f =
                std::fs::File::create(&path).when_writing_file(&path)?;
            f.write_all(file_data).when_writing_file(&path)?;
        }
        if flags == Some(b'x') {
            std::fs::set_permissions(&path, Permissions::from_mode(0o755))
                .when_writing_file(&path)?;
        }
        let metadata =
            std::fs::symlink_metadata(&path).when_reading_file(&path)?;

        let mode = metadata.mode();

        files_sender
            .send((
                file,
                mode,
                file_data.len(),
                TruncatedTimestamp::for_mtime_of(&metadata)
                    .when_reading_file(&path)?,
            ))
            .expect("channel should not be closed");
        progress.increment(1, None);
    }
    Ok(())
}

#[logging_timer::time("trace")]
fn update_dirstate(
    repo: &Repo,
    files_receiver: Receiver<(&HgPath, u32, usize, TruncatedTimestamp)>,
) -> Result<usize, HgError> {
    let mut dirstate = repo
        .dirstate_map_mut()
        .map_err(|e| HgError::abort(e.to_string(), exit_codes::ABORT, None))?;

    // (see the comments in `filter_ambiguous_files` in `merge.py` for more)
    // It turns out that (on Linux at least) the filesystem resolution time
    // for most filesystems is based on the HZ kernel config. Their internal
    // clocks do return nanoseconds if the hardware clock is precise enough,
    // which should be the case on most recent computers but are only updated
    // every few milliseconds at best (every "jiffy").
    //
    // We are still not concerned with fixing the race with other
    // processes that might modify the working copy right after it was created
    // within the same tick, because it is impossible to catch.
    // However, we might as well not race with operations that could run right
    // after this one, especially other Mercurial operations that could be
    // waiting for the wlock to change file contents and the dirstate.
    //
    // Thus: wait until the filesystem clock has ticked to filter ambiguous
    // entries and write the dirstate, but only for dirstate-v2, since v1 only
    // has second-level granularity and waiting for a whole second is too much
    // of a penalty in the general case.
    // Although we're assuming that people running dirstate-v2 on Linux
    // don't have a second-granularity FS (with the exclusion of NFS), users
    // can be surprising, and at some point in the future dirstate-v2 will
    // become the default. To that end, we limit the wait time to 100ms and
    // fall back to the filter method in case of a timeout.
    //
    // +------------+------+--------------+
    // |   version  | wait | filter level |
    // +------------+------+--------------+
    // |     V1     | No   | Second       |
    // |     V2     | Yes  | Nanosecond   |
    // | V2-slow-fs | No   | Second       |
    // +------------+------+--------------+
    let dirstate_v2 = repo.use_dirstate_v2();

    // Let's ignore NFS right off the bat
    let mut fast_enough_fs = !is_on_nfs_mount(repo.working_directory_path());
    let fs_time_now = if dirstate_v2 && fast_enough_fs {
        match wait_until_fs_tick(repo.working_directory_path()) {
            None => None,
            Some(Ok(time)) => Some(time),
            Some(Err(time)) => {
                fast_enough_fs = false;
                Some(time)
            }
        }
    } else {
        filesystem_now(repo.working_directory_path())
            .ok()
            .map(TruncatedTimestamp::from)
    };

    let mut total = 0;
    for (filename, mode, size, mtime) in files_receiver.into_iter() {
        total += 1;
        // When using dirstate-v2 on a filesystem with reasonable performance
        // this is basically always true unless you get a mtime from the
        // far future.
        let has_meaningful_mtime = if let Some(fs_time) = fs_time_now {
            mtime.for_reliable_mtime_of_self(&fs_time).is_some_and(|t| {
                // Dirstate-v1 only has second-level information
                !t.second_ambiguous || dirstate_v2 && fast_enough_fs
            })
        } else {
            // We somehow failed to write to the filesystem, so don't store
            // the cache information.
            false
        };
        let reset = DirstateEntryReset {
            filename,
            wc_tracked: true,
            p1_tracked: true,
            p2_info: false,
            has_meaningful_mtime,
            parent_file_data_opt: Some(ParentFileData {
                mode_size: Some((
                    mode,
                    size.try_into().expect("invalid file size in manifest"),
                )),
                mtime: Some(mtime),
            }),
            from_empty: true,
        };
        dirstate.reset_state(reset).map_err(|e| {
            HgError::abort(e.to_string(), exit_codes::ABORT, None)
        })?;
    }

    Ok(total)
}

/// Wait until the next update from the filesystem time by writing in a loop
/// a new temporary file inside the working directory and checking if its time
/// differs from the first one observed.
///
/// Returns `None` if we are unable to get the filesystem time,
/// `Some(Err(timestamp))` if we've timed out waiting for the filesystem clock
/// to tick, and `Some(Ok(timestamp))` if we've waited successfully.
///
/// On Linux, your average tick is going to be a "jiffy", or 1/HZ.
/// HZ is your kernel's tick rate (if it has one configured) and the value
/// is the one returned by `grep 'CONFIG_HZ=' /boot/config-$(uname -r)`,
/// again assuming a normal setup.
///
/// In my case (Alphare) at the time of writing, I get `CONFIG_HZ=250`,
/// which equates to 4ms.
///
/// This might change with a series that could make it to Linux 6.12:
/// https://lore.kernel.org/all/20241002-mgtime-v10-8-d1c4717f5284@kernel.org
fn wait_until_fs_tick(
    working_directory_path: &Path,
) -> Option<Result<TruncatedTimestamp, TruncatedTimestamp>> {
    let start = std::time::Instant::now();
    let old_fs_time = filesystem_now(working_directory_path).ok()?;
    let mut fs_time = filesystem_now(working_directory_path).ok()?;

    const FS_TICK_WAIT_TIMEOUT: Duration = Duration::from_millis(100);

    while fs_time == old_fs_time {
        if std::time::Instant::now() - start > FS_TICK_WAIT_TIMEOUT {
            log::trace!(
                "timed out waiting for the fs clock to tick after {:?}",
                FS_TICK_WAIT_TIMEOUT
            );
            return Some(Err(TruncatedTimestamp::from(old_fs_time)));
        }
        fs_time = filesystem_now(working_directory_path).ok()?;
    }
    log::trace!(
        "waited for {:?} before writing the dirstate",
        fs_time.duration_since(old_fs_time)
    );
    Some(Ok(TruncatedTimestamp::from(fs_time)))
}

#[cfg(test)]
mod test {
    use super::*;
    use pretty_assertions::assert_eq;

    #[test]
    fn test_chunk_tracked_files() {
        fn chunk(v: Vec<&'static str>) -> Vec<ExpandedManifestEntry> {
            v.into_iter()
                .map(|f| (HgPath::new(f.as_bytes()), NULL_NODE, None))
                .collect()
        }
        let p = HgPath::new;

        let files = chunk(vec!["a"]);
        let expected = vec![(p(""), chunk(vec!["a"]))];
        assert_eq!(chunk_tracked_files(files), expected);

        let files = chunk(vec!["a", "b", "c"]);
        let expected = vec![(p(""), chunk(vec!["a", "b", "c"]))];
        assert_eq!(chunk_tracked_files(files), expected);

        let files = chunk(vec![
            "dir/a-new",
            "dir/a/mut",
            "dir/a/mut-mut",
            "dir/albert",
            "dir/b",
            "dir/subdir/c",
            "dir/subdir/d",
            "file",
        ]);
        let expected = vec![
            (p("dir"), chunk(vec!["dir/a-new"])),
            (p("dir/a"), chunk(vec!["dir/a/mut", "dir/a/mut-mut"])),
            (p("dir"), chunk(vec!["dir/albert", "dir/b"])),
            (p("dir/subdir"), chunk(vec!["dir/subdir/c", "dir/subdir/d"])),
            (p(""), chunk(vec!["file"])),
        ];
        assert_eq!(chunk_tracked_files(files), expected);

        // Doesn't get split
        let large_dir = vec![
            "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12",
            "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23",
        ];
        let files = chunk(large_dir.clone());
        let expected = vec![(p(""), chunk(large_dir))];
        assert_eq!(chunk_tracked_files(files), expected);
    }
}
