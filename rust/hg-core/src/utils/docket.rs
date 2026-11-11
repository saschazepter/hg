//! Utilities for docket files.
//!
//! A docket is a small metadata file that points to other files and records
//! information about their size and structure. For more information, see
//! mercurial/utils/docket.py.

use std::io::Write;
use std::path::PathBuf;

use bytes_cast::BytesCast;
use rand::RngExt;

use crate::errors::HgBacktrace;

/// A unique identifier made of hex digits used as part of a filename.
#[derive(Debug, Copy, Clone, PartialEq, Eq, BytesCast)]
#[repr(transparent)]
pub struct FileUid([u8; UID_SIZE]);

/// Underlying integer type for a [`FileUid`].
type FileUidInt = u32;

/// Number of characters in a [`FileUid`].
pub const UID_SIZE: usize = std::mem::size_of::<FileUidInt>() * 2;

impl FileUid {
    /// Returns a sentinel value representing an unset uid.
    pub const fn unset() -> Self {
        Self([b'0'; UID_SIZE])
    }

    /// Returns true if the uid is unset.
    pub fn is_unset(&self) -> bool {
        *self == Self::unset()
    }

    /// Returns `None` if the uid is unset.
    pub fn none_if_unset(&self) -> Option<Self> {
        if *self == Self::unset() {
            None
        } else {
            Some(*self)
        }
    }

    /// Generates a random uid. It will never equal [`Self::unset()`].
    pub fn random() -> Self {
        // TODO: support the `HGTEST_UUIDFILE` environment variable.
        let mut id = [0; UID_SIZE];
        let random: FileUidInt = rand::rng().random_range(1..=FileUidInt::MAX);
        write!(&mut id[..], "{:0width$x}", random, width = UID_SIZE)
            .expect("write cannot fail since size matches");
        Self(id)
    }

    /// Returns this uid as bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// Returns this uid as a string.
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.0).expect("hex digits are ASCII")
    }
}

/// An error about a docket or the data files it points to
#[derive(Debug, PartialEq)]
pub struct DocketError {
    /// The path of the docket, relative to the vfs it is read from
    pub docket_path: PathBuf,
    pub kind: DocketErrorKind,
    pub backtrace: HgBacktrace,
}

impl DocketError {
    pub fn new(docket_path: impl Into<PathBuf>, kind: DocketErrorKind) -> Self {
        Self {
            docket_path: docket_path.into(),
            kind,
            backtrace: HgBacktrace::capture(),
        }
    }
}

/// The different kinds of [`DocketError`]
#[derive(Debug, PartialEq)]
pub enum DocketErrorKind {
    /// The docket cannot be parsed
    Corrupted,
    /// The docket does not start with the marker of its format
    BadFormatMarker,
    /// A data file is smaller than the size the docket records for it
    DataFileTooSmall { data_path: PathBuf },
    /// The data file disappeared between reading the docket and reading the
    /// data file itself. This *must* be handled locally and not directly
    /// surface to the user.
    ReadRace,
    /// We've hit [`Self::ReadRace`] too many times in a row
    ReadRaceExhausted { tries: usize },
    /// The ID of the data file in the docket is not valid UTF-8
    NonUtf8DataFileId,
    /// The data file is too large to be represented in the docket
    Overflow,
}
