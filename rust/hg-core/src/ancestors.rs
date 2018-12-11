// ancestors.rs
//
// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Rust versions of generic DAG ancestors algorithms for Mercurial

use super::{Graph, GraphError, Revision, NULL_REVISION};
use std::collections::{BinaryHeap, HashSet};

/// Iterator over the ancestors of a given list of revisions
/// This is a generic type, defined and implemented for any Graph, so that
/// it's easy to
///
/// - unit test in pure Rust
/// - bind to main Mercurial code, potentially in several ways and have these
///   bindings evolve over time
pub struct AncestorsIterator<G: Graph> {
    graph: G,
    visit: BinaryHeap<Revision>,
    seen: HashSet<Revision>,
    stoprev: Revision,
}

impl<G: Graph> AncestorsIterator<G> {
    /// Constructor.
    ///
    /// if `inclusive` is true, then the init revisions are emitted in
    /// particular, otherwise iteration starts from their parents.
    pub fn new<I>(
        graph: G,
        initrevs: I,
        stoprev: Revision,
        inclusive: bool,
    ) -> Result<Self, GraphError>
    where
        I: IntoIterator<Item = Revision>,
    {
        let filtered_initrevs = initrevs.into_iter().filter(|&r| r >= stoprev);
        if inclusive {
            let visit: BinaryHeap<Revision> = filtered_initrevs.collect();
            let seen = visit.iter().map(|&x| x).collect();
            return Ok(AncestorsIterator {
                visit: visit,
                seen: seen,
                stoprev: stoprev,
                graph: graph,
            });
        }
        let mut this = AncestorsIterator {
            visit: BinaryHeap::new(),
            seen: HashSet::new(),
            stoprev: stoprev,
            graph: graph,
        };
        this.seen.insert(NULL_REVISION);
        for rev in filtered_initrevs {
            let parents = this.graph.parents(rev)?;
            this.conditionally_push_rev(parents.0);
            this.conditionally_push_rev(parents.1);
        }
        Ok(this)
    }

    #[inline]
    fn conditionally_push_rev(&mut self, rev: Revision) {
        if self.stoprev <= rev && !self.seen.contains(&rev) {
            self.seen.insert(rev);
            self.visit.push(rev);
        }
    }

    /// Consumes partially the iterator to tell if the given target
    /// revision
    /// is in the ancestors it emits.
    /// This is meant for iterators actually dedicated to that kind of
    /// purpose
    pub fn contains(&mut self, target: Revision) -> Result<bool, GraphError> {
        if self.seen.contains(&target) && target != NULL_REVISION {
            return Ok(true);
        }
        for item in self {
            let rev = item?;
            if rev == target {
                return Ok(true);
            }
            if rev < target {
                return Ok(false);
            }
        }
        Ok(false)
    }
}

/// Main implementation.
///
/// The algorithm is the same as in `_lazyancestorsiter()` from `ancestors.py`
/// with a few non crucial differences:
///
/// - there's no filtering of invalid parent revisions. Actually, it should be
///   consistent and more efficient to filter them from the end caller.
/// - we don't have the optimization for adjacent revisions (i.e., the case
///   where `p1 == rev - 1`), because it amounts to update the first element of
///   the heap without sifting, which Rust's BinaryHeap doesn't let us do.
/// - we save a few pushes by comparing with `stoprev` before pushing
impl<G: Graph> Iterator for AncestorsIterator<G> {
    type Item = Result<Revision, GraphError>;

    fn next(&mut self) -> Option<Self::Item> {
        let current = match self.visit.peek() {
            None => {
                return None;
            }
            Some(c) => *c,
        };
        let (p1, p2) = match self.graph.parents(current) {
            Ok(ps) => ps,
            Err(e) => return Some(Err(e)),
        };
        if p1 < self.stoprev || self.seen.contains(&p1) {
            self.visit.pop();
        } else {
            *(self.visit.peek_mut().unwrap()) = p1;
            self.seen.insert(p1);
        };

        self.conditionally_push_rev(p2);
        Some(Ok(current))
    }
}

#[cfg(test)]
mod tests {

    use super::*;

    #[derive(Clone, Debug)]
    struct Stub;

    /// This is the same as the dict from test-ancestors.py
    impl Graph for Stub {
        fn parents(
            &self,
            rev: Revision,
        ) -> Result<(Revision, Revision), GraphError> {
            match rev {
                0 => Ok((-1, -1)),
                1 => Ok((0, -1)),
                2 => Ok((1, -1)),
                3 => Ok((1, -1)),
                4 => Ok((2, -1)),
                5 => Ok((4, -1)),
                6 => Ok((4, -1)),
                7 => Ok((4, -1)),
                8 => Ok((-1, -1)),
                9 => Ok((6, 7)),
                10 => Ok((5, -1)),
                11 => Ok((3, 7)),
                12 => Ok((9, -1)),
                13 => Ok((8, -1)),
                r => Err(GraphError::ParentOutOfRange(r)),
            }
        }
    }

    fn list_ancestors<G: Graph>(
        graph: G,
        initrevs: Vec<Revision>,
        stoprev: Revision,
        inclusive: bool,
    ) -> Vec<Revision> {
        AncestorsIterator::new(graph, initrevs, stoprev, inclusive)
            .unwrap()
            .map(|res| res.unwrap())
            .collect()
    }

    #[test]
    /// Same tests as test-ancestor.py, without membership
    /// (see also test-ancestor.py.out)
    fn test_list_ancestor() {
        assert_eq!(list_ancestors(Stub, vec![], 0, false), vec![]);
        assert_eq!(
            list_ancestors(Stub, vec![11, 13], 0, false),
            vec![8, 7, 4, 3, 2, 1, 0]
        );
        assert_eq!(list_ancestors(Stub, vec![1, 3], 0, false), vec![1, 0]);
        assert_eq!(
            list_ancestors(Stub, vec![11, 13], 0, true),
            vec![13, 11, 8, 7, 4, 3, 2, 1, 0]
        );
        assert_eq!(list_ancestors(Stub, vec![11, 13], 6, false), vec![8, 7]);
        assert_eq!(
            list_ancestors(Stub, vec![11, 13], 6, true),
            vec![13, 11, 8, 7]
        );
        assert_eq!(list_ancestors(Stub, vec![11, 13], 11, true), vec![13, 11]);
        assert_eq!(list_ancestors(Stub, vec![11, 13], 12, true), vec![13]);
        assert_eq!(
            list_ancestors(Stub, vec![10, 1], 0, true),
            vec![10, 5, 4, 2, 1, 0]
        );
    }

    #[test]
    /// Corner case that's not directly in test-ancestors.py, but
    /// that happens quite often, as demonstrated by running the whole
    /// suite.
    /// For instance, run tests/test-obsolete-checkheads.t
    fn test_nullrev_input() {
        let mut iter =
            AncestorsIterator::new(Stub, vec![-1], 0, false).unwrap();
        assert_eq!(iter.next(), None)
    }

    #[test]
    fn test_contains() {
        let mut lazy =
            AncestorsIterator::new(Stub, vec![10, 1], 0, true).unwrap();
        assert!(lazy.contains(1).unwrap());
        assert!(!lazy.contains(3).unwrap());

        let mut lazy =
            AncestorsIterator::new(Stub, vec![0], 0, false).unwrap();
        assert!(!lazy.contains(NULL_REVISION).unwrap());
    }

    /// A corrupted Graph, supporting error handling tests
    struct Corrupted;

    impl Graph for Corrupted {
        fn parents(
            &self,
            rev: Revision,
        ) -> Result<(Revision, Revision), GraphError> {
            match rev {
                1 => Ok((0, -1)),
                r => Err(GraphError::ParentOutOfRange(r)),
            }
        }
    }

    #[test]
    fn test_initrev_out_of_range() {
        // inclusive=false looks up initrev's parents right away
        match AncestorsIterator::new(Stub, vec![25], 0, false) {
            Ok(_) => panic!("Should have been ParentOutOfRange"),
            Err(e) => assert_eq!(e, GraphError::ParentOutOfRange(25)),
        }
    }

    #[test]
    fn test_next_out_of_range() {
        // inclusive=false looks up initrev's parents right away
        let mut iter =
            AncestorsIterator::new(Corrupted, vec![1], 0, false).unwrap();
        assert_eq!(iter.next(), Some(Err(GraphError::ParentOutOfRange(0))));
    }
}
