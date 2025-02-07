// ancestors.rs
//
// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Rust versions of generic DAG ancestors algorithms for Mercurial

use super::{Graph, GraphError, Revision, NULL_REVISION};
use crate::dagops;
use bit_set::BitSet;
use std::cmp::max;
use std::collections::{BinaryHeap, HashSet};

/// A set of revisions backed by a bitset, optimized for descending insertion.
struct DescendingRevisionSet {
    /// The underlying bitset storage.
    set: BitSet,
    /// For a revision `R` we store `ceiling - R` instead of `R` so that
    /// memory usage is proportional to how far we've descended.
    ceiling: i32,
    /// Track length separately because [`BitSet::len`] recounts every time.
    len: usize,
}

impl DescendingRevisionSet {
    /// Creates a new empty set that can store revisions up to `ceiling`.
    fn new(ceiling: Revision) -> Self {
        Self {
            set: BitSet::new(),
            ceiling: ceiling.0,
            len: 0,
        }
    }

    /// Returns the number of revisions in the set.
    fn len(&self) -> usize {
        self.len
    }

    /// Returns true if the set contains `value`.
    fn contains(&self, value: Revision) -> bool {
        match self.encode(value) {
            Ok(n) => self.set.contains(n),
            Err(_) => false,
        }
    }

    /// Adds `value` to the set. Returns true if it was not already in the set.
    /// Returns `Err` if it cannot store it because it is above the ceiling.
    fn insert(&mut self, value: Revision) -> Result<bool, GraphError> {
        let inserted = self.set.insert(self.encode(value)?);
        self.len += inserted as usize;
        Ok(inserted)
    }

    fn encode(&self, value: Revision) -> Result<usize, GraphError> {
        usize::try_from(self.ceiling - value.0)
            .map_err(|_| GraphError::ParentOutOfOrder(value))
    }
}

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
    seen: DescendingRevisionSet,
    stoprev: Revision,
}

pub struct MissingAncestors<G: Graph> {
    graph: G,
    bases: HashSet<Revision>,
    max_base: Revision,
}

impl<G: Graph> AncestorsIterator<G> {
    /// Constructor.
    ///
    /// if `inclusive` is true, then the init revisions are emitted in
    /// particular, otherwise iteration starts from their parents.
    pub fn new(
        graph: G,
        initrevs: impl IntoIterator<Item = Revision>,
        stoprev: Revision,
        inclusive: bool,
    ) -> Result<Self, GraphError> {
        let filtered_initrevs = initrevs
            .into_iter()
            .filter(|&r| r >= stoprev)
            .collect::<BinaryHeap<_>>();
        let max = *filtered_initrevs.peek().unwrap_or(&NULL_REVISION);
        let mut seen = DescendingRevisionSet::new(max);
        if inclusive {
            for &rev in &filtered_initrevs {
                seen.insert(rev).expect("revs cannot be above their max");
            }
            return Ok(AncestorsIterator {
                visit: filtered_initrevs,
                seen,
                stoprev,
                graph,
            });
        }
        let mut this = AncestorsIterator {
            visit: BinaryHeap::new(),
            seen,
            stoprev,
            graph,
        };
        this.seen
            .insert(NULL_REVISION)
            .expect("null is the smallest revision");
        for rev in filtered_initrevs {
            for parent in this.graph.parents(rev)?.iter().cloned() {
                this.conditionally_push_rev(parent)?;
            }
        }
        Ok(this)
    }

    #[inline]
    fn conditionally_push_rev(
        &mut self,
        rev: Revision,
    ) -> Result<(), GraphError> {
        if self.stoprev <= rev && self.seen.insert(rev)? {
            self.visit.push(rev);
        }
        Ok(())
    }

    /// Consumes partially the iterator to tell if the given target
    /// revision
    /// is in the ancestors it emits.
    /// This is meant for iterators actually dedicated to that kind of
    /// purpose
    pub fn contains(&mut self, target: Revision) -> Result<bool, GraphError> {
        if self.seen.contains(target) && target != NULL_REVISION {
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

    pub fn peek(&self) -> Option<Revision> {
        self.visit.peek().cloned()
    }

    /// Tell if the iterator is about an empty set
    ///
    /// The result does not depend whether the iterator has been consumed
    /// or not.
    /// This is mostly meant for iterators backing a lazy ancestors set
    pub fn is_empty(&self) -> bool {
        if self.visit.len() > 0 {
            return false;
        }
        let seen_len = self.seen.len();
        if seen_len > 1 {
            return false;
        }
        // at this point, the seen set is at most a singleton.
        // If not `self.inclusive`, it's still possible that it has only
        // the null revision
        seen_len == 0 || self.seen.contains(NULL_REVISION)
    }
}

/// Main implementation for the iterator
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
        let [p1, p2] = match self.graph.parents(current) {
            Ok(ps) => ps,
            Err(e) => return Some(Err(e)),
        };
        let pop = if p1 < self.stoprev {
            true
        } else {
            match self.seen.insert(p1) {
                Ok(inserted) => !inserted,
                Err(e) => return Some(Err(e)),
            }
        };
        if pop {
            self.visit.pop();
        } else {
            *(self.visit.peek_mut().unwrap()) = p1;
        };

        if let Err(e) = self.conditionally_push_rev(p2) {
            return Some(Err(e));
        }
        Some(Ok(current))
    }
}

impl<G: Graph> MissingAncestors<G> {
    pub fn new(graph: G, bases: impl IntoIterator<Item = Revision>) -> Self {
        let mut created = MissingAncestors {
            graph,
            bases: HashSet::new(),
            max_base: NULL_REVISION,
        };
        created.add_bases(bases);
        created
    }

    pub fn has_bases(&self) -> bool {
        !self.bases.is_empty()
    }

    /// Return a reference to current bases.
    ///
    /// This is useful in unit tests, but also setdiscovery.py does
    /// read the bases attribute of a ancestor.missingancestors instance.
    pub fn get_bases(&self) -> &HashSet<Revision> {
        &self.bases
    }

    /// Computes the relative heads of current bases.
    ///
    /// The object is still usable after this.
    pub fn bases_heads(&self) -> Result<HashSet<Revision>, GraphError> {
        dagops::heads(&self.graph, self.bases.iter())
    }

    /// Consumes the object and returns the relative heads of its bases.
    pub fn into_bases_heads(
        mut self,
    ) -> Result<HashSet<Revision>, GraphError> {
        dagops::retain_heads(&self.graph, &mut self.bases)?;
        Ok(self.bases)
    }

    /// Add some revisions to `self.bases`
    ///
    /// Takes care of keeping `self.max_base` up to date.
    pub fn add_bases(
        &mut self,
        new_bases: impl IntoIterator<Item = Revision>,
    ) {
        let mut max_base = self.max_base;
        self.bases.extend(
            new_bases
                .into_iter()
                .filter(|&rev| rev != NULL_REVISION)
                .inspect(|&r| {
                    if r > max_base {
                        max_base = r;
                    }
                }),
        );
        self.max_base = max_base;
    }

    /// Remove all ancestors of self.bases from the revs set (in place)
    pub fn remove_ancestors_from(
        &mut self,
        revs: &mut HashSet<Revision>,
    ) -> Result<(), GraphError> {
        revs.retain(|r| !self.bases.contains(r));
        // the null revision is always an ancestor. Logically speaking
        // it's debatable in case bases is empty, but the Python
        // implementation always adds NULL_REVISION to bases, making it
        // unconditionnally true.
        revs.remove(&NULL_REVISION);
        if revs.is_empty() {
            return Ok(());
        }
        // anything in revs > start is definitely not an ancestor of bases
        // revs <= start need to be investigated
        if self.max_base == NULL_REVISION {
            return Ok(());
        }

        // whatever happens, we'll keep at least keepcount of them
        // knowing this gives us a earlier stop condition than
        // going all the way to the root
        let keepcount = revs.iter().filter(|r| **r > self.max_base).count();

        let mut curr = self.max_base;
        while curr != NULL_REVISION && revs.len() > keepcount {
            if self.bases.contains(&curr) {
                revs.remove(&curr);
                self.add_parents(curr)?;
            }
            // We know this revision is safe because we've checked the bounds
            // before.
            curr = Revision(curr.0 - 1);
        }
        Ok(())
    }

    /// Add the parents of `rev` to `self.bases`
    ///
    /// This has no effect on `self.max_base`
    #[inline]
    fn add_parents(&mut self, rev: Revision) -> Result<(), GraphError> {
        if rev == NULL_REVISION {
            return Ok(());
        }
        for p in self.graph.parents(rev)?.iter().cloned() {
            // No need to bother the set with inserting NULL_REVISION over and
            // over
            if p != NULL_REVISION {
                self.bases.insert(p);
            }
        }
        Ok(())
    }

    /// Return all the ancestors of revs that are not ancestors of self.bases
    ///
    /// This may include elements from revs.
    ///
    /// Equivalent to the revset (::revs - ::self.bases). Revs are returned in
    /// revision number order, which is a topological order.
    pub fn missing_ancestors(
        &mut self,
        revs: impl IntoIterator<Item = Revision>,
    ) -> Result<Vec<Revision>, GraphError> {
        // just for convenience and comparison with Python version
        let bases_visit = &mut self.bases;
        let mut revs: HashSet<Revision> = revs
            .into_iter()
            .filter(|r| !bases_visit.contains(r))
            .collect();
        let revs_visit = &mut revs;
        let mut both_visit: HashSet<Revision> =
            revs_visit.intersection(bases_visit).cloned().collect();
        if revs_visit.is_empty() {
            return Ok(Vec::new());
        }
        let max_revs = revs_visit.iter().cloned().max().unwrap();
        let start = max(self.max_base, max_revs);

        // TODO heuristics for with_capacity()?
        let mut missing: Vec<Revision> = Vec::new();
        for curr in (0..=start.0).rev() {
            if revs_visit.is_empty() {
                break;
            }
            if both_visit.remove(&Revision(curr)) {
                // curr's parents might have made it into revs_visit through
                // another path
                for p in self.graph.parents(Revision(curr))?.iter().cloned() {
                    if p == NULL_REVISION {
                        continue;
                    }
                    revs_visit.remove(&p);
                    bases_visit.insert(p);
                    both_visit.insert(p);
                }
            } else if revs_visit.remove(&Revision(curr)) {
                missing.push(Revision(curr));
                for p in self.graph.parents(Revision(curr))?.iter().cloned() {
                    if p == NULL_REVISION {
                        continue;
                    }
                    if bases_visit.contains(&p) {
                        // p is already known to be an ancestor of revs_visit
                        revs_visit.remove(&p);
                        both_visit.insert(p);
                    } else if both_visit.contains(&p) {
                        // p should have been in bases_visit
                        revs_visit.remove(&p);
                        bases_visit.insert(p);
                    } else {
                        // visit later
                        revs_visit.insert(p);
                    }
                }
            } else if bases_visit.contains(&Revision(curr)) {
                for p in self.graph.parents(Revision(curr))?.iter().cloned() {
                    if p == NULL_REVISION {
                        continue;
                    }
                    if revs_visit.remove(&p) || both_visit.contains(&p) {
                        // p is an ancestor of bases_visit, and is implicitly
                        // in revs_visit, which means p is ::revs & ::bases.
                        bases_visit.insert(p);
                        both_visit.insert(p);
                    } else {
                        bases_visit.insert(p);
                    }
                }
            }
        }
        missing.reverse();
        Ok(missing)
    }
}

#[cfg(test)]
mod tests {

    use super::*;
    use crate::{
        testing::{SampleGraph, VecGraph},
        BaseRevision,
    };

    impl From<BaseRevision> for Revision {
        fn from(value: BaseRevision) -> Self {
            if !cfg!(test) {
                panic!("should only be used in tests")
            }
            Revision(value)
        }
    }

    impl PartialEq<BaseRevision> for Revision {
        fn eq(&self, other: &BaseRevision) -> bool {
            if !cfg!(test) {
                panic!("should only be used in tests")
            }
            self.0.eq(other)
        }
    }

    impl PartialEq<u32> for Revision {
        fn eq(&self, other: &u32) -> bool {
            if !cfg!(test) {
                panic!("should only be used in tests")
            }
            let check: Result<u32, _> = self.0.try_into();
            match check {
                Ok(value) => value.eq(other),
                Err(_) => false,
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
    fn test_descending_revision_set() {
        let mut set = DescendingRevisionSet::new(Revision(1_000_000));

        assert_eq!(set.len(), 0);
        assert!(!set.contains(Revision(999_950)));

        assert_eq!(set.insert(Revision(999_950)), Ok(true));
        assert_eq!(set.insert(Revision(999_950)), Ok(false));
        assert_eq!(set.insert(Revision(1_000_000)), Ok(true));
        assert_eq!(
            set.insert(Revision(1_000_001)),
            Err(GraphError::ParentOutOfOrder(Revision(1_000_001)))
        );

        assert_eq!(set.len(), 2);
        assert!(set.contains(Revision(999_950)));
        assert!(!set.contains(Revision(999_951)));
        assert!(set.contains(Revision(1_000_000)));
        assert!(!set.contains(Revision(1_000_001)));
    }

    #[test]
    /// Same tests as test-ancestor.py, without membership
    /// (see also test-ancestor.py.out)
    fn test_list_ancestor() {
        assert_eq!(
            list_ancestors(SampleGraph, vec![], 0.into(), false),
            Vec::<Revision>::new()
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                0.into(),
                false
            ),
            vec![8, 7, 4, 3, 2, 1, 0]
        );
        // it works as well on references, because &Graph implements Graph
        // this is needed as of this writing by RHGitaly
        assert_eq!(
            list_ancestors(
                &SampleGraph,
                vec![11.into(), 13.into()],
                0.into(),
                false
            ),
            vec![8, 7, 4, 3, 2, 1, 0]
        );

        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![1.into(), 3.into()],
                0.into(),
                false
            ),
            vec![1, 0]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                0.into(),
                true
            ),
            vec![13, 11, 8, 7, 4, 3, 2, 1, 0]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                6.into(),
                false
            ),
            vec![8, 7]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                6.into(),
                true
            ),
            vec![13, 11, 8, 7]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                11.into(),
                true
            ),
            vec![13, 11]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![11.into(), 13.into()],
                12.into(),
                true
            ),
            vec![13]
        );
        assert_eq!(
            list_ancestors(
                SampleGraph,
                vec![10.into(), 1.into()],
                0.into(),
                true
            ),
            vec![10, 5, 4, 2, 1, 0]
        );
    }

    #[test]
    /// Corner case that's not directly in test-ancestors.py, but
    /// that happens quite often, as demonstrated by running the whole
    /// suite.
    /// For instance, run tests/test-obsolete-checkheads.t
    fn test_nullrev_input() {
        let mut iter = AncestorsIterator::new(
            SampleGraph,
            vec![Revision(-1)],
            0.into(),
            false,
        )
        .unwrap();
        assert_eq!(iter.next(), None)
    }

    #[test]
    fn test_contains() {
        let mut lazy = AncestorsIterator::new(
            SampleGraph,
            vec![10.into(), 1.into()],
            0.into(),
            true,
        )
        .unwrap();
        assert!(lazy.contains(1.into()).unwrap());
        assert!(!lazy.contains(3.into()).unwrap());

        let mut lazy = AncestorsIterator::new(
            SampleGraph,
            vec![0.into()],
            0.into(),
            false,
        )
        .unwrap();
        assert!(!lazy.contains(NULL_REVISION).unwrap());
    }

    #[test]
    fn test_peek() {
        let mut iter = AncestorsIterator::new(
            SampleGraph,
            vec![10.into()],
            0.into(),
            true,
        )
        .unwrap();
        // peek() gives us the next value
        assert_eq!(iter.peek(), Some(10.into()));
        // but it's not been consumed
        assert_eq!(iter.next(), Some(Ok(10.into())));
        // and iteration resumes normally
        assert_eq!(iter.next(), Some(Ok(5.into())));

        // let's drain the iterator to test peek() at the end
        while iter.next().is_some() {}
        assert_eq!(iter.peek(), None);
    }

    #[test]
    fn test_empty() {
        let mut iter = AncestorsIterator::new(
            SampleGraph,
            vec![10.into()],
            0.into(),
            true,
        )
        .unwrap();
        assert!(!iter.is_empty());
        while iter.next().is_some() {}
        assert!(!iter.is_empty());

        let iter = AncestorsIterator::new(SampleGraph, vec![], 0.into(), true)
            .unwrap();
        assert!(iter.is_empty());

        // case where iter.seen == {NULL_REVISION}
        let iter = AncestorsIterator::new(
            SampleGraph,
            vec![0.into()],
            0.into(),
            false,
        )
        .unwrap();
        assert!(iter.is_empty());
    }

    /// A corrupted Graph, supporting error handling tests
    #[derive(Clone, Debug)]
    struct Corrupted;

    impl Graph for Corrupted {
        // FIXME what to do about this? Are we just not supposed to get them
        // anymore?
        fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
            match rev {
                Revision(1) => Ok([0.into(), (-1).into()]),
                r => Err(GraphError::ParentOutOfRange(r)),
            }
        }
    }

    #[test]
    fn test_initrev_out_of_range() {
        // inclusive=false looks up initrev's parents right away
        match AncestorsIterator::new(
            SampleGraph,
            vec![25.into()],
            0.into(),
            false,
        ) {
            Ok(_) => panic!("Should have been ParentOutOfRange"),
            Err(e) => assert_eq!(e, GraphError::ParentOutOfRange(25.into())),
        }
    }

    #[test]
    fn test_next_out_of_range() {
        // inclusive=false looks up initrev's parents right away
        let mut iter =
            AncestorsIterator::new(Corrupted, vec![1.into()], 0.into(), false)
                .unwrap();
        assert_eq!(
            iter.next(),
            Some(Err(GraphError::ParentOutOfRange(0.into())))
        );
    }

    #[test]
    /// Test constructor, add/get bases and heads
    fn test_missing_bases() -> Result<(), GraphError> {
        let mut missing_ancestors = MissingAncestors::new(
            SampleGraph,
            [5.into(), 3.into(), 1.into(), 3.into()].iter().cloned(),
        );
        let mut as_vec: Vec<Revision> =
            missing_ancestors.get_bases().iter().cloned().collect();
        as_vec.sort_unstable();
        assert_eq!(as_vec, [1, 3, 5]);
        assert_eq!(missing_ancestors.max_base, 5);

        missing_ancestors
            .add_bases([3.into(), 7.into(), 8.into()].iter().cloned());
        as_vec = missing_ancestors.get_bases().iter().cloned().collect();
        as_vec.sort_unstable();
        assert_eq!(as_vec, [1, 3, 5, 7, 8]);
        assert_eq!(missing_ancestors.max_base, 8);

        as_vec = missing_ancestors.bases_heads()?.iter().cloned().collect();
        as_vec.sort_unstable();
        assert_eq!(as_vec, [3, 5, 7, 8]);
        Ok(())
    }

    fn assert_missing_remove(
        bases: &[BaseRevision],
        revs: &[BaseRevision],
        expected: &[BaseRevision],
    ) {
        let mut missing_ancestors = MissingAncestors::new(
            SampleGraph,
            bases.iter().map(|r| Revision(*r)),
        );
        let mut revset: HashSet<Revision> =
            revs.iter().map(|r| Revision(*r)).collect();
        missing_ancestors
            .remove_ancestors_from(&mut revset)
            .unwrap();
        let mut as_vec: Vec<Revision> = revset.into_iter().collect();
        as_vec.sort_unstable();
        assert_eq!(as_vec.as_slice(), expected);
    }

    #[test]
    fn test_missing_remove() {
        assert_missing_remove(
            &[1, 2, 3, 4, 7],
            Vec::from_iter(1..10).as_slice(),
            &[5, 6, 8, 9],
        );
        assert_missing_remove(&[10], &[11, 12, 13, 14], &[11, 12, 13, 14]);
        assert_missing_remove(&[7], &[1, 2, 3, 4, 5], &[3, 5]);
    }

    fn assert_missing_ancestors(
        bases: &[BaseRevision],
        revs: &[BaseRevision],
        expected: &[BaseRevision],
    ) {
        let mut missing_ancestors = MissingAncestors::new(
            SampleGraph,
            bases.iter().map(|r| Revision(*r)),
        );
        let missing = missing_ancestors
            .missing_ancestors(revs.iter().map(|r| Revision(*r)))
            .unwrap();
        assert_eq!(missing.as_slice(), expected);
    }

    #[test]
    fn test_missing_ancestors() {
        // examples taken from test-ancestors.py by having it run
        // on the same graph (both naive and fast Python algs)
        assert_missing_ancestors(&[10], &[11], &[3, 7, 11]);
        assert_missing_ancestors(&[11], &[10], &[5, 10]);
        assert_missing_ancestors(&[7], &[9, 11], &[3, 6, 9, 11]);
    }

    /// An interesting case found by a random generator similar to
    /// the one in test-ancestor.py. An early version of Rust MissingAncestors
    /// failed this, yet none of the integration tests of the whole suite
    /// catched it.
    #[allow(clippy::unnecessary_cast)]
    #[test]
    fn test_remove_ancestors_from_case1() {
        const FAKE_NULL_REVISION: BaseRevision = -1;
        assert_eq!(FAKE_NULL_REVISION, NULL_REVISION.0);
        let graph: VecGraph = vec![
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
            [0, FAKE_NULL_REVISION],
            [1, 0],
            [2, 1],
            [3, FAKE_NULL_REVISION],
            [4, FAKE_NULL_REVISION],
            [5, 1],
            [2, FAKE_NULL_REVISION],
            [7, FAKE_NULL_REVISION],
            [8, FAKE_NULL_REVISION],
            [9, FAKE_NULL_REVISION],
            [10, 1],
            [3, FAKE_NULL_REVISION],
            [12, FAKE_NULL_REVISION],
            [13, FAKE_NULL_REVISION],
            [14, FAKE_NULL_REVISION],
            [4, FAKE_NULL_REVISION],
            [16, FAKE_NULL_REVISION],
            [17, FAKE_NULL_REVISION],
            [18, FAKE_NULL_REVISION],
            [19, 11],
            [20, FAKE_NULL_REVISION],
            [21, FAKE_NULL_REVISION],
            [22, FAKE_NULL_REVISION],
            [23, FAKE_NULL_REVISION],
            [2, FAKE_NULL_REVISION],
            [3, FAKE_NULL_REVISION],
            [26, 24],
            [27, FAKE_NULL_REVISION],
            [28, FAKE_NULL_REVISION],
            [12, FAKE_NULL_REVISION],
            [1, FAKE_NULL_REVISION],
            [1, 9],
            [32, FAKE_NULL_REVISION],
            [33, FAKE_NULL_REVISION],
            [34, 31],
            [35, FAKE_NULL_REVISION],
            [36, 26],
            [37, FAKE_NULL_REVISION],
            [38, FAKE_NULL_REVISION],
            [39, FAKE_NULL_REVISION],
            [40, FAKE_NULL_REVISION],
            [41, FAKE_NULL_REVISION],
            [42, 26],
            [0, FAKE_NULL_REVISION],
            [44, FAKE_NULL_REVISION],
            [45, 4],
            [40, FAKE_NULL_REVISION],
            [47, FAKE_NULL_REVISION],
            [36, 0],
            [49, FAKE_NULL_REVISION],
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
            [51, FAKE_NULL_REVISION],
            [52, FAKE_NULL_REVISION],
            [53, FAKE_NULL_REVISION],
            [14, FAKE_NULL_REVISION],
            [55, FAKE_NULL_REVISION],
            [15, FAKE_NULL_REVISION],
            [23, FAKE_NULL_REVISION],
            [58, FAKE_NULL_REVISION],
            [59, FAKE_NULL_REVISION],
            [2, FAKE_NULL_REVISION],
            [61, 59],
            [62, FAKE_NULL_REVISION],
            [63, FAKE_NULL_REVISION],
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
            [65, FAKE_NULL_REVISION],
            [66, FAKE_NULL_REVISION],
            [67, FAKE_NULL_REVISION],
            [68, FAKE_NULL_REVISION],
            [37, 28],
            [69, 25],
            [71, FAKE_NULL_REVISION],
            [72, FAKE_NULL_REVISION],
            [50, 2],
            [74, FAKE_NULL_REVISION],
            [12, FAKE_NULL_REVISION],
            [18, FAKE_NULL_REVISION],
            [77, FAKE_NULL_REVISION],
            [78, FAKE_NULL_REVISION],
            [79, FAKE_NULL_REVISION],
            [43, 33],
            [81, FAKE_NULL_REVISION],
            [82, FAKE_NULL_REVISION],
            [83, FAKE_NULL_REVISION],
            [84, 45],
            [85, FAKE_NULL_REVISION],
            [86, FAKE_NULL_REVISION],
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
            [88, FAKE_NULL_REVISION],
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
            [76, 83],
            [44, FAKE_NULL_REVISION],
            [92, FAKE_NULL_REVISION],
            [93, FAKE_NULL_REVISION],
            [9, FAKE_NULL_REVISION],
            [95, 67],
            [96, FAKE_NULL_REVISION],
            [97, FAKE_NULL_REVISION],
            [FAKE_NULL_REVISION, FAKE_NULL_REVISION],
        ]
        .into_iter()
        .map(|[a, b]| [Revision(a), Revision(b)])
        .collect();
        let problem_rev = 28.into();
        let problem_base = 70.into();
        // making the problem obvious: problem_rev is a parent of problem_base
        assert_eq!(graph.parents(problem_base).unwrap()[1], problem_rev);

        let mut missing_ancestors: MissingAncestors<VecGraph> =
            MissingAncestors::new(
                graph,
                [60, 26, 70, 3, 96, 19, 98, 49, 97, 47, 1, 6]
                    .iter()
                    .map(|r| Revision(*r)),
            );
        assert!(missing_ancestors.bases.contains(&problem_base));

        let mut revs: HashSet<Revision> =
            [4, 12, 41, 28, 68, 38, 1, 30, 56, 44]
                .iter()
                .map(|r| Revision(*r))
                .collect();
        missing_ancestors.remove_ancestors_from(&mut revs).unwrap();
        assert!(!revs.contains(&problem_rev));
    }
}
