use bit_set::BitSet;

use crate::GraphError;
use crate::GraphErrorKind;
use crate::Revision;

/// A set of revisions backed by a bitset, optimized for descending insertion.
pub struct DescendingRevisionSet {
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
    pub fn new(ceiling: Revision) -> Self {
        Self { set: BitSet::new(), ceiling: ceiling.0, len: 0 }
    }

    /// Returns the number of revisions in the set.
    pub fn len(&self) -> usize {
        self.len
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Returns true if the set contains `value`.
    pub fn contains(&self, value: Revision) -> bool {
        match self.encode(value) {
            Ok(n) => self.set.contains(n),
            Err(_) => false,
        }
    }

    /// Adds `value` to the set. Returns true if it was not already in the set.
    /// Returns `Err` if it cannot store it because it is above the ceiling.
    pub fn insert(&mut self, value: Revision) -> Result<bool, GraphError> {
        let inserted = self.set.insert(self.encode(value)?);
        self.len += inserted as usize;
        Ok(inserted)
    }

    pub fn encode(&self, value: Revision) -> Result<usize, GraphError> {
        usize::try_from(self.ceiling - value.0)
            .map_err(|_| GraphErrorKind::ParentOutOfOrder(value).into())
    }

    pub fn iter_descending(&self) -> impl Iterator<Item = Revision> {
        self.set.iter().map(|n| Revision(self.ceiling - n as i32))
    }
}
