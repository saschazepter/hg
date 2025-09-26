//! Utilities to compute diff for and with Revlogs.

use super::patch::Chunk;

/// A windows of different data when computing a delta
///
/// It keep a reference to the full "new" data to be able to extend them.
pub(super) struct DeltaCursor<'a> {
    old: (u32, u32),
    new: (u32, u32),
    data: &'a [u8],
}

impl<'a> DeltaCursor<'a> {
    pub fn new(
        old_start: u32,
        old_end: u32,
        new_start: u32,
        new_end: u32,
        full_new_data: &'a [u8],
    ) -> Self {
        assert!(
            !(old_start == old_end && new_start == new_end),
            "{} == {} && {} == {}",
            old_start,
            old_end,
            new_start,
            new_end,
        );
        DeltaCursor {
            old: (old_start, old_end),
            new: (new_start, new_end),
            data: full_new_data,
        }
    }

    pub fn extend(&mut self, old_size: u32, new_size: u32) {
        self.old.1 += old_size;
        self.new.1 += new_size;
    }

    /// flush a non empty cursor
    pub fn into_chunk(self) -> Chunk<'a> {
        let start = self.old.0;
        let end = self.old.1;
        let d_start = self.new.0.try_into().expect("16 bits computer?");
        let d_end = self.new.1.try_into().expect("16 bits computer?");
        let data = &self.data[d_start..d_end];
        Chunk { start, end, data }
    }
}

impl std::fmt::Debug for DeltaCursor<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeltaCursor")
            .field("old", &self.old)
            .field("old_size", &(self.old.1 - self.old.0))
            .field("new", &self.new)
            .field("new_size", &(self.new.1 - self.new.0))
            .finish()
    }
}

// note: 512 was picked somewhat arbitrarily and could probably be tuned.
// The value need to be big enough to the compiler to decide to use the most
// efficient SIMD vectorization at hand. Overshooting a bit is not dramatic as a
// manifest line is in the 100 bytes order of magnitude.
pub(crate) const CMP_BLK_SIZE: usize = 512;

/// return the starting position from which lines MAY be different between left
/// and right
///
/// Any position before that garantee that the lines are the same.
pub(crate) fn start_maybe_mismatch_line(left: &[u8], right: &[u8]) -> usize {
    start_mismatch_line_chunk::<CMP_BLK_SIZE>(left, right)
}

fn start_mismatch_line_chunk<const N: usize>(
    left: &[u8],
    right: &[u8],
) -> usize {
    let chunk_count =
        std::iter::zip(left.chunks_exact(N), right.chunks_exact(N))
            .take_while(|(l, r)| l == r)
            .count();
    let chunk_off = chunk_count * N;
    match memchr::memrchr(b'\n', &left[..chunk_off]) {
        None => 0,
        Some(pos) => pos + 1,
    }
}
