//! Utilities to compute diff for and with Revlogs.

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
