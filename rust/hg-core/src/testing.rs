// testing.rs
//
// Copyright 2018 Georges Racinet <georges.racinet@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::{Graph, GraphError, Revision, NULL_REVISION};

/// A stub `Graph`, same as the one from `test-ancestor.py`
///
/// o  13
/// |
/// | o  12
/// | |
/// | | o    11
/// | | |\
/// | | | | o  10
/// | | | | |
/// | o---+ |  9
/// | | | | |
/// o | | | |  8
///  / / / /
/// | | o |  7
/// | | | |
/// o---+ |  6
///  / / /
/// | | o  5
/// | |/
/// | o  4
/// | |
/// o |  3
/// | |
/// | o  2
/// |/
/// o  1
/// |
/// o  0
#[derive(Clone, Debug)]
pub struct SampleGraph;

impl Graph for SampleGraph {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        let null_rev = NULL_REVISION.0;
        let res = match rev.0 {
            0 => Ok([null_rev, null_rev]),
            1 => Ok([0, null_rev]),
            2 => Ok([1, null_rev]),
            3 => Ok([1, null_rev]),
            4 => Ok([2, null_rev]),
            5 => Ok([4, null_rev]),
            6 => Ok([4, null_rev]),
            7 => Ok([4, null_rev]),
            8 => Ok([null_rev, null_rev]),
            9 => Ok([6, 7]),
            10 => Ok([5, null_rev]),
            11 => Ok([3, 7]),
            12 => Ok([9, null_rev]),
            13 => Ok([8, null_rev]),
            r => Err(GraphError::ParentOutOfRange(Revision(r))),
        };
        match res {
            Ok([a, b]) => Ok([Revision(a), Revision(b)]),
            Err(e) => Err(e),
        }
    }
}

// A Graph represented by a vector whose indices are revisions
// and values are parents of the revisions
pub type VecGraph = Vec<[Revision; 2]>;

impl Graph for VecGraph {
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        Ok(self[rev.0 as usize])
    }
}
