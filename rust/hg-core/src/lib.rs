// Copyright 2018-2020 Georges Racinet <georges.racinet@octobus.net>
//           and Mercurial contributors
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

mod ancestors;
pub mod dagops;
pub mod errors;
pub mod narrow;
pub mod sparse;
pub use ancestors::{AncestorsIterator, MissingAncestors};
pub mod dirstate;
pub mod discovery;
pub mod exit_codes;
pub mod fncache;
pub mod requirements;
pub mod testing; // unconditionally built, for use from integration tests
pub use dirstate::{
    dirs_multiset::{DirsMultiset, DirsMultisetIter},
    status::{
        BadMatch, BadType, DirstateStatus, HgPathCow, StatusError,
        StatusOptions,
    },
    DirstateParents,
};
pub mod copy_tracing;
pub mod filepatterns;
pub mod matchers;
pub mod repo;
pub mod revlog;
// Export very common types to make discovery easier
pub use revlog::{
    BaseRevision, Graph, GraphError, Node, NodePrefix, Revision,
    UncheckedRevision, NULL_NODE, NULL_NODE_ID, NULL_REVISION,
    WORKING_DIRECTORY_HEX, WORKING_DIRECTORY_REVISION,
};
pub mod checkexec;
pub mod config;
pub mod lock;
pub mod logging;
pub mod operations;
pub mod progress;
pub mod revset;
pub mod transaction;
pub mod update;
pub mod utils;
pub mod vfs;

use crate::utils::hg_path::{HgPathBuf, HgPathError};
pub use filepatterns::{
    parse_pattern_syntax_kind, read_pattern_file, IgnorePattern,
    PatternFileWarning, PatternSyntax,
};
use std::fmt;
use std::{collections::HashMap, sync::atomic::AtomicBool};
use twox_hash::RandomXxHashBuilder64;

/// Used to communicate with threads spawned from code within this crate that
/// they should stop their work (SIGINT was received).
pub static INTERRUPT_RECEIVED: AtomicBool = AtomicBool::new(false);

pub type LineNumber = usize;

/// Rust's default hasher is too slow because it tries to prevent collision
/// attacks. We are not concerned about those: if an ill-minded person has
/// write access to your repository, you have other issues.
pub type FastHashMap<K, V> = HashMap<K, V, RandomXxHashBuilder64>;

// TODO: should this be the default `FastHashMap` for all of hg-core, not just
// dirstate? How does XxHash compare with AHash, hashbrown’s default?
pub type FastHashbrownMap<K, V> =
    hashbrown::HashMap<K, V, RandomXxHashBuilder64>;

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

#[derive(Debug, derive_more::From)]
pub enum PatternError {
    #[from]
    Path(HgPathError),
    UnsupportedSyntax(String),
    UnsupportedSyntaxInFile(String, String, usize),
    TooLong(usize),
    #[from]
    IO(std::io::Error),
    /// Needed a pattern that can be turned into a regex but got one that
    /// can't. This should only happen through programmer error.
    NonRegexPattern(IgnorePattern),
}

impl fmt::Display for PatternError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            PatternError::UnsupportedSyntax(syntax) => {
                write!(f, "Unsupported syntax {}", syntax)
            }
            PatternError::UnsupportedSyntaxInFile(syntax, file_path, line) => {
                write!(
                    f,
                    "{}:{}: unsupported syntax {}",
                    file_path, line, syntax
                )
            }
            PatternError::TooLong(size) => {
                write!(f, "matcher pattern is too long ({} bytes)", size)
            }
            PatternError::IO(error) => error.fmt(f),
            PatternError::Path(error) => error.fmt(f),
            PatternError::NonRegexPattern(pattern) => {
                write!(f, "'{:?}' cannot be turned into a regex", pattern)
            }
        }
    }
}
