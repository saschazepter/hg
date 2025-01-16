// utils module
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Contains useful functions, traits, structs, etc. for use in core.

use crate::errors::{HgError, IoErrorContext};
use im_rc::ordmap::DiffItem;
use im_rc::ordmap::OrdMap;
use itertools::EitherOrBoth;
use itertools::Itertools;
use std::cmp::Ordering;

pub mod debug;
pub mod files;
pub mod hg_path;
pub mod path_auditor;
pub mod strings;

pub fn current_dir() -> Result<std::path::PathBuf, HgError> {
    std::env::current_dir().map_err(|error| HgError::IoError {
        error,
        context: IoErrorContext::CurrentDir,
    })
}

pub fn current_exe() -> Result<std::path::PathBuf, HgError> {
    std::env::current_exe().map_err(|error| HgError::IoError {
        error,
        context: IoErrorContext::CurrentExe,
    })
}

pub(crate) enum MergeResult<V> {
    Left,
    Right,
    New(V),
}

/// Return the union of the two given maps,
/// calling `merge(key, left_value, right_value)` to resolve keys that exist in
/// both.
///
/// CC <https://github.com/bodil/im-rs/issues/166>
pub(crate) fn ordmap_union_with_merge<K, V>(
    left: OrdMap<K, V>,
    right: OrdMap<K, V>,
    mut merge: impl FnMut(&K, &V, &V) -> MergeResult<V>,
) -> OrdMap<K, V>
where
    K: Clone + Ord,
    V: Clone + PartialEq,
{
    if left.ptr_eq(&right) {
        // One of the two maps is an unmodified clone of the other
        left
    } else if left.len() / 2 > right.len() {
        // When two maps have different sizes,
        // their size difference is a lower bound on
        // how many keys of the larger map are not also in the smaller map.
        // This in turn is a lower bound on the number of differences in
        // `OrdMap::diff` and the "amount of work" that would be done
        // by `ordmap_union_with_merge_by_diff`.
        //
        // Here `left` is more than twice the size of `right`,
        // so the number of differences is more than the total size of
        // `right`. Therefore an algorithm based on iterating `right`
        // is more efficient.
        //
        // This helps a lot when a tiny (or empty) map is merged
        // with a large one.
        ordmap_union_with_merge_by_iter(left, right, merge)
    } else if left.len() < right.len() / 2 {
        // Same as above but with `left` and `right` swapped
        ordmap_union_with_merge_by_iter(right, left, |key, a, b| {
            // Also swapped in `merge` arguments:
            match merge(key, b, a) {
                MergeResult::New(v) => MergeResult::New(v),
                // … and swap back in `merge` result:
                MergeResult::Left => MergeResult::Right,
                MergeResult::Right => MergeResult::Left,
            }
        })
    } else {
        // For maps of similar size, use the algorithm based on `OrdMap::diff`
        ordmap_union_with_merge_by_diff(left, right, merge)
    }
}

/// Efficient if `right` is much smaller than `left`
fn ordmap_union_with_merge_by_iter<K, V>(
    mut left: OrdMap<K, V>,
    right: OrdMap<K, V>,
    mut merge: impl FnMut(&K, &V, &V) -> MergeResult<V>,
) -> OrdMap<K, V>
where
    K: Clone + Ord,
    V: Clone,
{
    for (key, right_value) in right {
        match left.get(&key) {
            None => {
                left.insert(key, right_value);
            }
            Some(left_value) => match merge(&key, left_value, &right_value) {
                MergeResult::Left => {}
                MergeResult::Right => {
                    left.insert(key, right_value);
                }
                MergeResult::New(new_value) => {
                    left.insert(key, new_value);
                }
            },
        }
    }
    left
}

/// Fallback when both maps are of similar size
fn ordmap_union_with_merge_by_diff<K, V>(
    mut left: OrdMap<K, V>,
    mut right: OrdMap<K, V>,
    mut merge: impl FnMut(&K, &V, &V) -> MergeResult<V>,
) -> OrdMap<K, V>
where
    K: Clone + Ord,
    V: Clone + PartialEq,
{
    // (key, value) pairs that would need to be inserted in either map
    // in order to turn it into the union.
    //
    // TODO: if/when https://github.com/bodil/im-rs/pull/168 is accepted,
    // change these from `Vec<(K, V)>` to `Vec<(&K, Cow<V>)>`
    // with `left_updates` only borrowing from `right` and `right_updates` from
    // `left`, and with `Cow::Owned` used for `MergeResult::New`.
    //
    // This would allow moving all `.clone()` calls to after we’ve decided
    // which of `right_updates` or `left_updates` to use
    // (value ones becoming `Cow::into_owned`),
    // and avoid making clones we don’t end up using.
    let mut left_updates = Vec::new();
    let mut right_updates = Vec::new();

    for difference in left.diff(&right) {
        match difference {
            DiffItem::Add(key, value) => {
                left_updates.push((key.clone(), value.clone()))
            }
            DiffItem::Remove(key, value) => {
                right_updates.push((key.clone(), value.clone()))
            }
            DiffItem::Update {
                old: (key, left_value),
                new: (_, right_value),
            } => match merge(key, left_value, right_value) {
                MergeResult::Left => {
                    right_updates.push((key.clone(), left_value.clone()))
                }
                MergeResult::Right => {
                    left_updates.push((key.clone(), right_value.clone()))
                }
                MergeResult::New(new_value) => {
                    left_updates.push((key.clone(), new_value.clone()));
                    right_updates.push((key.clone(), new_value))
                }
            },
        }
    }
    if left_updates.len() < right_updates.len() {
        for (key, value) in left_updates {
            left.insert(key, value);
        }
        left
    } else {
        for (key, value) in right_updates {
            right.insert(key, value);
        }
        right
    }
}

/// Like `Iterator::filter_map`, but over a fallible iterator of `Result`s.
///
/// The callback is only called for incoming `Ok` values. Errors are passed
/// through as-is. In order to let it use the `?` operator the callback is
/// expected to return a `Result` of `Option`, instead of an `Option` of
/// `Result`.
pub fn filter_map_results<'a, I, F, A, B, E>(
    iter: I,
    f: F,
) -> impl Iterator<Item = Result<B, E>> + 'a
where
    I: Iterator<Item = Result<A, E>> + 'a,
    F: Fn(A) -> Result<Option<B>, E> + 'a,
{
    iter.filter_map(move |result| match result {
        Ok(node) => f(node).transpose(),
        Err(e) => Some(Err(e)),
    })
}

/// Like `itertools::merge_join_by`, but merges fallible iterators.
///
/// The callback is only used for Ok values. Errors are passed through as-is.
/// Errors compare less than Ok values, which makes the error handling
/// conservative.
pub fn merge_join_results_by<'a, I1, I2, F, A, B, E>(
    iter1: I1,
    iter2: I2,
    f: F,
) -> impl Iterator<Item = Result<EitherOrBoth<A, B>, E>> + 'a
where
    I1: Iterator<Item = Result<A, E>> + 'a,
    I2: Iterator<Item = Result<B, E>> + 'a,
    F: FnMut(&A, &B) -> Ordering + 'a,
{
    let mut g = f;
    iter1
        .merge_join_by(iter2, move |i1, i2| match i1 {
            Err(_) => Ordering::Less,
            Ok(i1) => match i2 {
                Err(_) => Ordering::Greater,
                Ok(i2) => g(i1, i2),
            },
        })
        .map(|result| match result {
            EitherOrBoth::Left(Err(e)) => Err(e),
            EitherOrBoth::Right(Err(e)) => Err(e),
            EitherOrBoth::Both(Err(e), _) => Err(e),
            EitherOrBoth::Both(_, Err(e)) => Err(e),
            EitherOrBoth::Left(Ok(v)) => Ok(EitherOrBoth::Left(v)),
            EitherOrBoth::Right(Ok(v)) => Ok(EitherOrBoth::Right(v)),
            EitherOrBoth::Both(Ok(v1), Ok(v2)) => {
                Ok(EitherOrBoth::Both(v1, v2))
            }
        })
}

/// Force the global rayon threadpool to not exceed 16 concurrent threads
/// unless the user has specified a value.
/// This is a stop-gap measure until we figure out why using more than 16
/// threads makes `status` and `update` slower for each additional thread.
///
/// TODO find the underlying cause and fix it, then remove this.
///
/// # Errors
///
/// Returns an error if the global threadpool has already been initialized if
/// we try to initialize it.
pub fn cap_default_rayon_threads() -> Result<(), rayon::ThreadPoolBuildError> {
    const THREAD_CAP: usize = 16;

    if std::env::var("RAYON_NUM_THREADS").is_err() {
        let available_parallelism = std::thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(1);
        let new_thread_count = THREAD_CAP.min(available_parallelism);
        let res = rayon::ThreadPoolBuilder::new()
            .num_threads(new_thread_count)
            .build_global();
        if res.is_ok() {
            log::trace!(
                "Capped the rayon threadpool to {new_thread_count} threads",
            );
        }
        return res;
    }
    Ok(())
}
