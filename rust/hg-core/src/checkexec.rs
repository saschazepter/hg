use std::fs;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;

const EXECFLAGS: u32 = 0o111;

fn is_executable(path: impl AsRef<Path>) -> Result<bool, io::Error> {
    let metadata = fs::metadata(path)?;
    let mode = metadata.mode();
    Ok(mode & EXECFLAGS != 0)
}

fn make_executable(path: impl AsRef<Path>) -> Result<(), io::Error> {
    let mode = fs::metadata(path.as_ref())?.mode();
    fs::set_permissions(
        path,
        fs::Permissions::from_mode((mode & 0o777) | EXECFLAGS),
    )?;
    Ok(())
}

fn copy_mode(
    src: impl AsRef<Path>,
    dst: impl AsRef<Path>,
) -> Result<(), io::Error> {
    let mode = match fs::symlink_metadata(src) {
        Ok(metadata) => metadata.mode(),
        Err(e) if e.kind() == io::ErrorKind::NotFound =>
        // copymode in python has a more complicated handling of FileNotFound
        // error, which we don't need because all it does is applying
        // umask, which the OS already does when we mkdir.
        {
            return Ok(())
        }
        Err(e) => return Err(e),
    };
    fs::set_permissions(dst, fs::Permissions::from_mode(mode))?;
    Ok(())
}

fn check_exec_impl(path: impl AsRef<Path>) -> Result<bool, io::Error> {
    let basedir = path.as_ref().join(".hg");
    let cachedir = basedir.join("wcache");
    let storedir = basedir.join("store");

    if !cachedir.exists() {
        // we want to create the 'cache' directory, not the '.hg' one.
        // Automatically creating '.hg' directory could silently spawn
        // invalid Mercurial repositories. That seems like a bad idea.
        fs::create_dir(&cachedir)
            .and_then(|()| {
                if storedir.exists() {
                    copy_mode(&storedir, &cachedir)
                } else {
                    copy_mode(&basedir, &cachedir)
                }
            })
            .ok();
    }

    let leave_file: bool;
    let checkdir: &Path;
    let checkisexec = cachedir.join("checkisexec");
    let checknoexec = cachedir.join("checknoexec");
    if cachedir.is_dir() {
        // Check if both files already exist in cache and have correct
        // permissions. if so, we assume that permissions work.
        // If not, we delete the files and try again.
        match is_executable(&checkisexec) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(e) => return Err(e),
            Ok(is_exec) => {
                if is_exec {
                    let noexec_is_exec = match is_executable(&checknoexec) {
                        Err(e) if e.kind() == io::ErrorKind::NotFound => {
                            fs::write(&checknoexec, "")?;
                            is_executable(&checknoexec)?
                        }
                        Err(e) => return Err(e),
                        Ok(exec) => exec,
                    };
                    if !noexec_is_exec {
                        // check-exec is exec and check-no-exec is not exec
                        return Ok(true);
                    }
                    fs::remove_file(&checknoexec)?;
                }
                fs::remove_file(&checkisexec)?;
            }
        }
        checkdir = &cachedir;
        leave_file = true;
    } else {
        // no cache directory (probably because .hg doesn't exist):
        // check directly in `path` and don't leave the temp file behind
        checkdir = path.as_ref();
        leave_file = false;
    };

    let tmp_file = tempfile::Builder::new()
        .permissions(std::fs::Permissions::from_mode(0o666))
        .tempfile_in(checkdir)?;

    if !is_executable(tmp_file.path())? {
        make_executable(tmp_file.path())?;
        if is_executable(tmp_file.path())? {
            if leave_file {
                tmp_file.persist(checkisexec).ok();
            }
            return Ok(true);
        }
    }

    Ok(false)
}

/// This function is a Rust rewrite of the `checkexec` function from
/// `posix.py`.
///
/// Returns `true` if the filesystem supports execute permissions.
pub fn check_exec(path: impl AsRef<Path>) -> bool {
    check_exec_impl(path).unwrap_or(false)
}
