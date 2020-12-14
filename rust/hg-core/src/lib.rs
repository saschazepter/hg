// Copyright 2018-2020 Georges Racinet <georges.racinet@octobus.net>
//           and Mercurial contributors
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.
mod ancestors;
pub mod dagops;
pub use ancestors::{AncestorsIterator, LazyAncestors, MissingAncestors};
mod dirstate;
pub mod discovery;
pub mod requirements;
pub mod testing; // unconditionally built, for use from integration tests
pub use dirstate::{
    dirs_multiset::{DirsMultiset, DirsMultisetIter},
    dirstate_map::DirstateMap,
    parsers::{pack_dirstate, parse_dirstate, PARENT_SIZE},
    status::{
        status, BadMatch, BadType, DirstateStatus, StatusError, StatusOptions,
    },
    CopyMap, CopyMapIter, DirstateEntry, DirstateParents, EntryState,
    StateMap, StateMapIter,
};
pub mod copy_tracing;
mod filepatterns;
pub mod matchers;
pub mod repo;
pub mod revlog;
pub use revlog::*;
pub mod operations;
pub mod utils;

// Remove this to see (potential) non-artificial compile failures. MacOS
// *should* compile, but fail to compile tests for example as of 2020-03-06
#[cfg(not(target_os = "linux"))]
compile_error!(
    "`hg-core` has only been tested on Linux and will most \
     likely not behave correctly on other platforms."
);

use crate::utils::hg_path::{HgPathBuf, HgPathError};
pub use filepatterns::{
    parse_pattern_syntax, read_pattern_file, IgnorePattern,
    PatternFileWarning, PatternSyntax,
};
use std::collections::HashMap;
use twox_hash::RandomXxHashBuilder64;

/// This is a contract between the `micro-timer` crate and us, to expose
/// the `log` crate as `crate::log`.
use log;

pub type LineNumber = usize;

/// Rust's default hasher is too slow because it tries to prevent collision
/// attacks. We are not concerned about those: if an ill-minded person has
/// write access to your repository, you have other issues.
pub type FastHashMap<K, V> = HashMap<K, V, RandomXxHashBuilder64>;

#[derive(Clone, Debug, PartialEq)]
pub enum DirstateParseError {
    TooLittleData,
    Overflow,
    // TODO refactor to use bytes instead of String
    CorruptedEntry(String),
    Damaged,
}

impl From<std::io::Error> for DirstateParseError {
    fn from(e: std::io::Error) -> Self {
        DirstateParseError::CorruptedEntry(e.to_string())
    }
}

impl ToString for DirstateParseError {
    fn to_string(&self) -> String {
        use crate::DirstateParseError::*;
        match self {
            TooLittleData => "Too little data for dirstate.".to_string(),
            Overflow => "Overflow in dirstate.".to_string(),
            CorruptedEntry(e) => format!("Corrupted entry: {:?}.", e),
            Damaged => "Dirstate appears to be damaged.".to_string(),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum DirstatePackError {
    CorruptedEntry(String),
    CorruptedParent,
    BadSize(usize, usize),
}

impl From<std::io::Error> for DirstatePackError {
    fn from(e: std::io::Error) -> Self {
        DirstatePackError::CorruptedEntry(e.to_string())
    }
}
#[derive(Debug, PartialEq)]
pub enum DirstateMapError {
    PathNotFound(HgPathBuf),
    EmptyPath,
    InvalidPath(HgPathError),
}

impl ToString for DirstateMapError {
    fn to_string(&self) -> String {
        match self {
            DirstateMapError::PathNotFound(_) => {
                "expected a value, found none".to_string()
            }
            DirstateMapError::EmptyPath => "Overflow in dirstate.".to_string(),
            DirstateMapError::InvalidPath(e) => e.to_string(),
        }
    }
}

#[derive(Debug)]
pub enum DirstateError {
    Parse(DirstateParseError),
    Pack(DirstatePackError),
    Map(DirstateMapError),
    IO(std::io::Error),
}

impl From<DirstateParseError> for DirstateError {
    fn from(e: DirstateParseError) -> Self {
        DirstateError::Parse(e)
    }
}

impl From<DirstatePackError> for DirstateError {
    fn from(e: DirstatePackError) -> Self {
        DirstateError::Pack(e)
    }
}

#[derive(Debug)]
pub enum PatternError {
    Path(HgPathError),
    UnsupportedSyntax(String),
    UnsupportedSyntaxInFile(String, String, usize),
    TooLong(usize),
    IO(std::io::Error),
    /// Needed a pattern that can be turned into a regex but got one that
    /// can't. This should only happen through programmer error.
    NonRegexPattern(IgnorePattern),
}

impl ToString for PatternError {
    fn to_string(&self) -> String {
        match self {
            PatternError::UnsupportedSyntax(syntax) => {
                format!("Unsupported syntax {}", syntax)
            }
            PatternError::UnsupportedSyntaxInFile(syntax, file_path, line) => {
                format!(
                    "{}:{}: unsupported syntax {}",
                    file_path, line, syntax
                )
            }
            PatternError::TooLong(size) => {
                format!("matcher pattern is too long ({} bytes)", size)
            }
            PatternError::IO(e) => e.to_string(),
            PatternError::Path(e) => e.to_string(),
            PatternError::NonRegexPattern(pattern) => {
                format!("'{:?}' cannot be turned into a regex", pattern)
            }
        }
    }
}

impl From<DirstateMapError> for DirstateError {
    fn from(e: DirstateMapError) -> Self {
        DirstateError::Map(e)
    }
}

impl From<std::io::Error> for DirstateError {
    fn from(e: std::io::Error) -> Self {
        DirstateError::IO(e)
    }
}

impl From<std::io::Error> for PatternError {
    fn from(e: std::io::Error) -> Self {
        PatternError::IO(e)
    }
}

impl From<HgPathError> for PatternError {
    fn from(e: HgPathError) -> Self {
        PatternError::Path(e)
    }
}
