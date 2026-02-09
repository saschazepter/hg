use std::path::PathBuf;

use super::manifest::Manifest;
use super::options::RevlogOpenOptions;
use super::path_encode::PathEncoding;
use crate::dirstate::entry::has_exec_bit;
use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::inner_revlog::InnerRevlog;
use crate::revlog::manifest::ManifestFlags;
use crate::revlog::path_encode::path_encode;
use crate::revlog::NodePrefix;
use crate::revlog::Revision;
use crate::revlog::Revlog;
use crate::revlog::RevlogEntry;
use crate::revlog::RevlogError;
use crate::revlog::RevlogType;
use crate::revlog::REVISION_FLAG_HASMETA;
use crate::utils::files::get_bytes_from_os_string;
use crate::utils::files::get_path_from_bytes;
use crate::utils::hg_path::hg_path_to_path_buf;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::SliceExt;
use crate::utils::RawData;
use crate::vfs::VfsImpl;
use crate::Graph;
use crate::GraphError;
use crate::Node;
use crate::UncheckedRevision;

/// A specialized `Revlog` to work with file data logs.
pub struct Filelog {
    /// The generic `revlog` format.
    pub(crate) revlog: Revlog,
}

impl Graph for Filelog {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        self.revlog.parents(rev)
    }
}

impl Filelog {
    pub fn open_vfs(
        store_vfs: &crate::vfs::VfsImpl,
        file_path: &HgPath,
        options: RevlogOpenOptions,
    ) -> Result<Self, HgError> {
        let index_path = store_path(file_path, b".i", store_vfs.encoding);
        let data_path = store_path(file_path, b".d", store_vfs.encoding);
        let revlog = Revlog::open(
            store_vfs,
            index_path,
            Some(&data_path),
            options,
            RevlogType::Filelog,
        )?;
        Ok(Self { revlog })
    }

    pub fn open(
        repo: &Repo,
        file_path: &HgPath,
        options: RevlogOpenOptions,
    ) -> Result<Self, HgError> {
        Self::open_vfs(&repo.store_vfs(), file_path, options)
    }

    /// The given node ID is that of the file as found in a filelog, not of a
    /// changeset.
    pub fn data_for_node(
        &self,
        file_node: impl Into<NodePrefix>,
    ) -> Result<FilelogRevisionData, RevlogError> {
        let file_rev = self.revlog.rev_from_node(file_node.into())?;
        Ok(self.entry(file_rev)?.data()?)
    }

    /// The given revision is that of the file as found in a filelog, not of a
    /// changeset.
    pub fn data_for_unchecked_rev(
        &self,
        file_rev: UncheckedRevision,
    ) -> Result<FilelogRevisionData, RevlogError> {
        let data = self.revlog.get_data_for_unchecked_rev(file_rev);
        maybe_ignore_censored_revision(&self.revlog.inner, data)
    }

    /// The given node ID is that of the file as found in a filelog, not of a
    /// changeset.
    pub fn entry_for_node(
        &self,
        file_node: impl Into<NodePrefix>,
    ) -> Result<FilelogEntry<'_>, RevlogError> {
        let file_rev = self.revlog.rev_from_node(file_node.into())?;
        self.entry(file_rev)
    }

    /// The given revision is that of the file as found in a filelog, not of a
    /// changeset.
    pub fn entry_for_unchecked_rev(
        &self,
        file_rev: UncheckedRevision,
    ) -> Result<FilelogEntry<'_>, RevlogError> {
        Ok(FilelogEntry(self.revlog.get_entry_for_unchecked_rev(file_rev)?))
    }

    /// Same as [`Self::entry_for_unchecked_rev`] for a checked revision.
    pub fn entry(
        &self,
        file_rev: Revision,
    ) -> Result<FilelogEntry<'_>, RevlogError> {
        Ok(FilelogEntry(self.revlog.get_entry(file_rev)?))
    }
}

/// Given a [`Result`] of fetching filelog revision data, catch the eventual
/// censored node error and either forward it or ignore it according to config.
fn maybe_ignore_censored_revision(
    irl: &InnerRevlog,
    data_result: Result<RawData, RevlogError>,
) -> Result<FilelogRevisionData, RevlogError> {
    match data_result {
        Ok(data) => Ok(FilelogRevisionData(data)),
        // Errors other than `HgError` should not happen at this point
        Err(e) => match &e {
            RevlogError::Other(hg_error) => match hg_error {
                HgError::CensoredNodeError(_, _)
                    if irl.ignore_filelog_censored_revisions() =>
                {
                    Ok(FilelogRevisionData(RawData::empty()))
                }
                _ => Err(e),
            },
            _ => Err(e),
        },
    }
}

fn store_path(
    hg_path: &HgPath,
    suffix: &[u8],
    encoding: PathEncoding,
) -> PathBuf {
    let encoded_bytes =
        path_encode(&[b"data/", hg_path.as_bytes(), suffix].concat(), encoding);
    get_path_from_bytes(&encoded_bytes).into()
}

pub struct FilelogEntry<'a>(pub(crate) RevlogEntry<'a>);

impl FilelogEntry<'_> {
    /// `self.data()` can be expensive, with decompression and delta
    /// resolution.
    ///
    /// *Without* paying this cost, based on revlog index information
    /// including `RevlogEntry::uncompressed_len`:
    ///
    /// * Returns `true` if the length that `self.data().file_data().len()`
    ///   would return is definitely **not equal** to `other_len`.
    /// * Returns `false` if available information is inconclusive.
    pub fn file_data_len_not_equal_to(&self, other_len: u64) -> bool {
        // Relevant code that implement this behavior in Python code:
        // basefilectx.cmp, filelog.size, filelog.renamed,
        // revlog.size, revlog.rawsize

        // Let’s call `file_data_len` what would be returned by
        // `self.data().file_data().len()`.

        if self.0.is_censored() {
            let file_data_len = 0;
            return other_len != file_data_len;
        }

        if self.0.has_length_affecting_flag_processor() {
            // We can’t conclude anything about `file_data_len`.
            return false;
        }

        // Revlog revisions (usually) have metadata for the size of
        // their data after decompression and delta resolution
        // as would be returned by `Revlog::get_rev_data`.
        //
        // For filelogs this is the file’s contents preceded by an optional
        // metadata block.
        let uncompressed_len = if let Some(l) = self.0.uncompressed_len() {
            l as u64
        } else {
            // The field was set to -1, the actual uncompressed len is unknown.
            // We need to decompress to say more.
            return false;
        };
        // `uncompressed_len = file_data_len + optional_metadata_len`,
        // so `file_data_len <= uncompressed_len`.
        if uncompressed_len < other_len {
            // Transitively, `file_data_len < other_len`.
            // So `other_len != file_data_len` definitely.
            return true;
        }

        if uncompressed_len == other_len + 4 {
            // It’s possible that `file_data_len == other_len` with an empty
            // metadata block (2 start marker bytes + 2 end marker bytes).
            // This happens when there wouldn’t otherwise be metadata, but
            // the first 2 bytes of file data happen to match a start marker
            // and would be ambiguous.
            return false;
        }

        if self.0.revlog.index.uses_filelog_meta() {
            return (self.0.flags & REVISION_FLAG_HASMETA) != 0;
        } else if !self.0.has_p1() {
            // There may or may not be copy metadata, so we can’t deduce more
            // about `file_data_len` without computing file data.
            return false;
        }

        // Filelog ancestry is not meaningful in the way changelog ancestry is.
        // It only provides hints to delta generation.
        // p1 and p2 are set to null when making a copy or rename since
        // contents are likely unrelatedto what might have previously existed
        // at the destination path.
        //
        // Conversely, since here p1 is non-null, there is no copy metadata.
        // Note that this reasoning may be invalidated in the presence of
        // merges made by some previous versions of Mercurial that
        // swapped p1 and p2. See <https://bz.mercurial-scm.org/show_bug.cgi?id=6528>
        // and `tests/test-issue6528.t`.
        //
        // Since copy metadata is currently the only kind of metadata
        // kept in revlog data of filelogs,
        // this `FilelogEntry` does not have such metadata:
        let file_data_len = uncompressed_len;

        file_data_len != other_len
    }

    pub fn data(&self) -> Result<FilelogRevisionData, HgError> {
        let data = self.0.data();
        maybe_ignore_censored_revision(self.0.revlog, data).map_err(|e| match e
        {
            RevlogError::Other(hg_error) => hg_error,
            revlog_error => HgError::abort_simple(revlog_error.to_string()),
        })
    }
}

/// The data for one revision in a filelog, uncompressed and delta-resolved.
pub struct FilelogRevisionData(RawData);

impl FilelogRevisionData {
    /// Split into metadata and data
    pub fn split(
        &self,
    ) -> Result<(FilelogRevisionMetadata<'_>, &[u8]), HgError> {
        const DELIMITER: &[u8; 2] = b"\x01\n";

        if let Some(rest) = self.0.drop_prefix(DELIMITER) {
            if let Some((metadata, data)) = rest.split_2_by_slice(DELIMITER) {
                Ok((FilelogRevisionMetadata(Some(metadata)), data))
            } else {
                Err(HgError::corrupted(
                    "Missing metadata end delimiter in filelog entry",
                ))
            }
        } else {
            Ok((FilelogRevisionMetadata(None), &self.0))
        }
    }

    /// Returns the metadata header.
    pub fn metadata(&self) -> Result<FilelogRevisionMetadata<'_>, HgError> {
        let (metadata, _data) = self.split()?;
        Ok(metadata)
    }

    /// Returns the file contents at this revision, stripped of any metadata
    pub fn file_data(&self) -> Result<&[u8], HgError> {
        let (_metadata, data) = self.split()?;
        Ok(data)
    }

    /// Consume the entry, and convert it into data, discarding any metadata,
    /// if present.
    pub fn into_file_data(self) -> Result<RawData, HgError> {
        if let (FilelogRevisionMetadata(Some(_)), data) = self.split()? {
            Ok(RawData::from(data)) // XXX consider the Bytes crate
        } else {
            Ok(self.0)
        }
    }
}

/// The optional metadata header included in [`FilelogRevisionData`].
pub struct FilelogRevisionMetadata<'a>(Option<&'a [u8]>);

/// Fields parsed from [`FilelogRevisionMetadata`].
#[derive(Debug, PartialEq, Default)]
pub struct FilelogRevisionMetadataFields<'a> {
    /// True if the file revision data is censored.
    pub censored: bool,
    /// Path of the copy source.
    pub copy: Option<&'a HgPath>,
    /// Filelog node ID of the copy source.
    pub copyrev: Option<Node>,
}

impl<'a> FilelogRevisionMetadata<'a> {
    /// Parses the metadata fields.
    pub fn parse(self) -> Result<FilelogRevisionMetadataFields<'a>, HgError> {
        let mut fields = FilelogRevisionMetadataFields::default();
        if let Some(metadata) = self.0 {
            let mut rest = metadata;
            while !rest.is_empty() {
                let Some(colon_idx) = memchr::memchr(b':', rest) else {
                    return Err(HgError::corrupted(
                        "File metadata header line missing colon",
                    ));
                };
                if rest.get(colon_idx + 1) != Some(&b' ') {
                    return Err(HgError::corrupted(
                        "File metadata header line missing space",
                    ));
                }
                let key = &rest[..colon_idx];
                rest = &rest[colon_idx + 2..];
                let Some(newline_idx) = memchr::memchr(b'\n', rest) else {
                    return Err(HgError::corrupted(
                        "File metadata header line missing newline",
                    ));
                };
                let value = &rest[..newline_idx];
                match key {
                    b"censored" => {
                        match value {
                            b"" => fields.censored = true,
                            _ => return Err(HgError::corrupted(
                                "File metadata header 'censored' field has nonempty value",
                            )),
                        }
                    }
                    b"copy" => fields.copy = Some(HgPath::new(value)),
                    b"copyrev" => {
                        fields.copyrev = Some(Node::from_hex_for_repo(value)?)
                    }
                    _ => {
                        return Err(HgError::corrupted(
                            format!(
                                "File metadata header has unrecognized key '{}'",
                                String::from_utf8_lossy(key),
                            ),
                        ))
                    }
                }
                rest = &rest[newline_idx + 1..];
            }
        }
        Ok(fields)
    }
}

/// Outcome of checking if a file has changed since the last commit
#[derive(Debug, PartialEq, Eq)]
pub enum FileCompOutcome {
    /// The file is actually clean
    Clean,
    /// The file has been modified
    Modified,
    /// The file was deleted on disk (or became another type of fs entry)
    Deleted,
}

/// Check if a file is modified by comparing actual repo store and file system.
pub fn is_file_modified(
    working_directory_vfs: &VfsImpl,
    store_vfs: &VfsImpl,
    check_exec: bool,
    manifest: &Manifest,
    hg_path: &HgPath,
    revlog_open_options: RevlogOpenOptions,
) -> Result<FileCompOutcome, HgError> {
    let vfs = working_directory_vfs;
    let fs_path = hg_path_to_path_buf(hg_path).expect("HgPath conversion");
    let fs_metadata = if let Ok(it) = vfs.symlink_metadata(&fs_path) {
        it
    } else {
        return Ok(FileCompOutcome::Deleted);
    };
    let is_symlink = fs_metadata.file_type().is_symlink();

    let entry =
        manifest.find_by_path(hg_path)?.expect("ambgious file not in p1");

    // TODO: Also account for `FALLBACK_SYMLINK` and `FALLBACK_EXEC` from the
    // dirstate
    let fs_flags = if is_symlink {
        ManifestFlags::new_link()
    } else if check_exec && has_exec_bit(&fs_metadata) {
        ManifestFlags::new_exec()
    } else {
        ManifestFlags::new_empty()
    };

    let entry_flags = if check_exec {
        entry.flags
    } else if entry.flags.is_exec() {
        ManifestFlags::new_empty()
    } else {
        entry.flags
    };

    if entry_flags != fs_flags {
        return Ok(FileCompOutcome::Modified);
    }
    let filelog = Filelog::open_vfs(store_vfs, hg_path, revlog_open_options)?;
    let fs_len = fs_metadata.len();
    let file_node = entry.node_id()?;
    let filelog_entry = filelog.entry_for_node(file_node).map_err(|_| {
        HgError::corrupted(format!(
            "filelog {:?} missing node {:?} from manifest",
            hg_path, file_node
        ))
    })?;
    if filelog_entry.file_data_len_not_equal_to(fs_len) {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(FileCompOutcome::Modified);
    }

    let p1_filelog_data = filelog_entry.data()?;
    let p1_contents = p1_filelog_data.file_data()?;
    if p1_contents.len() as u64 != fs_len {
        // No need to read file contents:
        // it cannot be equal if it has a different length.
        return Ok(FileCompOutcome::Modified);
    }

    let fs_contents = if is_symlink {
        get_bytes_from_os_string(vfs.read_link(fs_path)?.into_os_string())
    } else {
        vfs.read(fs_path)?
    };

    Ok(if p1_contents != &*fs_contents {
        FileCompOutcome::Modified
    } else {
        FileCompOutcome::Clean
    })
}

#[cfg(test)]
mod tests {
    use format_bytes::format_bytes;

    use super::*;

    #[test]
    fn test_parse_no_metadata() {
        let data = FilelogRevisionData(RawData::from(b"data".to_vec()));
        let fields = data.metadata().unwrap().parse().unwrap();
        assert_eq!(fields, Default::default());
    }

    #[test]
    fn test_parse_empty_metadata() {
        let data =
            FilelogRevisionData(RawData::from(b"\x01\n\x01\ndata".to_vec()));
        let fields = data.metadata().unwrap().parse().unwrap();
        assert_eq!(fields, Default::default());
    }

    #[test]
    fn test_parse_one_field() {
        let data = FilelogRevisionData(RawData::from(
            b"\x01\ncopy: foo\n\x01\ndata".to_vec(),
        ));
        let fields = data.metadata().unwrap().parse().unwrap();
        assert_eq!(
            fields,
            FilelogRevisionMetadataFields {
                copy: Some(HgPath::new("foo")),
                ..Default::default()
            }
        );
    }

    #[test]
    fn test_parse_all_fields() {
        let sha = b"215d5d1546f82a79481eb2df513a7bc341bdf17f";
        let data = FilelogRevisionData(RawData::from(format_bytes!(
            b"\x01\ncensored: \ncopy: foo\ncopyrev: {}\n\x01\ndata",
            sha
        )));
        let fields = data.metadata().unwrap().parse().unwrap();
        assert_eq!(
            fields,
            FilelogRevisionMetadataFields {
                censored: true,
                copy: Some(HgPath::new("foo")),
                copyrev: Some(Node::from_hex(sha).unwrap()),
            }
        );
    }

    #[test]
    fn test_parse_invalid_metadata() {
        let data = FilelogRevisionData(RawData::from(
            b"\x01\nbad: value\n\x01\ndata".to_vec(),
        ));
        let err = data.metadata().unwrap().parse().unwrap_err();
        assert!(err.to_string().contains("unrecognized key 'bad'"));
    }
}
