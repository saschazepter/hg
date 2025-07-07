//! This module contains code to understand and process deltas used by Mercurial

/// Size of a patch header piece
const HP_SIZE: usize = size_of::<i32>();
/// Size of a patch header (start, old_end, size)
const H_SIZE: usize = HP_SIZE * 3;

/// A piece of delta that replace a section of the base by another piece of
/// data.
#[derive(Copy, Clone, Debug, PartialEq)]
struct DeltaPiece {
    start: i32,
    old_end: i32,
    size: i32,
}

impl DeltaPiece {
    /// return a new version of this DeltaPiece move by <offset> bytes
    ///
    /// This is used when adjusting a delta to the change made by another one
    pub fn offsetted(&self, offset: i32) -> Self {
        if offset == 0 {
            return *self;
        }
        assert!(
            0 <= (self.start + offset),
            "start: {}, offset: {}",
            self.start,
            offset
        );

        Self {
            start: self.start + offset,
            old_end: self.old_end + offset,
            size: self.size,
        }
    }

    /// the amount of bytes content after this DeltaPiece get shifted.
    pub fn offset(&self) -> i32 {
        (self.start + self.size) - self.old_end
    }

    /// return a new version of this DeltaPiece, removing the <amount> first
    /// bytes change to the base.
    pub fn truncated(&self, amount: i32) -> Self {
        assert!(amount < (self.old_end - self.start));
        DeltaPiece {
            start: self.start + amount,
            old_end: self.old_end,
            size: self.size - amount.min(self.size),
        }
    }
}

/// estimate an upper bound of a delta combining and equivalement range
pub fn estimate_combined_deltas_size(deltas: Vec<&[u8]>) -> usize {
    assert!(deltas.len() > 1);
    let mut high_delta = vec![];
    let mut low_delta = vec![];
    let mut folded_delta = vec![];
    let base_data = deltas.last().expect("can't be empty");
    let mut combined_size = chunk_to_delta(&mut high_delta, base_data);
    for idx in (0..deltas.len() - 1).rev() {
        low_delta.clear();
        chunk_to_delta(&mut low_delta, deltas[idx]);
        combined_size = fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        std::mem::swap(&mut high_delta, &mut folded_delta);
    }
    combined_size
}

/// Combine two delta into a new delta
///
/// The `bottom_delta` should be the earlier delta in the chain, the
/// `top_delta` object applying over it.
/// This produce a new delta that would result in `top_delta` content when
/// applied on `bottom_delta` base.
///
///    input:  A --[bottom_delta]--> B --[top_delta]-->C
///    output: A --[folded]--> C
///
/// Resulting delta is always "correct", but there is some case where is it not
/// "minimal"
///
/// For example, if a line is reverted to a previous content (A → B → A),
/// folding the two last patch would result in a patch requesting an unecessary
/// replacement of the line with "A".
fn fold_deltas(
    bottom_delta: &[DeltaPiece],
    top_delta: &[DeltaPiece],
    folded_delta: &mut Vec<DeltaPiece>,
) -> usize {
    assert!(folded_delta.is_empty());
    // The amount of bytes added or removed by content from "bottom" so far
    //
    // This value needs to be substracted to "top" patches "start" to compute
    // the "start" position in "base" (and, therefor, how they need to be
    // represented in "folded")
    //
    // When the "bottom" patch:
    // - add N extra bytes of content compared the "base", it goes up by N
    // - remove N bytes of content compared the "base", it goes down by N
    //
    // For a patch "b" from bottom:
    //   - start of the resulting area in B is b.start + offset_top_bottom
    //   - end of the resulting area in B is b.start + b.size +
    //     offset_top_bottom
    //
    // For a patch "t" from top:
    //   - start of the replaced area in A is t.start - offset_top_bottom
    //   - end of the replaced area in A is t.old_end - offset_top_bottom
    let mut offset_top_bottom: i32 = 0;

    // Hold temporary "truncated" value
    let mut tmp_bottom: DeltaPiece;
    let mut tmp_top: DeltaPiece;

    // patches from the bottom delta
    let mut bottom_iter = bottom_delta.iter();
    let mut bottom = bottom_iter.next();

    // patches from the top delta
    let mut top_iter = top_delta.iter();
    let mut top = top_iter.next();

    while bottom.is_some() || top.is_some() {
        match (bottom, top) {
            // only patches from bottom remains, add them to the result
            (Some(bot), None) => {
                folded_delta.push(*bot);
                for p in bottom_iter {
                    folded_delta.push(*p);
                }
                break;
            }
            // only patches from top remains, add them to the result
            (None, Some(t)) => {
                folded_delta.push(t.offsetted(-offset_top_bottom));
                for p in top_iter {
                    folded_delta.push(p.offsetted(-offset_top_bottom));
                }
                break;
            }
            (Some(bot), Some(t))
                if (bot.start + bot.size) < (t.start - offset_top_bottom) =>
            {
                folded_delta.push(*bot);
                offset_top_bottom += bot.offset();
                bottom = bottom_iter.next();
            }
            (Some(bot), Some(t))
                if (t.old_end - offset_top_bottom) < bot.start =>
            {
                folded_delta.push(t.offsetted(-offset_top_bottom));
                top = top_iter.next();
            }
            (Some(bot), Some(t)) => {
                // There is some overlap between the next patch in "bottom" and
                // the next patch in "top" and they need to be merged.

                // start with a zero size area from the first patch
                let start_a = bot.start.min(t.start - offset_top_bottom);
                let mut end_a = start_a;

                // check content offset from each layer
                //
                // We don't consume the initial patch yet, as consuming them is
                // no different than consuming the subsequent one.
                let mut local_offset_from_bottom = 0;
                let mut local_offset_from_top = 0;

                // We look for successive patches in either list the overlap
                // with the current one, and merge them (extend end points and
                // adapt offsets)

                loop {
                    let (current_bottom, current_top) = match (bottom, top) {
                        (None, None) => break,
                        (Some(_), None) => {
                            while match bottom {
                                None => false,
                                Some(b) => b.start <= end_a,
                            } {
                                let b = bottom.unwrap();
                                end_a = end_a.max(b.old_end);
                                local_offset_from_bottom += b.offset();
                                bottom = bottom_iter.next();
                            }
                            break;
                        }
                        (None, Some(_)) => {
                            let local_offset =
                                offset_top_bottom + local_offset_from_bottom;
                            while match top {
                                None => false,
                                Some(t) => t.start - local_offset <= end_a,
                            } {
                                let t = top.unwrap();
                                end_a = end_a.max(t.old_end - local_offset);
                                local_offset_from_top += t.offset();
                                top = top_iter.next();
                            }
                            break;
                        }
                        (Some(bot), Some(top)) => (bot, top),
                    };

                    let start_bottom = current_bottom.start;
                    let start_top = current_top.start
                        - offset_top_bottom
                        - local_offset_from_bottom;

                    if start_bottom > end_a && start_top > end_a {
                        // No remaining overlap, go to conclusion of this merge
                        break;
                    }

                    // check if any patch is ahead of the other and by how
                    // much.
                    //
                    // If one is ahead of the other, we process it first.
                    // Either by consuming it entirely if
                    // there is no overlap with the
                    // next one, or by processing the part ahead.
                    //
                    // If the two patch start at the same level, consume the
                    // one contained in the other
                    match start_bottom - start_top {
                        rd if rd < 0 => {
                            let d = -rd;
                            let size_a =
                                current_bottom.old_end - current_bottom.start;
                            if size_a <= d {
                                // "top" does not overlap with the current
                                // patch, merge wholly
                                end_a = end_a.max(current_bottom.old_end);
                                local_offset_from_bottom +=
                                    current_bottom.offset();
                                bottom = bottom_iter.next();
                            } else {
                                // truncate the start to align it with the
                                // other one
                                end_a += d;
                                local_offset_from_bottom +=
                                    0.min(current_bottom.size - d);
                                tmp_bottom = current_bottom.truncated(d);
                                bottom = Some(&tmp_bottom);
                            }
                        }
                        d if d > 0 => {
                            let size_b =
                                current_top.old_end - current_top.start;
                            if size_b <= d {
                                // "bottom" patch does not overlap with the
                                // current patch, merge wholly
                                end_a = end_a.max(
                                    current_top.old_end
                                        - offset_top_bottom
                                        - local_offset_from_bottom,
                                );
                                local_offset_from_top += current_top.offset();
                                top = top_iter.next();
                            } else {
                                // truncate the current "top" patch top align
                                // it with the "bottom" one
                                end_a += d;
                                local_offset_from_top +=
                                    0.min(current_top.size - d);
                                tmp_top = current_top.truncated(d);
                                top = Some(&tmp_top);
                            }
                        }
                        _ => {
                            debug_assert_eq!(start_bottom, start_top);
                            // Check if the "top" patch only replace "bottom"
                            // content
                            let size_b =
                                current_top.old_end - current_top.start;
                            if size_b <= current_bottom.size {
                                // "top" only replace bottom content, adjust
                                // the
                                // final patch size and rely on "bottom" to
                                // update
                                // the `end_a` value.
                                local_offset_from_top += current_top.offset();
                                top = top_iter.next();
                            } else {
                                // "top" replace more that the current "bottom"
                                // data,
                                // truncate the part associated with that
                                // "bottom"
                                // patch and consume it.
                                local_offset_from_top += 0.min(
                                    current_top.size - current_bottom.size,
                                );
                                tmp_top =
                                    current_top.truncated(current_bottom.size);
                                top = Some(&tmp_top);

                                // consume the "bottom" patch
                                end_a += current_bottom.old_end
                                    - current_bottom.start;
                                local_offset_from_bottom +=
                                    current_bottom.offset();
                                bottom = bottom_iter.next();
                            }
                        }
                    };
                }
                // all contiguous patches are now merged, we can register
                // this patch coordinates are relative
                // to A, the size is relative to C
                let size = end_a - start_a
                    + local_offset_from_top
                    + local_offset_from_bottom;
                folded_delta.push(DeltaPiece {
                    start: start_a,
                    old_end: end_a,
                    size,
                });
                offset_top_bottom += local_offset_from_bottom;
            }
            _ => unreachable!(),
        }
    }
    folded_delta.iter().map(|p| (p.size as usize) + H_SIZE).sum()
}

/// Parse a binary chunk into a Delta
///
/// return the storage size of the parsed delta
/// (which should be the size of `chunk` anyway)
fn chunk_to_delta(delta: &mut Vec<DeltaPiece>, chunk: &[u8]) -> usize {
    assert!(delta.is_empty());
    let mut offset = 0;
    let mut delta_size = 0;

    while (offset + H_SIZE) <= chunk.len() {
        let start = i32::from_be_bytes(
            chunk[offset..offset + HP_SIZE].try_into().unwrap(),
        );
        offset += HP_SIZE;
        let old_end = i32::from_be_bytes(
            chunk[offset..offset + HP_SIZE].try_into().unwrap(),
        );
        offset += HP_SIZE;
        let size = i32::from_be_bytes(
            chunk[offset..offset + HP_SIZE].try_into().unwrap(),
        );
        offset += HP_SIZE;
        if start < 0
            || old_end < 0
            || start > old_end
            || size < 0
            || (offset + size as usize) > chunk.len()
        {
            // inconsistent patch ‽
            break;
        }
        delta.push(DeltaPiece { start, old_end, size });
        delta_size = delta_size + H_SIZE + size as usize;
        offset += size as usize;
    }
    assert!(chunk.len() == delta_size);
    delta_size
}

#[cfg(test)]
mod tests {

    use super::*;

    fn delta_size(delta: &[DeltaPiece]) -> usize {
        delta.iter().map(|p| p.size as usize + H_SIZE).sum()
    }

    /// Check that two disjoint patch does not get merged
    ///
    /// (with patches not doing any offsets)
    #[test]
    fn test_disjoint_patches() {
        let low_delta = vec![DeltaPiece { start: 0, old_end: 10, size: 10 }];
        let high_delta = vec![DeltaPiece { start: 20, old_end: 30, size: 10 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 22);
        assert_eq!(delta_size(&high_delta), 22);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(delta_size(&folded_delta), 44);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 0, old_end: 10, size: 10 },
                DeltaPiece { start: 20, old_end: 30, size: 10 },
            ]
        )
    }

    /// Check that two consecutive patch do get merged
    ///
    /// (with patches not doing any offsets)
    #[test]
    fn test_consecutive_patches() {
        let low_delta = vec![DeltaPiece { start: 0, old_end: 10, size: 10 }];
        let high_delta = vec![DeltaPiece { start: 10, old_end: 20, size: 10 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 22);
        assert_eq!(delta_size(&high_delta), 22);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(delta_size(&folded_delta), 32);
        assert_eq!(
            folded_delta,
            vec![DeltaPiece { start: 0, old_end: 20, size: 20 },]
        )
    }

    /// Merging overlaping patches
    ///
    /// (without offset)
    #[test]
    fn test_overlapping_patches() {
        let low_delta = vec![DeltaPiece { start: 0, old_end: 10, size: 10 }];
        let high_delta = vec![DeltaPiece { start: 5, old_end: 15, size: 10 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 22);
        assert_eq!(delta_size(&high_delta), 22);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(delta_size(&folded_delta), 27);
        assert_eq!(
            folded_delta,
            vec![DeltaPiece { start: 0, old_end: 15, size: 15 },]
        )
    }

    ///  Merging a chain of overlapping patches
    ///
    /// (without offsets)
    #[test]
    fn test_overlapping_chain_or_patches() {
        let low_delta = vec![
            DeltaPiece { start: 0, old_end: 10, size: 10 },
            DeltaPiece { start: 15, old_end: 25, size: 10 },
            DeltaPiece { start: 30, old_end: 40, size: 10 },
        ];
        let high_delta = vec![
            DeltaPiece { start: 8, old_end: 18, size: 10 },
            DeltaPiece { start: 23, old_end: 33, size: 10 },
        ];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 66);
        assert_eq!(delta_size(&high_delta), 44);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![DeltaPiece { start: 0, old_end: 40, size: 40 },]
        );
        assert_eq!(delta_size(&folded_delta), 52);
    }

    /// Merge patch that are super set of the others
    ///
    /// ()
    #[test]
    fn test_superset_patches() {
        let low_delta = vec![
            DeltaPiece { start: 0, old_end: 30, size: 30 },
            DeltaPiece { start: 50, old_end: 60, size: 10 },
        ];
        let high_delta = vec![
            DeltaPiece { start: 10, old_end: 20, size: 10 },
            DeltaPiece { start: 40, old_end: 70, size: 30 },
        ];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 64);
        assert_eq!(delta_size(&high_delta), 64);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 0, old_end: 30, size: 30 },
                DeltaPiece { start: 40, old_end: 70, size: 30 },
            ]
        );
        assert_eq!(delta_size(&folded_delta), 84);
    }

    /// Disjoint patches
    ///
    /// (with offsets)
    #[test]
    fn test_disjoint_patches_offsets() {
        let low_delta = vec![DeltaPiece { start: 0, old_end: 10, size: 5 }];
        let high_delta = vec![DeltaPiece { start: 10, old_end: 15, size: 10 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 17);
        assert_eq!(delta_size(&high_delta), 22);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 0, old_end: 10, size: 5 },
                DeltaPiece { start: 15, old_end: 20, size: 10 },
            ]
        );
        assert_eq!(delta_size(&folded_delta), 39);
    }

    /// Merge consecutive patches with offsets
    ///
    /// (with offsets)
    #[test]
    fn test_consecutive_patches_offsets() {
        let low_delta = vec![DeltaPiece { start: 0, old_end: 10, size: 15 }];
        let high_delta = vec![DeltaPiece { start: 15, old_end: 20, size: 7 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 27);
        assert_eq!(delta_size(&high_delta), 19);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![DeltaPiece { start: 0, old_end: 15, size: 22 },]
        );
        assert_eq!(delta_size(&folded_delta), 34);
    }

    /// Merge overlapping patches
    ///
    /// (with offsets)
    #[test]
    fn test_overlapping_patches_offsets() {
        let low_delta = vec![DeltaPiece { start: 10, old_end: 20, size: 20 }];
        let high_delta = vec![DeltaPiece { start: 25, old_end: 35, size: 3 }];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 32);
        assert_eq!(delta_size(&high_delta), 15);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![DeltaPiece { start: 10, old_end: 25, size: 18 },]
        );
        assert_eq!(delta_size(&folded_delta), 30);
    }

    /// Merge chain of patches
    ///
    /// (with offsets)
    #[test]
    fn test_overlapping_chain_of_patches_offsets() {
        let low_delta = vec![
            DeltaPiece { start: 0, old_end: 0, size: 5 },
            DeltaPiece { start: 5, old_end: 10, size: 15 },
            DeltaPiece { start: 15, old_end: 20, size: 0 },
            DeltaPiece { start: 30, old_end: 35, size: 15 },
            DeltaPiece { start: 40, old_end: 80, size: 10 },
        ];
        let high_delta = vec![
            DeltaPiece { start: 18, old_end: 45, size: 5 },
            DeltaPiece { start: 50, old_end: 65, size: 30 },
            DeltaPiece { start: 75, old_end: 75, size: 5 },
        ];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 105);
        assert_eq!(delta_size(&high_delta), 76);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 0, old_end: 0, size: 5 },
                DeltaPiece { start: 5, old_end: 82, size: 55 },
                DeltaPiece { start: 85, old_end: 85, size: 5 },
            ]
        );
        assert_eq!(delta_size(&folded_delta), 101);
    }

    /// Merge patches that are superset of others
    ///
    /// (with offsets)
    #[test]
    fn test_superset_patches_offsets() {
        let low_delta = vec![
            DeltaPiece { start: 5, old_end: 10, size: 15 },
            DeltaPiece { start: 20, old_end: 50, size: 10 },
            DeltaPiece { start: 80, old_end: 90, size: 40 },
        ];
        let high_delta = vec![
            DeltaPiece { start: 33, old_end: 38, size: 65 },
            DeltaPiece { start: 65, old_end: 120, size: 10 },
            DeltaPiece { start: 150, old_end: 200, size: 66 },
        ];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 101);
        assert_eq!(delta_size(&high_delta), 177);

        fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 5, old_end: 10, size: 15 },
                DeltaPiece { start: 20, old_end: 50, size: 70 },
                DeltaPiece { start: 75, old_end: 100, size: 10 },
                DeltaPiece { start: 130, old_end: 180, size: 66 },
            ]
        );
        assert_eq!(delta_size(&folded_delta), 209);
    }

    /// A large test coming from an error in the .t
    #[test]
    fn test_large() {
        let low_delta = vec![
            DeltaPiece { start: 0, old_end: 1651, size: 1652 },
            DeltaPiece { start: 9868, old_end: 9901, size: 33 },
            DeltaPiece { start: 19768, old_end: 19801, size: 33 },
            DeltaPiece { start: 29668, old_end: 29701, size: 33 },
            DeltaPiece { start: 39568, old_end: 39601, size: 33 },
            DeltaPiece { start: 49468, old_end: 49501, size: 33 },
            DeltaPiece { start: 59368, old_end: 59401, size: 33 },
            DeltaPiece { start: 69268, old_end: 69301, size: 33 },
            DeltaPiece { start: 79168, old_end: 79201, size: 33 },
            DeltaPiece { start: 89068, old_end: 89101, size: 33 },
            DeltaPiece { start: 98968, old_end: 99001, size: 33 },
            DeltaPiece { start: 108868, old_end: 108901, size: 33 },
            DeltaPiece { start: 118768, old_end: 118801, size: 33 },
            DeltaPiece { start: 128668, old_end: 128701, size: 33 },
            DeltaPiece { start: 138568, old_end: 138601, size: 33 },
            DeltaPiece { start: 148468, old_end: 148501, size: 33 },
            DeltaPiece { start: 158368, old_end: 158401, size: 33 },
            DeltaPiece { start: 168268, old_end: 168301, size: 33 },
            DeltaPiece { start: 178168, old_end: 178201, size: 33 },
            DeltaPiece { start: 188068, old_end: 188101, size: 33 },
            DeltaPiece { start: 197968, old_end: 198001, size: 33 },
            DeltaPiece { start: 207868, old_end: 207901, size: 33 },
            DeltaPiece { start: 217768, old_end: 217801, size: 33 },
            DeltaPiece { start: 227668, old_end: 227701, size: 33 },
            DeltaPiece { start: 237568, old_end: 237601, size: 33 },
            DeltaPiece { start: 247468, old_end: 247501, size: 33 },
            DeltaPiece { start: 257368, old_end: 257401, size: 33 },
            DeltaPiece { start: 267268, old_end: 267301, size: 33 },
            DeltaPiece { start: 277168, old_end: 277201, size: 33 },
            DeltaPiece { start: 287068, old_end: 287101, size: 33 },
            DeltaPiece { start: 296968, old_end: 297001, size: 33 },
            DeltaPiece { start: 306868, old_end: 306901, size: 33 },
            DeltaPiece { start: 316768, old_end: 316801, size: 33 },
            DeltaPiece { start: 326668, old_end: 326701, size: 33 },
            DeltaPiece { start: 336568, old_end: 336601, size: 33 },
        ];
        let high_delta = vec![
            DeltaPiece { start: 0, old_end: 1652, size: 1652 },
            DeltaPiece { start: 9869, old_end: 9902, size: 33 },
            DeltaPiece { start: 29669, old_end: 29702, size: 33 },
            DeltaPiece { start: 49469, old_end: 49502, size: 33 },
            DeltaPiece { start: 59369, old_end: 59402, size: 33 },
            DeltaPiece { start: 69269, old_end: 69302, size: 33 },
            DeltaPiece { start: 69335, old_end: 69368, size: 33 },
            DeltaPiece { start: 79169, old_end: 79202, size: 33 },
            DeltaPiece { start: 98969, old_end: 99002, size: 33 },
            DeltaPiece { start: 108869, old_end: 108902, size: 33 },
            DeltaPiece { start: 118769, old_end: 118802, size: 33 },
            DeltaPiece { start: 138569, old_end: 138602, size: 33 },
            DeltaPiece { start: 158369, old_end: 158402, size: 33 },
            DeltaPiece { start: 168269, old_end: 168302, size: 33 },
            DeltaPiece { start: 178169, old_end: 178202, size: 33 },
            DeltaPiece { start: 178235, old_end: 178268, size: 33 },
            DeltaPiece { start: 188069, old_end: 188102, size: 33 },
            DeltaPiece { start: 207869, old_end: 207902, size: 33 },
            DeltaPiece { start: 217769, old_end: 217802, size: 33 },
            DeltaPiece { start: 227669, old_end: 227702, size: 33 },
            DeltaPiece { start: 247469, old_end: 247502, size: 33 },
            DeltaPiece { start: 267269, old_end: 267302, size: 33 },
            DeltaPiece { start: 277169, old_end: 277202, size: 33 },
            DeltaPiece { start: 287069, old_end: 287102, size: 33 },
            DeltaPiece { start: 287135, old_end: 287168, size: 33 },
            DeltaPiece { start: 296969, old_end: 297002, size: 33 },
            DeltaPiece { start: 316769, old_end: 316802, size: 33 },
            DeltaPiece { start: 326669, old_end: 326702, size: 33 },
            DeltaPiece { start: 336569, old_end: 336602, size: 33 },
        ];
        let mut folded_delta = vec![];

        assert_eq!(delta_size(&low_delta), 3194);
        assert_eq!(delta_size(&high_delta), 2924);

        let size = fold_deltas(&low_delta, &high_delta, &mut folded_delta);
        assert_eq!(
            folded_delta,
            vec![
                DeltaPiece { start: 0, old_end: 1651, size: 1652 },
                DeltaPiece { start: 9868, old_end: 9901, size: 33 },
                DeltaPiece { start: 19768, old_end: 19801, size: 33 },
                DeltaPiece { start: 29668, old_end: 29701, size: 33 },
                DeltaPiece { start: 39568, old_end: 39601, size: 33 },
                DeltaPiece { start: 49468, old_end: 49501, size: 33 },
                DeltaPiece { start: 59368, old_end: 59401, size: 33 },
                DeltaPiece { start: 69268, old_end: 69301, size: 33 },
                DeltaPiece { start: 69334, old_end: 69367, size: 33 },
                DeltaPiece { start: 79168, old_end: 79201, size: 33 },
                DeltaPiece { start: 89068, old_end: 89101, size: 33 },
                DeltaPiece { start: 98968, old_end: 99001, size: 33 },
                DeltaPiece { start: 108868, old_end: 108901, size: 33 },
                DeltaPiece { start: 118768, old_end: 118801, size: 33 },
                DeltaPiece { start: 128668, old_end: 128701, size: 33 },
                DeltaPiece { start: 138568, old_end: 138601, size: 33 },
                DeltaPiece { start: 148468, old_end: 148501, size: 33 },
                DeltaPiece { start: 158368, old_end: 158401, size: 33 },
                DeltaPiece { start: 168268, old_end: 168301, size: 33 },
                DeltaPiece { start: 178168, old_end: 178201, size: 33 },
                DeltaPiece { start: 178234, old_end: 178267, size: 33 },
                DeltaPiece { start: 188068, old_end: 188101, size: 33 },
                DeltaPiece { start: 197968, old_end: 198001, size: 33 },
                DeltaPiece { start: 207868, old_end: 207901, size: 33 },
                DeltaPiece { start: 217768, old_end: 217801, size: 33 },
                DeltaPiece { start: 227668, old_end: 227701, size: 33 },
                DeltaPiece { start: 237568, old_end: 237601, size: 33 },
                DeltaPiece { start: 247468, old_end: 247501, size: 33 },
                DeltaPiece { start: 257368, old_end: 257401, size: 33 },
                DeltaPiece { start: 267268, old_end: 267301, size: 33 },
                DeltaPiece { start: 277168, old_end: 277201, size: 33 },
                DeltaPiece { start: 287068, old_end: 287101, size: 33 },
                DeltaPiece { start: 287134, old_end: 287167, size: 33 },
                DeltaPiece { start: 296968, old_end: 297001, size: 33 },
                DeltaPiece { start: 306868, old_end: 306901, size: 33 },
                DeltaPiece { start: 316768, old_end: 316801, size: 33 },
                DeltaPiece { start: 326668, old_end: 326701, size: 33 },
                DeltaPiece { start: 336568, old_end: 336601, size: 33 },
            ]
        );
        assert_eq!(delta_size(&folded_delta), 3329);
        assert_eq!(delta_size(&folded_delta), size);
    }
}
