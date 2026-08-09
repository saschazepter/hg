use std::fmt;
use std::ops::Bound;
use std::ops::Deref;
use std::ops::DerefMut;
use std::ops::RangeBounds;
use std::ptr::NonNull;
use std::sync::Arc;

use stable_deref_trait::StableDeref;

use crate::errors::HgBacktrace;

/// Error Kinds for
#[derive(Debug, PartialEq, Eq)]
pub enum ErrorKind {
    /// The range's start is greater than its end
    StartAfterEnd { start: usize, end: usize },
    /// The range ends past the end of the slice
    OutOfBounds { end: usize, len: usize },
    /// The range is in bounds but its bytes are not contiguous in memory.
    ///
    /// Offsets are logical offsets into the source [`SegmentedBytes`], not
    /// into the [`SegmentedBytesSlice`] this was called on, since extent
    /// boundaries only exist at the source level.
    SpansExtents { start: usize, end: usize },
}

#[derive(Debug, PartialEq)]
pub struct Error {
    pub kind: ErrorKind,
    pub backtrace: HgBacktrace,
}

impl From<ErrorKind> for Error {
    fn from(value: ErrorKind) -> Self {
        Self { kind: value, backtrace: HgBacktrace::capture() }
    }
}

/// Presents a logical concatenation of byte slices, mostly intended for
/// append-only memory-mapped binary formats.
pub struct SegmentedBytes {
    /// Contains all backing slices. This must never be mutated after `new`.
    extents: Vec<CachedExtent>,
    /// A cache of the sum of the length of all extents
    total_len: usize,
}

// Make sure we never implement `Deref`: it would let downstream code compile
// `bytes[index]`, `bytes.get(index)`, etc. against the whole buffer, which
// can only panic at runtime on multi-extent data.
static_assertions_next::assert_impl!(SegmentedBytes: !Deref);

impl SegmentedBytes {
    /// Create a new [`Self`] from this set of extents. Will logically
    /// concatenate in the same order, the caller is responsible for providing
    /// data that can be meaningfully used (i.e. no slices that span extents)
    pub fn new(extents: Vec<Extent>) -> Self {
        Self::empty().with_new_extents(extents)
    }

    /// Create an empty buffer, which will always stay empty
    pub fn empty() -> Self {
        Self { extents: vec![], total_len: 0 }
    }

    /// Create a new [`Self`] from a single raw extent
    pub fn from_single_extent<OnDisk>(on_disk: OnDisk) -> Self
    where
        OnDisk: StableDeref<Target = [u8]> + Send + Sync + 'static,
    {
        Self::new(vec![Arc::new(on_disk)])
    }

    /// Cheaply creates a new [`Self`] from the extents in `self`,
    /// followed by `new_extents`, with no copying of actual data.
    pub fn with_new_extents(
        &self,
        new_extents: impl IntoIterator<Item = Extent>,
    ) -> Self {
        let mut extents = self.extents.clone();
        let mut total_len = self.total_len;
        for extent in new_extents {
            let extent = CachedExtent::new(extent, total_len);
            total_len = extent.end_offset;
            extents.push(extent);
        }
        Self { extents, total_len }
    }

    /// The length of the entire logically concatenated data
    #[inline]
    pub fn len(&self) -> usize {
        self.total_len
    }

    /// `true` can still mean that we have only empty extents
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.total_len == 0
    }

    /// The bytes in `range` as a slice.
    ///
    /// # Panics
    ///
    /// - If the range is out of the logical bounds or spans multiple [`Extent`]
    #[inline]
    pub fn range_to_slice(&self, range: impl RangeBounds<usize>) -> &[u8] {
        self.as_slice().contiguous_slice(range)
    }

    /// A borrowed view of `range`, like `&[u8]` to a `Vec<u8>`.
    /// The range may span multiple extents, as it is intended to reduce the
    /// logical range over a [`SegmentedBytes`].
    #[inline]
    pub fn slice(
        &self,
        range: impl RangeBounds<usize>,
    ) -> SegmentedBytesSlice<'_> {
        self.as_slice().slice(range)
    }

    pub fn iter(&self) -> impl Iterator<Item = &u8> {
        self.as_slice().iter_extents().flat_map(<[u8]>::iter)
    }

    pub fn to_vec(&self) -> Vec<u8> {
        self.as_slice().to_vec()
    }

    /// Returns the [`Location`] for this logical offset.
    ///
    /// # Panics
    ///
    /// - If the offset is out of the logical bounds
    fn locate(&self, logical_offset: usize) -> Location<'_> {
        debug_assert!(logical_offset < self.total_len);

        // Scanning the offsets sequentially instead of with a binary search
        // is likely better for small quantities, here up to two cache lines.
        let extent_idx = if self.extents.len() <= 16 {
            self.extents
                .iter()
                .take_while(|extent| extent.end_offset <= logical_offset)
                .count()
        } else {
            // Binary search if we really have that many offsets
            self.extents
                .partition_point(|extent| extent.end_offset <= logical_offset)
        };
        let extent = &self.extents[extent_idx];
        let bytes = extent.bytes();
        Location {
            extent: bytes,
            offset: logical_offset - (extent.end_offset - bytes.len()),
        }
    }

    /// A borrowed view of the whole buffer (what [`str`] is to [`String`]).
    pub fn as_slice(&self) -> SegmentedBytesSlice<'_> {
        SegmentedBytesSlice {
            source: self,
            bounds: LogicalBounds { start: 0, end: self.total_len },
            contiguous: if self.extents.len() == 1 {
                Some(self.extents[0].bytes())
            } else {
                None
            },
        }
    }
}

impl fmt::Debug for SegmentedBytes {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SegmentedBytes")
            .field("len", &self.total_len)
            .field(
                "extent_lengths",
                &self
                    .extents
                    .iter()
                    .map(|extent| extent.bytes().len())
                    .collect::<Vec<_>>(),
            )
            .finish()
    }
}

/// What [`str`] is to [`String`] for [`SegmentedBytes`].
///
/// Can span multiple [`Extent`], used for example to logically concatenate
/// append-only datastructures from multiple sources at once.
#[derive(Clone, Copy)]
pub struct SegmentedBytesSlice<'a> {
    source: &'a SegmentedBytes,
    /// The logical slice that this [`Self`] concerns.
    bounds: LogicalBounds,
    /// Contains the plain slice if the source is contiguous anyway, which
    /// speeds up the likely single-extent case.
    contiguous: Option<&'a [u8]>,
}

impl<'source> SegmentedBytesSlice<'source> {
    /// The size in bytes of the logical slice
    #[inline]
    pub fn len(&self) -> usize {
        self.bounds.len()
    }

    /// `true` if the logical slice is empty
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.bounds.is_empty()
    }

    /// Narrows the slice to that logical range, with no copying.
    ///
    /// # Panics
    ///
    /// - Range spans logical offsets that [`self`] does not
    #[inline]
    pub fn slice(
        &self,
        range: impl RangeBounds<usize>,
    ) -> SegmentedBytesSlice<'source> {
        let bounds = range_to_bounds(range, self.len());
        SegmentedBytesSlice {
            source: self.source,
            bounds: LogicalBounds {
                start: self.bounds.start + bounds.start,
                end: self.bounds.start + bounds.end,
            },
            contiguous: self
                .contiguous
                .map(|bytes| &bytes[bounds.start..bounds.end]),
        }
    }

    /// Narrows the slice to that logical range, with no copying.
    ///
    /// # Panics
    ///
    /// - Range spans logical offsets that [`self`] does not
    #[inline]
    pub fn try_slice(
        &self,
        range: impl RangeBounds<usize>,
    ) -> Result<SegmentedBytesSlice<'source>, Error> {
        let bounds = try_range_to_bounds(range, self.len())?;
        Ok(SegmentedBytesSlice {
            source: self.source,
            bounds: LogicalBounds {
                start: self.bounds.start + bounds.start,
                end: self.bounds.start + bounds.end,
            },
            contiguous: self
                .contiguous
                .map(|bytes| &bytes[bounds.start..bounds.end]),
        })
    }

    /// Returns slices of all logically contiguous (non-empty) chunks, in order
    pub fn iter_extents(
        &self,
    ) -> impl Iterator<Item = &'source [u8]> + use<'source> {
        let source = self.source;
        let end = self.bounds.end;
        let mut position = self.bounds.start;
        std::iter::from_fn(move || {
            if position >= end {
                return None;
            }
            let Location { extent, offset } = source.locate(position);
            let take = (end - position).min(extent.len() - offset);
            position += take;
            Some(&extent[offset..offset + take])
        })
    }

    /// Returns a plain owned [`Vec`] of all of the logically contiguous data
    pub fn to_vec(&self) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(self.len());
        for piece in self.iter_extents() {
            bytes.extend_from_slice(piece);
        }
        bytes
    }

    /// Returns the logical offset of `slice` within this [`Self`].
    ///
    /// This is the inverse operation of [`Self::contiguous_slice_opt`], but
    /// it always returns `None` on an empty slice.
    pub fn slice_to_offset(&self, slice: &[u8]) -> Option<usize> {
        if slice.is_empty() {
            return None;
        }
        let start_addr = slice.as_ptr() as usize;
        let end_addr = start_addr + slice.len();

        // We have to iterate over extents, can assume no ordering
        // for addresses
        for extent in &self.source.extents {
            let bytes = extent.bytes();
            let extent_start = bytes.as_ptr() as usize;
            let extent_end = extent_start + bytes.len();
            if start_addr < extent_start || end_addr > extent_end {
                // We're not in this extent, or we're crossing bounds
                continue;
            }
            let logical_start =
                (extent.end_offset - bytes.len()) + (start_addr - extent_start);
            let logical_end = logical_start + slice.len();
            // This falls outside of this [`Self`] altogether
            if logical_start < self.bounds.start
                || logical_end > self.bounds.end
            {
                return None;
            }
            return Some(logical_start - self.bounds.start);
        }
        None
    }

    /// Get a plain slice from a contiguous range.
    /// More panicking version of [`Self::contiguous_slice_opt`].
    ///
    /// # Panics
    ///
    /// - The range is out of bounds
    /// - The range spans multiple extents
    /// - The range is larger than `usize`
    #[inline]
    pub fn contiguous_slice(
        self,
        range: impl RangeBounds<usize>,
    ) -> &'source [u8] {
        if let Some(bytes) = self.contiguous {
            let bounds = range_to_bounds(range, bytes.len());
            return &bytes[bounds.start..bounds.end];
        }
        let bounds = range_to_bounds(range, self.len());
        // Translate to logical offsets into the source
        let start = self.bounds.start + bounds.start;
        let end = self.bounds.start + bounds.end;
        if start == end {
            return &[];
        }
        let Location { extent, offset } = self.source.locate(start);
        let available = extent.len() - offset;
        assert!(
            end - start <= available,
            "range {:?} spans multiple extents",
            bounds,
        );
        &extent[offset..offset + (end - start)]
    }

    /// Less-panicking version of [`Self::contiguous_slice`]
    ///
    /// # Panics
    ///
    /// - The range is larger than `usize`, which should never happen
    #[inline]
    pub fn contiguous_slice_opt(
        self,
        range: impl RangeBounds<usize>,
    ) -> Option<&'source [u8]> {
        if let Some(bytes) = self.contiguous {
            let bounds = range_to_bounds_opt(range, bytes.len())?;
            return Some(&bytes[bounds.start..bounds.end]);
        }
        let bounds = range_to_bounds_opt(range, self.len())?;
        // Translate to logical offsets into the source
        let start = self.bounds.start + bounds.start;
        let end = self.bounds.start + bounds.end;
        if start == end {
            return Some(&[]);
        }
        let Location { extent, offset } = self.source.locate(start);
        let available = extent.len() - offset;
        if end - start > available {
            return None;
        }
        Some(&extent[offset..offset + (end - start)])
    }
}

impl fmt::Debug for SegmentedBytesSlice<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SegmentedBytesSlice")
            .field("logical_bounds", &self.bounds)
            .finish()
    }
}

impl PartialEq<[u8]> for SegmentedBytesSlice<'_> {
    fn eq(&self, other: &[u8]) -> bool {
        if self.len() != other.len() {
            return false;
        }
        let mut rest = other;
        for piece in self.iter_extents() {
            let (head, tail) = rest.split_at(piece.len());
            if piece != head {
                return false;
            }
            rest = tail;
        }
        true
    }
}

/// Can be a `Vec<u8>`, `MMap`, `Box<[u8]>`, etc.
type InnerExtent = dyn StableDeref<Target = [u8]> + Send + Sync + 'static;

// Make sure what our [`Extent`] is pointing to stays true to these invariants:
// Stable in its address for its entire lifetime so we can cache its pointer
static_assertions_next::assert_impl!(InnerExtent: StableDeref);
// not `Clone`, since that would change the address of its target
static_assertions_next::assert_impl!(InnerExtent: !Clone);

/// Shared, read-only bytes behind an address-stable deref.
pub type Extent = Arc<InnerExtent>;

// Make sure that [`Extent`] true to these invariants:
// Its address is stable through a lifetime.
static_assertions_next::assert_impl!(Extent: StableDeref);
// *Not* `DerefMut`, this is just paranoia at this point since it's already
// [`StableDeref`].
static_assertions_next::assert_impl!(Extent: !DerefMut);

/// An [`Extent`] stored alongside its slice, resolved once at construction.
///
/// Going through an [`Extent`] on every access would cost two pointer jumps,
/// one for the [`Arc`] and one for whatever type holds the [`StableDeref`],
/// plus a vtable call that cannot be optimized away.
/// Extents are immutable, kept alive through `Arc`, their address is stable
/// (checked with `StableDeref`), so resolving once is sound and every access
/// after that is a plain slice.
pub struct CachedExtent {
    /// Points into `_owner`, valid for as long as `_owner` is alive.
    bytes: NonNull<[u8]>,
    /// The exclusive logical end offset of this extent within its
    /// [`SegmentedBytes`]
    end_offset: usize,
    _owner: Extent,
}

/// Safety: `bytes` is by construction a shared, read-only alias of data owned
/// by `_owner`, which is `Send`;
unsafe impl Send for CachedExtent {}
/// Safety: `bytes` is by construction a shared, read-only alias of data owned
/// by `_owner`, which is `Sync`;
unsafe impl Sync for CachedExtent {}

impl CachedExtent {
    fn new(owner: Extent, start_offset: usize) -> Self {
        let slice = owner.deref().deref();
        let end_offset =
            start_offset.checked_add(slice.len()).expect("extents too long");
        let bytes = NonNull::from(slice);
        Self { bytes, end_offset, _owner: owner }
    }

    fn bytes(&self) -> &[u8] {
        // Safety: See documentation of [`Self`]
        unsafe { self.bytes.as_ref() }
    }
}

impl Clone for CachedExtent {
    fn clone(&self) -> Self {
        // This works because the `Arc` keeps the allocation stable in memory
        Self {
            bytes: self.bytes,
            _owner: Arc::clone(&self._owner),
            end_offset: self.end_offset,
        }
    }
}

/// The location of a byte within a [`SegmentedBytes`]
struct Location<'a> {
    /// The bytes of the extent this byte is in
    extent: &'a [u8],
    /// Its offset within the extent
    offset: usize,
}

/// Represents bounds into the logically contiguous buffer.
/// This may span extents.
#[derive(Debug, Clone, Copy)]
struct LogicalBounds {
    start: usize,
    end: usize,
}

impl LogicalBounds {
    /// The length in logical bytes spanned
    fn len(&self) -> usize {
        self.end - self.start
    }

    fn is_empty(&self) -> bool {
        self.start == self.end
    }
}

/// Transforms any [`RangeBounds`] of [`usize`] into [`LogicalBounds`], checking
/// for simple overflows. This does not yet check for extent spanning, as it
/// is also used for [`SegmentedBytesSlice`].
fn range_to_bounds(
    range: impl RangeBounds<usize>,
    len: usize,
) -> LogicalBounds {
    let start = match range.start_bound() {
        Bound::Included(&start) => start,
        Bound::Excluded(&start) => {
            start.checked_add(1).expect("range start overflows usize")
        }
        Bound::Unbounded => 0,
    };
    let end = match range.end_bound() {
        Bound::Included(&end) => {
            end.checked_add(1).expect("range end overflows usize")
        }
        Bound::Excluded(&end) => end,
        Bound::Unbounded => len,
    };
    assert!(start <= end, "slice index starts at {start} but ends at {end}");
    assert!(
        end <= len,
        "range end index {end} out of range for slice of length {len}"
    );
    LogicalBounds { start, end }
}

/// Less panicking version of [`range_to_bounds`]
fn try_range_to_bounds(
    range: impl RangeBounds<usize>,
    len: usize,
) -> Result<LogicalBounds, Error> {
    let start = match range.start_bound() {
        Bound::Included(&start) => start,
        Bound::Excluded(&start) => {
            start.checked_add(1).expect("range start overflows usize")
        }
        Bound::Unbounded => 0,
    };
    let end = match range.end_bound() {
        Bound::Included(&end) => {
            end.checked_add(1).expect("range end overflows usize")
        }
        Bound::Excluded(&end) => end,
        Bound::Unbounded => len,
    };
    if start > end {
        return Err(ErrorKind::StartAfterEnd { start, end }.into());
    }
    if end > len {
        return Err(ErrorKind::OutOfBounds { end, len }.into());
    }
    Ok(LogicalBounds { start, end })
}

/// Less panicking version of [`range_to_bounds`]
fn range_to_bounds_opt(
    range: impl RangeBounds<usize>,
    len: usize,
) -> Option<LogicalBounds> {
    let start = match range.start_bound() {
        Bound::Included(&start) => start,
        Bound::Excluded(&start) => {
            start.checked_add(1).expect("range start overflows usize")
        }
        Bound::Unbounded => 0,
    };
    let end = match range.end_bound() {
        Bound::Included(&end) => {
            end.checked_add(1).expect("range end overflows usize")
        }
        Bound::Excluded(&end) => end,
        Bound::Unbounded => len,
    };
    if start > end {
        return None;
    }
    if end > len {
        return None;
    }
    Some(LogicalBounds { start, end })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn into_extent(bytes: &[u8]) -> Extent {
        Arc::new(bytes.to_vec())
    }

    /// "hello, world!" as "hel" | "" | "lo, wo" | "rld!", mixing extent types.
    fn segmented_base() -> SegmentedBytes {
        SegmentedBytes::new(vec![
            into_extent(b"hel"),
            into_extent(b""),
            Arc::new(&b"lo, wo"[..]) as Extent,
            Arc::new(b"rld!".to_vec().into_boxed_slice()) as Extent,
        ])
    }

    #[test]
    fn test_with_new_extents() {
        let base = segmented_base();
        let refcount_before = Arc::strong_count(&base.extents[0]._owner);
        let combined = base
            .with_new_extents([into_extent(b" it's"), into_extent(b" me!")]);
        assert_eq!(combined.len(), 22);
        assert_eq!(combined.to_vec(), b"hello, world! it's me!");
        // The original is untouched
        assert_eq!(base.to_vec(), b"hello, world!");

        // The refcount is updated
        assert_eq!(
            Arc::strong_count(&base.extents[0]._owner),
            refcount_before + 1
        );
        let base_slice = base.range_to_slice(3..9);
        let combined_slice = combined.range_to_slice(3..9);
        // Using the same memory
        assert_eq!(base_slice.as_ptr(), combined_slice.as_ptr());
        // This does not panic
        assert_eq!(combined.as_slice().slice_to_offset(base_slice), Some(3));

        // Dropping the base doesn't affect the other one
        drop(base);
        assert_eq!(combined.range_to_slice(3..9), b"lo, wo");

        // Empty extents is just a cheap clone
        let clone = combined.with_new_extents([]);
        assert_eq!(clone.to_vec(), b"hello, world! it's me!");
    }

    #[test]
    fn test_basic() {
        // Length and empty
        let base = segmented_base();
        assert_eq!(base.len(), 13);
        assert!(!base.is_empty());
        let empty = SegmentedBytes::new(Vec::new());
        assert!(empty.is_empty());
        assert_eq!(empty.range_to_slice(..), b"");

        assert_eq!(base.as_slice().contiguous_slice_opt(13..14), None);

        // Iteration
        let pieces: Vec<&[u8]> = base.as_slice().iter_extents().collect();
        assert_eq!(pieces, [b"hel" as &[u8], b"lo, wo", b"rld!"]);
        let bytes: Vec<u8> = base.iter().copied().collect();
        assert_eq!(bytes, b"hello, world!");
        assert_eq!(base.to_vec(), b"hello, world!");
    }

    #[test]
    fn test_single_extent() {
        let segmented = SegmentedBytes::new(vec![into_extent(b"abc")]);
        assert_eq!(segmented.range_to_slice(..), b"abc");
        assert_eq!(segmented.range_to_slice(..).first(), Some(&b'a'));

        // Narrowing a single-extent uses the correct (offset) indices
        let narrowed = segmented.slice(1..3);
        assert_eq!(narrowed.len(), 2);
        assert_eq!(narrowed.contiguous_slice(..), b"bc");
        assert_eq!(narrowed.contiguous_slice_opt(..), Some(&b"bc"[..]));
        assert_eq!(narrowed.contiguous_slice(1..), b"c");
        let renarrowed = narrowed.slice(1..2);
        assert_eq!(renarrowed.contiguous_slice(..), b"c");
        assert_eq!(narrowed.contiguous_slice_opt(1..3), None);

        let base = segmented_base();
        let base = base.as_slice();
        assert_eq!(&base.contiguous_slice(0..3), b"hel");
        assert_eq!(&base.contiguous_slice(..3), b"hel");
        assert_eq!(&base.contiguous_slice(3..9), b"lo, wo");
        assert_eq!(&base.contiguous_slice(4..=6), b"o, ");
        assert_eq!(&base.contiguous_slice(9..), b"rld!");
        // Empty ranges never panic, even on an extent boundary.
        assert_eq!(&base.contiguous_slice(3..3), b"");
        assert_eq!(&base.contiguous_slice(13..), b"");
    }

    #[test]
    fn test_slicing() {
        let base = segmented_base();
        let slice = base.slice(1..12);
        assert!(!slice.is_empty());
        assert_eq!(slice.len(), 11);
        assert_eq!(slice.to_vec(), b"ello, world");
        assert!(slice == b"ello, world"[..]);

        // Narrowing down to one extent makes it contiguous.
        let narrowed = slice.slice(2..8);
        assert_eq!(narrowed.to_vec(), b"lo, wo");
        assert_eq!(narrowed.contiguous_slice(..), b"lo, wo");
        assert_eq!(narrowed.contiguous_slice(1..3), b"o,");
    }

    #[test]
    fn test_binary_search_path() {
        // 100 extents will be above the linear scan limit.
        let extents: Vec<Extent> =
            (0..100).map(|i| into_extent(&[2 * i, 2 * i + 1])).collect();

        let segmented = SegmentedBytes::new(extents);
        // Check length
        assert_eq!(segmented.len(), 200);

        // Check indexing
        for i in 0..200 {
            assert_eq!(segmented.range_to_slice(i..i + 1), &[i as u8]);
        }

        // Check slicing (even though it's only 1 byte)
        assert_eq!(
            segmented.as_slice().contiguous_slice(6..8),
            [6, 7].as_slice()
        );

        // Check iteration
        let all: Vec<u8> = segmented.iter().copied().collect();
        assert_eq!(all, (0..200).collect::<Vec<u8>>());
    }

    #[test]
    fn test_slice_to_offset() {
        let base = segmented_base();
        let bytes_slice = base.as_slice();

        // Roundtrip with `contiguous_slice`
        let contains_lowo = bytes_slice.contiguous_slice(3..9);
        assert_eq!(contains_lowo, b"lo, wo");
        assert_eq!(bytes_slice.slice_to_offset(contains_lowo), Some(3));
        assert_eq!(bytes_slice.slice_to_offset(&contains_lowo[2..4]), Some(5));
        let contains_rld = bytes_slice.contiguous_slice(9..);
        assert_eq!(contains_rld, b"rld!");
        assert_eq!(bytes_slice.slice_to_offset(contains_rld), Some(9));

        // Empty slices return None
        assert_eq!(bytes_slice.slice_to_offset(&[]), None);

        // Identity is by address, not content
        let explicit_vec = b"lo, wo".to_vec();
        assert_eq!(bytes_slice.slice_to_offset(&explicit_vec), None);

        // Narrowed views change offsets
        let narrowed = base.slice(1..12);
        assert_eq!(narrowed.slice_to_offset(&contains_lowo[2..4]), Some(4));
        // "rld!" ends at logical offset 13, past the end of narrowed
        assert_eq!(narrowed.slice_to_offset(contains_rld), None);
    }

    // Panic tests, useful to make sure we don't create UB/surprises

    #[test]
    #[should_panic(expected = "out of range")]
    fn test_out_of_bounds() {
        let _ = segmented_base().slice(13..14);
    }

    #[test]
    #[should_panic(expected = "spans multiple extents")]
    fn test_multiple_extents_slicing() {
        let _ = &segmented_base().as_slice().contiguous_slice(2..4);
    }
}
