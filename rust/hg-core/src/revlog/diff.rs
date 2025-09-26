//! Utilities to compute diff for and with Revlogs.

use imara_diff::Algorithm;
use imara_diff::Diff;
use imara_diff::InternedInput;
use imara_diff::TokenSource;

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

    pub fn ends_at(&self, offset: u32) -> bool {
        self.old.1 == offset
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
        let i: usize = idx.try_into().expect("16 bits computer?");
        self.offsets[i].try_into().expect("16 bits computer?")
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
        if self.idx
            < self.text.offsets.len().try_into().expect("16 bits computer?")
        {
            let start = self
                .text
                .offset(self.idx - 1)
                .try_into()
                .expect("16 bits computer?");
            let end = self
                .text
                .offset(self.idx)
                .try_into()
                .expect("16 bits computer?");
            let next = &self.text.data[start..end];
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
        self.offsets.len().try_into().expect("16 bits computer?")
    }
}

/// Compute a delta between m1 an m2.
///
/// The delta is line aligned.
pub fn text_delta(m1: &[u8], m2: &[u8]) -> Vec<u8> {
    let mut delta = vec![];

    let prefix_size = lines_prefix_size_low(m1, m2);

    match (&m1[prefix_size..], &m2[prefix_size..]) {
        ([], []) => (),
        (m, []) => all_deleted(prefix_size, m, &mut delta),
        ([], m) => all_created(prefix_size, m, &mut delta),
        (sub_1, sub_2) => {
            text_delta_inner(prefix_size, sub_1, sub_2, &mut delta)
        }
    }
    delta
}

fn all_created(prefix_size: usize, content: &[u8], delta: &mut Vec<u8>) {
    let skip: u32 = prefix_size.try_into().expect("16 bits computer");
    Chunk { start: skip, end: skip, data: content }.write(delta)
}

fn all_deleted(prefix_size: usize, deleted: &[u8], delta: &mut Vec<u8>) {
    let skip: u32 = prefix_size.try_into().expect("16 bits computer");
    let deleted_size: u32 = deleted.len().try_into().expect("16 bits computer");

    Chunk { start: skip, end: skip + deleted_size, data: &[] }.write(delta)
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
    let skip: u32 = prefix_size.try_into().expect("16 bits computer");
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
                c.into_chunk().write(delta);
                DeltaCursor::new(start, end, content_start, content_end, m2)
            }
        } else {
            DeltaCursor::new(start, end, content_start, content_end, m2)
        });
    }
    if let Some(last) = cursor {
        last.into_chunk().write(delta)
    }
}
