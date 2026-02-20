// dirstate module
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use bytes_cast::BytesCast;
use entry::DirstateEntry;

use crate::dirstate::on_disk::DirstateV2ParseError;
use crate::errors::HgBacktrace;
use crate::revlog::Node;
use crate::revlog::node::NULL_NODE;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathError;

pub mod dirs_multiset;
pub mod dirstate_map;
pub mod entry;
pub mod on_disk;
pub mod owning;
pub mod parsers;
pub mod path_with_basename;
pub mod status;

#[derive(Debug, PartialEq, Copy, Clone, BytesCast)]
#[repr(C)]
pub struct DirstateParents {
    pub p1: Node,
    pub p2: Node,
}

impl DirstateParents {
    pub const NULL: Self = Self { p1: NULL_NODE, p2: NULL_NODE };

    pub fn is_merge(&self) -> bool {
        !(self.p2 == NULL_NODE)
    }
}

pub type StateMapIter<'a> = Box<
    dyn Iterator<
            Item = Result<(&'a HgPath, DirstateEntry), DirstateV2ParseError>,
        > + Send
        + Sync
        + 'a,
>;

pub type CopyMapIter<'a> = Box<
    dyn Iterator<Item = Result<(&'a HgPath, &'a HgPath), DirstateV2ParseError>>
        + Send
        + Sync
        + 'a,
>;

/// An error that has occurred when parsing or using the dirstate
#[derive(Debug, derive_more::From, PartialEq)]
pub enum DirstateError {
    #[from]
    /// A parsing error specific to dirstate V2
    V2ParseError(DirstateV2ParseError),
    /// This path was not found inside the dirstate
    PathNotFound(HgPathBuf, HgBacktrace),
    /// A path from the dirstate or its inputs is invalid
    #[from]
    InvalidPath(HgPathError),
    /// Failed to parse dirstate-v1 due to too little data
    TooLittleData(usize, HgBacktrace),
    /// Failed to parse dirstate-v1 due to too little data for the given entry
    IncompleteEntry {
        /// 0-index of the entry, from the start of the file
        entry_idx: usize,
        /// Byte index from the start of the file
        at_byte: usize,
        backtrace: HgBacktrace,
    },
    /// Failed to parse dirstate-v1 due to too little data for the path of
    /// the given entry
    IncompletePath {
        /// 0-index of the entry, from the start of the file
        entry_idx: usize,
        /// Byte index from the start of the file
        at_byte: usize,
        /// Expected length of the entire file (for this path to be parsed)
        expected_len: usize,
        backtrace: HgBacktrace,
    },
    /// An invalid dirstate-v1 state was read
    BadEntryState(u8, HgBacktrace),
    /// The root node of the dirstate is not at the root path
    RootNotAtRoot(HgPathBuf, HgBacktrace),
    /// The path of a child node does not start with its parent's path
    BadChildPrefix {
        /// Path of the parent
        path: HgPathBuf,
        /// Full path of the child
        child_path: HgPathBuf,
        backtrace: HgBacktrace,
    },
}

impl DirstateError {
    /// Helper method to simplify the creation of this common variant
    pub fn path_not_found(path: &HgPath) -> Self {
        Self::PathNotFound(path.to_owned(), HgBacktrace::capture())
    }
}
