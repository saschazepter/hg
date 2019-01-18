// Copyright 2018 Georges Racinet <gracinet@anybox.fr>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Bindings for CPython extension code
//!
//! This exposes methods to build and use a `rustlazyancestors` iterator
//! from C code, using an index and its parents function that are passed
//! from the caller at instantiation.

use hg::AncestorsIterator;
use hg::{Graph, GraphError, Revision, NULL_REVISION};
use libc::{c_int, c_long, c_void, ssize_t};
use std::ptr::null_mut;
use std::slice;

type IndexPtr = *mut c_void;

extern "C" {
    fn HgRevlogIndex_GetParents(
        op: IndexPtr,
        rev: c_int,
        parents: *mut [c_int; 2],
    ) -> c_int;
}

/// A Graph backed up by objects and functions from revlog.c
///
/// This implementation of the Graph trait, relies on (pointers to)
/// - the C index object (`index` member)
/// - the `index_get_parents()` function (`parents` member)
pub struct Index {
    index: IndexPtr,
}

impl Index {
    pub fn new(index: IndexPtr) -> Self {
        Index {
            index: index,
        }
    }
}

impl Graph for Index {
    /// wrap a call to the C extern parents function
    fn parents(&self, rev: Revision) -> Result<[Revision; 2], GraphError> {
        let mut res: [c_int; 2] = [0; 2];
        let code =
            unsafe { HgRevlogIndex_GetParents(self.index, rev, &mut res as *mut [c_int; 2]) };
        match code {
            0 => Ok(res),
            _ => Err(GraphError::ParentOutOfRange(rev)),
        }
    }
}

/// Wrapping of AncestorsIterator<Index> constructor, for C callers.
///
/// Besides `initrevs`, `stoprev` and `inclusive`, that are converted
/// we receive the index and the parents function as pointers
#[no_mangle]
pub extern "C" fn rustlazyancestors_init(
    index: IndexPtr,
    initrevslen: ssize_t,
    initrevs: *mut c_long,
    stoprev: c_long,
    inclusive: c_int,
) -> *mut AncestorsIterator<Index> {
    assert!(initrevslen >= 0);
    unsafe {
        raw_init(
            Index::new(index),
            initrevslen as usize,
            initrevs,
            stoprev,
            inclusive,
        )
    }
}

/// Testable (for any Graph) version of rustlazyancestors_init
#[inline]
unsafe fn raw_init<G: Graph>(
    graph: G,
    initrevslen: usize,
    initrevs: *mut c_long,
    stoprev: c_long,
    inclusive: c_int,
) -> *mut AncestorsIterator<G> {
    let inclb = match inclusive {
        0 => false,
        1 => true,
        _ => {
            return null_mut();
        }
    };

    let slice = slice::from_raw_parts(initrevs, initrevslen);

    Box::into_raw(Box::new(match AncestorsIterator::new(
        graph,
        slice.into_iter().map(|&r| r as Revision),
        stoprev as Revision,
        inclb,
    ) {
        Ok(it) => it,
        Err(_) => {
            return null_mut();
        }
    }))
}

/// Deallocator to be called from C code
#[no_mangle]
pub extern "C" fn rustlazyancestors_drop(raw_iter: *mut AncestorsIterator<Index>) {
    raw_drop(raw_iter);
}

/// Testable (for any Graph) version of rustlazayancestors_drop
#[inline]
fn raw_drop<G: Graph>(raw_iter: *mut AncestorsIterator<G>) {
    unsafe {
        Box::from_raw(raw_iter);
    }
}

/// Iteration main method to be called from C code
///
/// We convert the end of iteration into NULL_REVISION,
/// it will be up to the C wrapper to convert that back into a Python end of
/// iteration
#[no_mangle]
pub extern "C" fn rustlazyancestors_next(raw: *mut AncestorsIterator<Index>) -> c_long {
    raw_next(raw)
}

/// Testable (for any Graph) version of rustlazayancestors_next
#[inline]
fn raw_next<G: Graph>(raw: *mut AncestorsIterator<G>) -> c_long {
    let as_ref = unsafe { &mut *raw };
    let rev = match as_ref.next() {
        Some(Ok(rev)) => rev,
        Some(Err(_)) | None => NULL_REVISION,
    };
    rev as c_long
}

#[no_mangle]
pub extern "C" fn rustlazyancestors_contains(
    raw: *mut AncestorsIterator<Index>,
    target: c_long,
) -> c_int {
    raw_contains(raw, target)
}

/// Testable (for any Graph) version of rustlazayancestors_next
#[inline]
fn raw_contains<G: Graph>(
    raw: *mut AncestorsIterator<G>,
    target: c_long,
) -> c_int {
    let as_ref = unsafe { &mut *raw };
    match as_ref.contains(target as Revision) {
        Ok(r) => r as c_int,
        Err(_) => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[derive(Clone, Debug)]
    struct Stub;

    impl Graph for Stub {
        fn parents(&self, r: Revision) -> Result<[Revision; 2], GraphError> {
            match r {
                25 => Err(GraphError::ParentOutOfRange(25)),
                _ => Ok([1, 2]),
            }
        }
    }

    /// Helper for test_init_next()
    fn stub_raw_init(
        initrevslen: usize,
        initrevs: usize,
        stoprev: c_long,
        inclusive: c_int,
    ) -> usize {
        unsafe {
            raw_init(
                Stub,
                initrevslen,
                initrevs as *mut c_long,
                stoprev,
                inclusive,
            ) as usize
        }
    }

    fn stub_raw_init_from_vec(
        mut initrevs: Vec<c_long>,
        stoprev: c_long,
        inclusive: c_int,
    ) -> *mut AncestorsIterator<Stub> {
        unsafe {
            raw_init(
                Stub,
                initrevs.len(),
                initrevs.as_mut_ptr(),
                stoprev,
                inclusive,
            )
        }
    }

    #[test]
    // Test what happens when we init an Iterator as with the exposed C ABI
    // and try to use it afterwards
    // We spawn new threads, in order to make memory consistency harder
    // but this forces us to convert the pointers into shareable usizes.
    fn test_init_next() {
        let mut initrevs: Vec<c_long> = vec![11, 13];
        let initrevs_len = initrevs.len();
        let initrevs_ptr = initrevs.as_mut_ptr() as usize;
        let handler = thread::spawn(move || stub_raw_init(initrevs_len, initrevs_ptr, 0, 1));
        let raw = handler.join().unwrap() as *mut AncestorsIterator<Stub>;

        assert_eq!(raw_next(raw), 13);
        assert_eq!(raw_next(raw), 11);
        assert_eq!(raw_next(raw), 2);
        assert_eq!(raw_next(raw), 1);
        assert_eq!(raw_next(raw), NULL_REVISION as c_long);
        raw_drop(raw);
    }

    #[test]
    fn test_init_wrong_bool() {
        assert_eq!(stub_raw_init_from_vec(vec![11, 13], 0, 2), null_mut());
    }

    #[test]
    fn test_empty() {
        let raw = stub_raw_init_from_vec(vec![], 0, 1);
        assert_eq!(raw_next(raw), NULL_REVISION as c_long);
        raw_drop(raw);
    }

    #[test]
    fn test_init_err_out_of_range() {
        assert!(stub_raw_init_from_vec(vec![25], 0, 0).is_null());
    }

    #[test]
    fn test_contains() {
        let raw = stub_raw_init_from_vec(vec![5, 6], 0, 1);
        assert_eq!(raw_contains(raw, 5), 1);
        assert_eq!(raw_contains(raw, 2), 1);
    }

    #[test]
    fn test_contains_exclusive() {
        let raw = stub_raw_init_from_vec(vec![5, 6], 0, 0);
        assert_eq!(raw_contains(raw, 5), 0);
        assert_eq!(raw_contains(raw, 2), 1);
    }
}
