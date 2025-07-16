// Copyright 2018-2020 Georges Racinet <georges.racinet@octobus.net>
//           and Mercurial contributors
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

mod ancestors;
mod bdiff;
pub mod dagops;
pub mod encoding;
pub mod errors;
pub mod narrow;
pub mod sparse;
pub use ancestors::AncestorsIterator;
pub use ancestors::MissingAncestors;
pub mod dirstate;
pub mod discovery;
pub mod exit_codes;
pub mod fncache;
pub mod requirements;
pub mod testing; // unconditionally built, for use from integration tests

// Export very common type to make discovery easier
pub use dirstate::DirstateParents;
pub mod copy_tracing;
pub mod filepatterns;
pub mod matchers;
pub mod repo;
pub mod revlog;
// Export very common types to make discovery easier
pub use revlog::BaseRevision;
pub use revlog::Graph;
pub use revlog::GraphError;
pub use revlog::Node;
pub use revlog::NodePrefix;
pub use revlog::Revision;
pub use revlog::UncheckedRevision;
pub use revlog::NULL_NODE;
pub use revlog::NULL_NODE_ID;
pub use revlog::NULL_REVISION;
pub use revlog::WORKING_DIRECTORY_HEX;
pub use revlog::WORKING_DIRECTORY_REVISION;
pub mod checkexec;
pub mod config;
pub mod dyn_bytes;
pub mod lock;
pub mod logging;
pub mod operations;
mod pre_regex;
pub mod progress;
pub mod revset;
pub mod transaction;
pub mod update;
pub mod utils;
pub mod vfs;
pub mod warnings;
use std::collections::HashMap;
use std::sync::atomic::AtomicBool;

use twox_hash::xxhash64::RandomState;

/// Used to communicate with threads spawned from code within this crate that
/// they should stop their work (SIGINT was received).
pub static INTERRUPT_RECEIVED: AtomicBool = AtomicBool::new(false);

pub type LineNumber = usize;

/// Rust's default hasher is too slow because it tries to prevent collision
/// attacks. We are not concerned about those: if an ill-minded person has
/// write access to your repository, you have other issues.
pub type FastHashMap<K, V> = HashMap<K, V, RandomState>;

// TODO: should this be the default `FastHashMap` for all of hg-core, not just
// dirstate? How does XxHash compare with AHash, hashbrown’s default?
pub type FastHashbrownMap<K, V> = hashbrown::HashMap<K, V, RandomState>;
