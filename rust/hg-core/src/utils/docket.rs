//! Utilities for docket files.
//!
//! A docket is a small metadata file that points to other files and records
//! information about their size and structure. For more information, see
//! mercurial/utils/docket.py.

use std::io::Write;

use bytes_cast::BytesCast;
use rand::RngExt;

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
