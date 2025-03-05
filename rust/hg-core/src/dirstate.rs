// dirstate module
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::fmt;

use crate::dirstate::on_disk::DirstateV2ParseError;
use crate::errors;
use crate::revlog::node::NULL_NODE;
use crate::revlog::Node;
use crate::utils::hg_path::{HgPath, HgPathBuf, HgPathError};
use bytes_cast::BytesCast;
use entry::DirstateEntry;

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
    pub const NULL: Self = Self {
        p1: NULL_NODE,
        p2: NULL_NODE,
    };

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

#[derive(Debug, PartialEq)]
pub enum DirstateMapError {
    PathNotFound(HgPathBuf),
    InvalidPath(HgPathError),
}

impl From<HgPathError> for DirstateMapError {
    fn from(error: HgPathError) -> Self {
        Self::InvalidPath(error)
    }
}

impl fmt::Display for DirstateMapError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            DirstateMapError::PathNotFound(_) => {
                f.write_str("expected a value, found none")
            }
            DirstateMapError::InvalidPath(path_error) => path_error.fmt(f),
        }
    }
}

#[derive(Debug, derive_more::From)]
pub enum DirstateError {
    Map(DirstateMapError),
    Common(errors::HgError),
}

impl From<HgPathError> for DirstateError {
    fn from(error: HgPathError) -> Self {
        Self::Map(DirstateMapError::InvalidPath(error))
    }
}

impl fmt::Display for DirstateError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            DirstateError::Map(error) => error.fmt(f),
            DirstateError::Common(error) => error.fmt(f),
        }
    }
}
