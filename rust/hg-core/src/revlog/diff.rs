//! Utilities to compute diff for and with Revlogs.
use imara_diff::Algorithm;
use imara_diff::Diff;
use imara_diff::InternedInput;
use imara_diff::TokenSource;

use super::inner_revlog::InnerRevlog;
use super::inner_revlog::SingleRevisionCache;
use super::patch;
use super::patch::DeltaPiece;
use super::patch::PlainDeltaPiece;
use super::RevlogEntry;
use super::RevlogError;
use crate::utils::u32_u;
use crate::utils::u_i32;
use crate::utils::u_u32;
use crate::utils::RawData;
use crate::Revision;

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

    pub fn ends_at(&self, offset: u32) -> bool {
        self.old.1 == offset
    }

    pub fn extend(&mut self, old_size: u32, new_size: u32) {
        self.old.1 += old_size;
        self.new.1 += new_size;
    }

    /// flush a non empty cursor
    pub fn into_piece(self) -> PlainDeltaPiece<'a> {
        let start = self.old.0;
        let end = self.old.1;
        let d_start = u32_u(self.new.0);
        let d_end = u32_u(self.new.1);
        let data = &self.data[d_start..d_end];
        PlainDeltaPiece { start, end, data }
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

/// return a lower bound estimate of the size of a line-aligned prefix
///
/// For that  many bytes, we garantee all lines are the same. A few consecutive
/// lines might still be identical after that point.
pub(crate) fn lines_prefix_size_low(left: &[u8], right: &[u8]) -> usize {
    lines_prefix_size_low_chunk::<CMP_BLK_SIZE>(left, right)
}

fn lines_prefix_size_low_chunk<const N: usize>(
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

/// Return the size of a line-aligned identical suffix
///
/// The suffix might not be minimal
pub fn lines_suffix_size_low(left: &[u8], right: &[u8]) -> usize {
    lines_suffix_size_low_chunk::<CMP_BLK_SIZE>(left, right)
}

fn lines_suffix_size_low_chunk<const N: usize>(
    left: &[u8],
    right: &[u8],
) -> usize {
    let chunk_count =
        std::iter::zip(left.rchunks_exact(N), right.rchunks_exact(N))
            .take_while(|(l, r)| l == r)
            .count();
    let size = chunk_count * N;
    match memchr::memchr(b'\n', &left[left.len() - size..]) {
        None => 0,
        Some(pos) => size - (pos + 1),
    }
}

/// Estimation of the number of bytes per lines
///
/// This is used to infer the number of line we can expect for a given full text
///
/// The value was arbitrarily picked and should probably be refined at some
/// point.
pub(crate) const MIN_AVG_LINE_SIZE: usize = 10;

/// Tracks the starting position of each line of a full text
///
/// Also holds an abstract final line marking the end of the full text.
struct Lines<'a> {
    /// The full text.
    data: &'a [u8],
    /// Starting position of each lines.
    offsets: Vec<usize>,
}

impl<'a> Lines<'a> {
    fn new(data: &'a [u8]) -> Self {
        let mut offsets =
            Vec::with_capacity(data.len() / MIN_AVG_LINE_SIZE + 2);
        // TODO: filling the vec at tokenization time would avoid walking the
        // memory twice
        offsets.push(0);
        offsets.extend(memchr::memchr_iter(b'\n', data).map(|o| o + 1));
        if let Some(c) = data.last() {
            if *c != b'\n' {
                offsets.push(data.len());
            }
        }
        Self { data, offsets }
    }

    /// The starting position of the `idx`'th line.
    fn offset(&self, idx: u32) -> u32 {
        u_u32(self.offsets[u32_u(idx)])
    }
}

/// iterator over each line of a full text.
struct IterLines<'a> {
    text: &'a Lines<'a>,
    idx: u32,
}

impl<'a> IterLines<'a> {
    fn new(text: &'a Lines) -> Self {
        Self { text, idx: 1 }
    }
}

impl<'a> Iterator for IterLines<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<Self::Item> {
        if u32_u(self.idx) < self.text.offsets.len() {
            let start = self.text.offset(self.idx - 1);
            let end = self.text.offset(self.idx);
            let next = &self.text.data[u32_u(start)..u32_u(end)];
            self.idx += 1;
            Some(next)
        } else {
            None
        }
    }
}

/// By default, a line diff is produced for slice of bytes
impl<'a> TokenSource for &'a Lines<'a> {
    type Token = &'a [u8];
    type Tokenizer = IterLines<'a>;

    fn tokenize(&self) -> Self::Tokenizer {
        IterLines::new(self)
    }

    fn estimate_tokens(&self) -> u32 {
        u_u32(self.offsets.len())
    }
}

/// Compute a delta between m1 an m2.
///
/// The delta is line aligned.
pub fn text_delta(m1: &[u8], m2: &[u8]) -> Vec<u8> {
    text_delta_with_offset(0, m1, m2)
}
pub(super) fn text_delta_with_offset(
    offset: u32,
    m1: &[u8],
    m2: &[u8],
) -> Vec<u8> {
    let mut delta = vec![];

    let offset: usize = offset.try_into().expect("16bits computer?");
    let prefix_size = lines_prefix_size_low(m1, m2);
    let suffix_size =
        lines_suffix_size_low(&m1[prefix_size..], &m2[prefix_size..]);

    match (
        &m1[prefix_size..m1.len() - suffix_size],
        &m2[prefix_size..m2.len() - suffix_size],
    ) {
        ([], []) => (),
        (m, []) => all_deleted(offset + prefix_size, m, &mut delta),
        ([], m) => all_created(offset + prefix_size, m, &mut delta),
        (sub_1, sub_2) => {
            text_delta_inner(offset + prefix_size, sub_1, sub_2, &mut delta)
        }
    }
    delta
}

fn all_created(prefix_size: usize, content: &[u8], delta: &mut Vec<u8>) {
    let start = u_u32(prefix_size);
    PlainDeltaPiece { start, end: start, data: content }.write(delta)
}

fn all_deleted(prefix_size: usize, deleted: &[u8], delta: &mut Vec<u8>) {
    let start = u_u32(prefix_size);
    let end = start + u_u32(deleted.len());
    PlainDeltaPiece { start, end, data: &[] }.write(delta)
}

/// The main part of [`text_delta`] extracted for clarity
///
/// This is the part actually diffing lines.
fn text_delta_inner(
    prefix_size: usize,
    m1: &[u8],
    m2: &[u8],
    delta: &mut Vec<u8>,
) {
    let skip: u32 = u_u32(prefix_size);
    let mut cursor: Option<DeltaCursor> = None;
    let t1 = Lines::new(m1);
    let t2 = Lines::new(m2);
    let input = InternedInput::new(&t1, &t2);
    // XXX consider testing other algorithm at some point
    let diff = Diff::compute(Algorithm::Myers, &input);
    for h in diff.hunks() {
        assert!(
            !(h.before.start == h.before.end && h.after.start == h.after.end),
            "{:?}",
            h,
        );
        let start = skip + t1.offset(h.before.start);
        let end = skip + t1.offset(h.before.end);
        let content_start = t2.offset(h.after.start);
        let content_end = t2.offset(h.after.end);
        cursor = Some(if let Some(mut c) = cursor.take() {
            if c.ends_at(start) {
                c.extend(end - start, content_end - content_start);
                c
            } else {
                c.into_piece().write(delta);
                DeltaCursor::new(start, end, content_start, content_end, m2)
            }
        } else {
            DeltaCursor::new(start, end, content_start, content_end, m2)
        });
    }
    if let Some(last) = cursor {
        last.into_piece().write(delta)
    }
}

/// hold state and data useful to computing the delta of two revisions with some
/// common part for their delta chain.
pub(super) struct RevDeltaState<'irl> {
    irl: &'irl InnerRevlog,
    cache: Option<SingleRevisionCache>,
    common_rev: Revision,
    old_rev: Revision,
    new_rev: Revision,
    common_chunks: Vec<RawData>,
    old_chain: Vec<RawData>,
    new_chain: Vec<RawData>,
}

/// hold the necessary reference to compute the delta between two content (from
/// a `RevDeltaState`)
pub(super) struct Prepared<'state> {
    pub(super) common_rev: Revision,
    pub(super) base_text: &'state [u8],
    pub(super) common_delta:
        patch::Delta<'state, patch::PlainDeltaPiece<'state>>,
    pub(super) common_size: u32,
    pub(super) old_delta: patch::Delta<'state, patch::PlainDeltaPiece<'state>>,
    pub(super) old_size: u32,
    pub(super) new_delta: patch::Delta<'state, patch::PlainDeltaPiece<'state>>,
    pub(super) new_size: u32,
}

impl<'irl> RevDeltaState<'irl> {
    pub(super) fn new(
        irl: &'irl InnerRevlog,
        cache: Option<SingleRevisionCache>,
        common_count: usize,
        cached_idx: Option<usize>,
        delta_chain_1: Vec<Revision>,
        delta_chain_2: Vec<Revision>,
    ) -> Result<Self, RevlogError> {
        let common_rev = delta_chain_1[common_count - 1];
        // note: rev_# might be different than the source if empty delta where
        // trimed from the chain. This has no impact of the computation
        // of the delta.
        let rev_1 = delta_chain_1[delta_chain_1.len() - 1];
        let rev_2 = delta_chain_2[delta_chain_2.len() - 1];
        let entry_c = &irl.get_entry(common_rev)?;
        let entry_1 = &irl.get_entry(rev_1)?;
        let entry_2 = &irl.get_entry(rev_2)?;
        let rev_size = |e: &RevlogEntry| e.uncompressed_len().unwrap_or(0u32);

        // estimate the total chunks size from the revisions size
        let size_c = rev_size(entry_c);
        let size_1 = rev_size(entry_1);
        let size_2 = rev_size(entry_2);
        let t_size_1 = Some(size_1 as u64 * 4);
        let t_size_2 = Some(size_2 as u64 * 4);
        irl.seen_file_size(u32_u(size_c.max(size_1.max(size_2))));

        let (cache, cached_skip) = if let Some(cached_idx) = cached_idx {
            (cache, cached_idx + 1)
        } else {
            (None, 0)
        };

        let mut common_chunks;
        let old_chain;
        if cached_skip == common_count {
            common_chunks = vec![];
            old_chain = irl.chunks(&delta_chain_1[cached_skip..], t_size_1)?;
        } else {
            common_chunks =
                irl.chunks(&delta_chain_1[cached_skip..], t_size_1)?;
            if common_count == common_chunks.len() {
                old_chain = vec![];
            } else {
                old_chain = common_chunks.split_off(common_count - cached_skip);
            }
        }

        let new_chain = irl.chunks(&delta_chain_2[common_count..], t_size_2)?;

        Ok(Self {
            irl,
            cache,
            common_rev,
            old_rev: rev_1,
            new_rev: rev_2,
            common_chunks,
            old_chain,
            new_chain,
        })
    }

    /// Return the core element to compute a delta from two common delta chain.
    pub(super) fn prepare(
        &'irl mut self,
    ) -> Result<Prepared<'irl>, RevlogError> {
        // determine the base_text and delta for the common part
        let (base_text, common_chain): (&[u8], &[RawData]) =
            if let Some(cache) = &self.cache {
                (cache, &self.common_chunks)
            } else {
                let (base, chain): (&RawData, &[RawData]) =
                    self.common_chunks.split_first().expect("empty chain?");
                (base, chain)
            };

        // get common base_text, delta, and size
        let common_deltas = patch::deltas(common_chain)?;
        let common_delta = patch::fold_deltas(&common_deltas);
        let size_c: u32 = self
            .irl
            .get_entry(self.common_rev)?
            .uncompressed_len()
            .unwrap_or_else(|| {
                let size = u_i32(base_text.len());
                let patched_size = size - common_delta.len_diff();
                assert!(patched_size >= 0);
                patched_size as u32
            });
        // old delta and size
        let old_deltas = patch::deltas(&self.old_chain)?;
        let old_delta = patch::fold_deltas(&old_deltas);
        let size_old: u32 = self
            .irl
            .get_entry(self.old_rev)?
            .uncompressed_len()
            .unwrap_or_else(|| {
                let patched_size = size_c as i32 - old_delta.len_diff();
                assert!(patched_size >= 0);
                patched_size as u32
            });
        // new delta and size
        let new_deltas = patch::deltas(&self.new_chain)?;
        let new_delta = patch::fold_deltas(&new_deltas);
        let size_new: u32 = self
            .irl
            .get_entry(self.new_rev)?
            .uncompressed_len()
            .unwrap_or_else(|| {
                let patched_size = size_c as i32 - new_delta.len_diff();
                assert!(patched_size >= 0);
                patched_size as u32
            });

        Ok(Prepared {
            common_rev: self.common_rev,
            base_text,
            common_delta,
            common_size: size_c,
            old_delta,
            old_size: size_old,
            new_delta,
            new_size: size_new,
        })
    }
}
