//! Gather code around processing and applying delta
//!
//! Terminology:
//!
//! **Full-Text:** a blob of bytes that consistitute a consisten content
//! (usually a revision)
//!
//! **Delta:** A series of "DeltaPiece" that can be applied to a Full-Text" to
//! produce another "Full-Text".
//!
//! **DeltaPiece:** An atomic unit that replace a section of the *old*
//! "Full-Text" with another.
//!
//! **Delta-Chain:** A "Full-Text" followed by a list of Delta.
//!
//! **Delta-Base:** The content a Delta applies to. It can be an explicite
//! Full-Text or a Delta-Chain.
use byteorder::BigEndian;
use byteorder::ByteOrder;

use super::inner_revlog::RevisionBuffer;
use crate::revlog::RevlogError;

/// A piece of data to insert, delete or replace in a Delta
///
/// A DeltaPiece is:
/// - an insertion when `!data.is_empty() && start == end`
/// - an deletion when `data.is_empty() && start < end`
/// - a replacement when `!data.is_empty() && start < end`
/// - not doing anything when `data.is_empty() && start == end`
#[derive(Clone)]
pub(crate) struct DeltaPiece<'a> {
    /// The start position of the chunk of data to replace
    pub(crate) start: u32,
    /// The end position of the chunk of data to replace (open end interval)
    pub(crate) end: u32,
    /// The data replacing the chunk
    pub(crate) data: &'a [u8],
}

impl DeltaPiece<'_> {
    /// Adjusted start of the data to replace.
    ///
    /// The offset, taking into account the growth/shrinkage of data
    /// induced by previously applied DeltaPiece.
    fn start_offset_by(&self, offset: i32) -> u32 {
        let start = self.start as i32 + offset;
        assert!(start >= 0, "negative chunk start should never happen");
        start as u32
    }

    /// Adjusted end of the data to replace.
    ///
    /// The offset, taking into account the growth/shrinkage of data
    /// induced by previously applied DeltaPiece.
    fn end_offset_by(&self, offset: i32) -> u32 {
        self.start_offset_by(offset) + self.data.len() as u32
    }

    /// Length of the replaced date.
    fn replaced_len(&self) -> u32 {
        self.end - self.start
    }

    /// Length difference between the replacing data and the replaced data.
    fn len_diff(&self) -> i32 {
        self.data.len() as i32 - self.replaced_len() as i32
    }

    /// push a single DeltaPiece inside a Delta, ignoring empty ones
    pub fn write(self, delta: &mut Vec<u8>) {
        let size: u32 =
            self.data.len().try_into().expect("more than 2GB of patch data");
        debug_assert!(
            !(self.start == self.end && size == 0),
            "won't write empty chunk"
        );
        delta.extend_from_slice(&u32::to_be_bytes(self.start));
        delta.extend_from_slice(&u32::to_be_bytes(self.end));
        delta.extend_from_slice(&u32::to_be_bytes(size));
        delta.extend_from_slice(self.data);
    }
}

impl std::fmt::Debug for DeltaPiece<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeltaPiece")
            .field("start", &self.start)
            .field("end", &self.end)
            .field("size", &self.data.len())
            .finish()
    }
}

/// The delta between two revisions data.
#[derive(Debug, Clone)]
pub struct Delta<'a> {
    /// A collection of DeltaPiece to apply.
    ///
    /// Those DeltaPiece are:
    /// - ordered from the left-most replacement to the right-most replacement
    /// - non-overlapping, meaning that two chucks can not change the same
    ///   chunk of the patched data
    pub(crate) chunks: Vec<DeltaPiece<'a>>,
}

impl<'a> Delta<'a> {
    /// Create a `Delta` from bytes.
    pub fn new(data: &'a [u8]) -> Result<Self, RevlogError> {
        let mut chunks = vec![];
        let mut data = data;
        while !data.is_empty() {
            let start = BigEndian::read_u32(&data[0..]);
            let end = BigEndian::read_u32(&data[4..]);
            let len = BigEndian::read_u32(&data[8..]);
            if start > end {
                return Err(RevlogError::corrupted("patch cannot be decoded"));
            }
            chunks.push(DeltaPiece {
                start,
                end,
                data: &data[12..12 + (len as usize)],
            });
            data = &data[12 + (len as usize)..];
        }
        Ok(Delta { chunks })
    }

    /// Creates a patch for a full snapshot, going from nothing to `data`.
    pub fn full_snapshot(data: &'a [u8]) -> Self {
        Self { chunks: vec![DeltaPiece { start: 0, end: 0, data }] }
    }

    /// Apply the Delta to some Full-Text,
    pub fn apply<T>(
        &self,
        buffer: &mut dyn RevisionBuffer<Target = T>,
        initial: &[u8],
    ) {
        let mut last: usize = 0;
        for DeltaPiece { start, end, data } in self.chunks.iter() {
            let slice = &initial[last..(*start as usize)];
            buffer.extend_from_slice(slice);
            buffer.extend_from_slice(data);
            last = *end as usize;
        }
        buffer.extend_from_slice(&initial[last..]);
    }

    /// Combine two Delta into a single Delta.
    ///
    /// Applying consecutive Delta can lead to waste of time and memory
    /// as the changes introduced by one Delta can be overridden by the next.
    /// Combining Delta optimizes the whole patching sequence.
    fn combine(&mut self, other: &mut Self) -> Self {
        let mut chunks = vec![];

        // Keep track of each growth/shrinkage resulting from applying a chunk
        // in order to adjust the start/end of subsequent chunks.
        let mut offset = 0i32;

        // Keep track of the chunk of self.chunks to process.
        let mut pos = 0;

        // For each chunk of `other`, chunks of `self` are processed
        // until they start after the end of the current chunk.
        for DeltaPiece { start, end, data } in other.chunks.iter() {
            // Add chunks of `self` that start before this chunk of `other`
            // without overlap.
            while pos < self.chunks.len()
                && self.chunks[pos].end_offset_by(offset) <= *start
            {
                let first = self.chunks[pos].clone();
                offset += first.len_diff();
                chunks.push(first);
                pos += 1;
            }

            // The current chunk of `self` starts before this chunk of `other`
            // with overlap.
            // The left-most part of data is added as an insertion chunk.
            // The right-most part data is kept in the chunk.
            if pos < self.chunks.len()
                && self.chunks[pos].start_offset_by(offset) < *start
            {
                let first = &mut self.chunks[pos];

                let (data_left, data_right) = first.data.split_at(
                    (*start - first.start_offset_by(offset)) as usize,
                );
                let left = DeltaPiece {
                    start: first.start,
                    end: first.start,
                    data: data_left,
                };

                first.data = data_right;

                offset += left.len_diff();

                chunks.push(left);

                // There is no index incrementation because the right-most part
                // needs further examination.
            }

            // At this point remaining chunks of `self` starts after
            // the current chunk of `other`.

            // `start_offset` will be used to adjust the start of the current
            // chunk of `other`.
            // Offset tracking continues with `end_offset` to adjust the end
            // of the current chunk of `other`.
            let mut next_offset = offset;

            // Discard the chunks of `self` that are totally overridden
            // by the current chunk of `other`
            while pos < self.chunks.len()
                && self.chunks[pos].end_offset_by(next_offset) <= *end
            {
                let first = &self.chunks[pos];
                next_offset += first.len_diff();
                pos += 1;
            }

            // Truncate the left-most part of chunk of `self` that overlaps
            // the current chunk of `other`.
            if pos < self.chunks.len()
                && self.chunks[pos].start_offset_by(next_offset) < *end
            {
                let first = &mut self.chunks[pos];

                let how_much_to_discard =
                    *end - first.start_offset_by(next_offset);

                first.data = &first.data[(how_much_to_discard as usize)..];

                next_offset += how_much_to_discard as i32;
            }

            // Add the chunk of `other` with adjusted position.
            chunks.push(DeltaPiece {
                start: (*start as i32 - offset) as u32,
                end: (*end as i32 - next_offset) as u32,
                data,
            });

            // Go back to normal offset tracking for the next `o` chunk
            offset = next_offset;
        }

        // Add remaining chunks of `self`.
        for elt in &self.chunks[pos..] {
            chunks.push(elt.clone());
        }
        Delta { chunks }
    }
}

/// Combine a list of Deltas into a single Delta "optimized".
///
/// Content from different Delta will still appears in different DeltaPiece, so
/// the result if not "minimal". However it is "optiomized" in terms of
/// application as it only contains non overlapping DeltaPiece.
pub fn fold_deltas<'a>(lists: &[Delta<'a>]) -> Delta<'a> {
    if lists.len() <= 1 {
        if lists.is_empty() {
            Delta { chunks: vec![] }
        } else {
            lists[0].clone()
        }
    } else {
        let (left, right) = lists.split_at(lists.len() / 2);
        let mut left_res = fold_deltas(left);
        let mut right_res = fold_deltas(right);
        left_res.combine(&mut right_res)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::revlog::CoreRevisionBuffer;

    const MIN_SIZE: usize = 1;
    const MAX_SIZE: usize = 10;

    /// apply a chain of Delta in binary form to a Full-Text
    fn apply_chain<D>(full_text: &[u8], deltas: &[D]) -> Vec<u8>
    where
        D: AsRef<[u8]>,
    {
        let deltas: Vec<_> =
            deltas.iter().map(|d| Delta::new(d.as_ref()).unwrap()).collect();

        let projected = fold_deltas(&deltas[..]);
        let mut buffer = CoreRevisionBuffer::new();
        projected.apply(&mut buffer, full_text);
        buffer.finish()
    }

    /// represent a chain of deltas usable for test.
    ///
    /// - the full text size is alway betwen 1 and 10,
    /// - content from the full text are bytes in the [0, 9] range,
    /// - content from patch N are bytes in the [10 * N, 10 * N + 9].
    #[derive(Debug, Clone, Eq, PartialEq)]
    struct TestChain {
        /// the "Full-Text" initial size
        initial_size: u8,
        /// The "Deltas" involved in the chain
        deltas: Vec<TestDelta>,
    }

    #[derive(Debug, Clone, Eq, PartialEq)]
    struct TestDelta {
        /// The size of the Full-Text this Delta applies to.
        src_size: u8,
        /// The size of the Full-Text resulting from applying this delta.
        dst_size: u8,
        /// The Delta-Pieces that compose this delta (alway have at least one).
        pieces: Vec<TestPiece>,
    }

    #[derive(Debug, Clone, Eq, PartialEq)]
    struct TestPiece {
        /// offset in the "Base" we start replacing.
        pos: u8,
        /// the size of the section in the "Base" we replace.
        old_size: u8,
        /// the size of the new section that get inserted.
        new_size: u8,
    }

    impl TestChain {
        /// turn into a "simplified" expression into a TestChain
        ///
        /// The delta_spec express the chain as slice de delta, each expressed
        /// as a slice of three item tuple: (pos, old_size, new_size)
        ///
        /// The actual bytes used for the full text and delta are automatically
        /// computed (see [`TestChain`] for details).
        fn new(
            initial_size: usize,
            deltas_spec: &[&[(usize, usize, usize)]],
        ) -> Self {
            assert!(MIN_SIZE <= initial_size);
            assert!(initial_size <= MAX_SIZE);
            let mut deltas = vec![];
            let mut src_size = initial_size as u8;
            for d_spec in deltas_spec.iter() {
                let mut new_size: i8 = src_size as i8;
                let mut pieces = vec![];
                for (pos, old, new) in d_spec.iter() {
                    new_size += *new as i8;
                    new_size -= *old as i8;
                    pieces.push(TestPiece {
                        pos: *pos as u8,
                        old_size: *old as u8,
                        new_size: *new as u8,
                    })
                }
                deltas.push(TestDelta {
                    src_size,
                    dst_size: new_size as u8,
                    pieces,
                });
                src_size = new_size as u8;
            }
            Self { initial_size: initial_size as u8, deltas }
        }

        fn full_text(&self) -> Vec<u8> {
            assert!(self.initial_size <= 10);
            let mut text = vec![];
            for i in 0..self.initial_size {
                text.push(i as u8);
            }
            text
        }

        /// Return all deltas in their binary serialization
        fn deltas(&self) -> Vec<Vec<u8>> {
            let mut pieces = vec![];
            for (idx, d) in self.deltas.iter().enumerate() {
                let mut data = PatchDataBuilder::new();
                let idx = (idx + 1) as u8;
                let new_data = [
                    (idx * 10) + 0,
                    (idx * 10) + 1,
                    (idx * 10) + 2,
                    (idx * 10) + 3,
                    (idx * 10) + 4,
                    (idx * 10) + 5,
                    (idx * 10) + 6,
                    (idx * 10) + 7,
                    (idx * 10) + 8,
                    (idx * 10) + 9,
                ];
                let mut cursor: usize = 0;
                for p in &d.pieces {
                    let start = p.pos;
                    let end = p.pos + p.old_size;
                    let cursor_end = cursor + p.new_size as usize;
                    assert!(cursor_end <= 10);
                    let new = &new_data[cursor..cursor_end];
                    data.replace(start as usize, end as usize, new);
                    cursor = cursor_end;
                }
                pieces.push(data.data);
            }
            pieces
        }

        /// return the expected final Full-Text from applying this delta Chain
        fn expected(&self) -> Vec<u8> {
            let mut content = self.full_text();
            for d in self.deltas() {
                let patch = Delta::new(&d).unwrap();
                let mut buffer = CoreRevisionBuffer::new();
                patch.apply(&mut buffer, &content);
                content = buffer.finish();
            }
            content
        }

        fn apply_result(&self) -> Vec<u8> {
            let full_text = self.full_text();
            let deltas = self.deltas();
            apply_chain(&full_text, &deltas)
        }
    }

    struct PatchDataBuilder {
        data: Vec<u8>,
    }

    impl PatchDataBuilder {
        pub fn new() -> Self {
            Self { data: vec![] }
        }

        pub fn replace(
            &mut self,
            start: usize,
            end: usize,
            data: &[u8],
        ) -> &mut Self {
            assert!(start <= end);
            self.data.extend(&(start as i32).to_be_bytes());
            self.data.extend(&(end as i32).to_be_bytes());
            self.data.extend(&(data.len() as i32).to_be_bytes());
            self.data.extend(data.iter());
            self
        }
    }

    #[test]
    fn test_ends_before() {
        let chain = TestChain::new(3, &[&[(0, 1, 2)], &[(2, 2, 3)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![10u8, 11, 20, 21, 22]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_starts_after() {
        let chain = TestChain::new(3, &[&[(0, 1, 1)], &[(1, 1, 2)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![10u8, 20, 21, 2]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_overridden() {
        let chain = TestChain::new(3, &[&[(1, 1, 2)], &[(1, 3, 3)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![0u8, 20, 21, 22]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_right_most_part_is_overridden() {
        let chain = TestChain::new(3, &[&[(0, 1, 2)], &[(1, 3, 3)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![10u8, 20, 21, 22]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_left_most_part_is_overridden() {
        let chain = TestChain::new(3, &[&[(1, 2, 3)], &[(0, 2, 2)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![20u8, 21, 11, 12]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_mid_is_overridden() {
        let chain = TestChain::new(3, &[&[(0, 3, 4)], &[(1, 2, 2)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![10u8, 20, 21, 13]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }

    #[test]
    fn test_simple_interleaved() {
        let chain = TestChain::new(3, &[&[(1, 1, 2), (3, 0, 1)]]);

        // test that the testing tool generated what we want
        //
        // This is a way to sanity check the testing tool.
        let expected = chain.expected();
        assert_eq!(expected, vec![0u8, 10, 11, 2, 12]);

        let result = chain.apply_result();
        assert_eq!(result, expected);
    }
}
