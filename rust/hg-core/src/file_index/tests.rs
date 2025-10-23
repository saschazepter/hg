//! Tests for the file index.
//! See tests/test-file-index.t for more comprehensive testing.

use super::*;
use crate::revlog::path_encode::PathEncoding;
use crate::utils::hg_path::HgPath;

/// Creates an empty file index in a temporary directory.
fn create_file_index() -> Result<(FileIndex, tempfile::TempDir), HgError> {
    let temp_dir = tempfile::tempdir().expect("creating tempdir");
    let base = temp_dir.path().to_owned();
    let vfs = VfsImpl::new(base, false, PathEncoding::None);
    let try_pending = false;
    let config = Config {
        vacuum_mode: VacuumMode::Never,
        max_unused_ratio: 1.0,
        gc_retention_s: 0,
        garbage_timestamp: None,
    };
    let devel_sync_point = || {};
    Ok((FileIndex::open(vfs, try_pending, config, devel_sync_point)?, temp_dir))
}

/// Asserts that the file index contains the given tokens and paths.
/// The tokens must be in ascending order.
#[track_caller]
fn check_paths(file_index: &FileIndex, tokens_and_paths: &[(u32, &HgPath)]) {
    let paths =
        tokens_and_paths.iter().map(|&(_, path)| path).collect::<Vec<_>>();
    let actual_paths = file_index
        .iter()
        .map(|result| Ok(result?.0))
        .collect::<Result<Vec<_>, Error>>()
        .expect("iterating paths");
    assert_eq!(actual_paths, paths, "line {}", line!());
    assert_eq!(file_index.len(), paths.len(), "line {}", line!());
    assert_eq!(file_index.is_empty(), paths.is_empty(), "line {}", line!());
    for &(token, path) in tokens_and_paths {
        let token = FileToken(token);
        let msg = &format!("checking token={token:?}, path={path}");
        let get_path = file_index.get_path(token);
        assert_eq!(get_path, Ok(Some(path)), "line {}: {msg}", line!());
        let get_token = file_index.get_token(path);
        assert_eq!(get_token, Ok(Some(token)), "line {}: {msg}", line!());
    }
}

struct FakeTransaction;

impl Transaction for FakeTransaction {
    fn add(&mut self, _file: impl AsRef<Path>, _offset: usize) {
        // No need to do anything. We only add new files to the transaction
        // to ensure that rolling back will delete them.
    }
}

#[test]
fn test_empty() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    check_paths(&file_index, &[]);
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[]);
}

#[test]
fn test_single() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let foo = HgPath::new(b"foo");
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), true));
    check_paths(&file_index, &[(0, foo)]);
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, foo)]);
}

#[test]
fn test_multiple_write_together() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let a = HgPath::new(b"a");
    let bb = HgPath::new(b"bb");
    let ccc = HgPath::new(b"ccc");

    assert_eq!(file_index.add(a).unwrap(), (FileToken(0), true));
    check_paths(&file_index, &[(0, a)]);
    assert_eq!(file_index.add(bb).unwrap(), (FileToken(1), true));
    check_paths(&file_index, &[(0, a), (1, bb)]);
    assert_eq!(file_index.add(ccc).unwrap(), (FileToken(2), true));
    check_paths(&file_index, &[(0, a), (1, bb), (2, ccc)]);

    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, a), (1, bb), (2, ccc)]);
}

#[test]
fn test_multiple_write_separately() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let a = HgPath::new(b"a");
    let bb = HgPath::new(b"bb");
    let ccc = HgPath::new(b"ccc");

    assert_eq!(file_index.add(a).unwrap(), (FileToken(0), true));
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, a)]);
    assert_eq!(file_index.add(bb).unwrap(), (FileToken(1), true));
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, a), (1, bb)]);
    assert_eq!(file_index.add(ccc).unwrap(), (FileToken(2), true));
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, a), (1, bb), (2, ccc)]);
}

#[test]
fn test_maximum_path_length_in_memory() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    // This is the maximum length allowed by mercurial/cext/pathencode.c
    // and by rust/hg-core/src/revlog/path_encode.rs.
    const MAX_LENGTH: usize = 4096 * 4;
    let path: &Vec<_> = &(0..MAX_LENGTH).map(|i| (i % 256) as u8).collect();
    let path = HgPath::new(path);
    assert_eq!(file_index.add(path).unwrap(), (FileToken(0), true));

    check_paths(&file_index, &[(0, path)]);
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, path)]);
}

#[test]
fn test_add_existing_path() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let foo = HgPath::new(b"foo");
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), true));
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), false));
    file_index.write(&mut FakeTransaction).unwrap();
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), false));
}

#[test]
fn test_get_path_none() {
    let (file_index, _temp_dir) = create_file_index().unwrap();
    assert_eq!(file_index.get_path(FileToken(0)).unwrap(), None);
    assert_eq!(file_index.get_path(FileToken(u32::MAX)).unwrap(), None);
}

#[test]
fn test_get_token_none() {
    let (file_index, _temp_dir) = create_file_index().unwrap();
    assert_eq!(file_index.get_token(HgPath::new("")).unwrap(), None);
    assert_eq!(file_index.get_token(HgPath::new("fake")).unwrap(), None);
}

#[test]
fn test_remove_all() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let foo = HgPath::new(b"foo");
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), true));
    file_index.write(&mut FakeTransaction).unwrap();
    file_index.remove(foo).unwrap();
    check_paths(&file_index, &[]);
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[]);
}

#[test]
fn test_remove_some() {
    let (mut file_index, _temp_dir) = create_file_index().unwrap();
    let foo = HgPath::new(b"foo");
    let bar = HgPath::new(b"bar");
    assert_eq!(file_index.add(foo).unwrap(), (FileToken(0), true));
    assert_eq!(file_index.add(bar).unwrap(), (FileToken(1), true));
    file_index.write(&mut FakeTransaction).unwrap();
    file_index.remove(foo).unwrap();
    // TODO: this should pass
    // check_paths(&file_index, &[(1, bar)]);
    file_index.write(&mut FakeTransaction).unwrap();
    check_paths(&file_index, &[(0, bar)]);
}
