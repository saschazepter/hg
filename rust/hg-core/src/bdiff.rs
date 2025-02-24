//! Safe bindings to bdiff.c.

use crate::errors::HgError;
use std::marker::PhantomData;

/// A file split into lines, ready for diffing.
pub struct Lines<'a> {
    /// The array of lines, allocated by bdiff.c.
    /// Must never be mutated by Rust code apart from freeing it in `Drop`.
    array: *mut ffi::bdiff_line,
    /// Length of the array.
    len: u32,
    /// Lifetime of the source buffer, since array items store pointers.
    _lifetime: PhantomData<&'a [u8]>,
}

/// Splits `source` into lines that can be diffed.
pub fn split_lines(source: &[u8]) -> Result<Lines, HgError> {
    let mut array = std::ptr::null_mut();
    // Safety: The pointer and length are valid since they both come from
    // `source`, and the out pointer is non-null.
    let result = unsafe {
        ffi::bdiff_splitlines(
            source.as_ptr() as *const std::ffi::c_char,
            source.len() as isize,
            &mut array,
        )
    };
    match u32::try_from(result) {
        Ok(len) => {
            assert!(!array.is_null());
            Ok(Lines {
                array,
                len,
                _lifetime: PhantomData,
            })
        }
        Err(_) => {
            Err(HgError::abort_simple("bdiff_splitlines failed to allocate"))
        }
    }
}

impl<'a> Lines<'a> {
    /// Returns the number of lines.
    pub fn len(&self) -> usize {
        self.len as usize
    }

    /// Returns an iterator over the lines.
    pub fn iter(&self) -> LinesIter<'_, 'a> {
        LinesIter {
            lines: self,
            index: 0,
        }
    }
}

impl Drop for Lines<'_> {
    fn drop(&mut self) {
        // Safety: This is the only place that frees the array (no
        // double-free), and it's in a `Drop` impl (no use-after-free).
        unsafe {
            libc::free(self.array as *mut std::ffi::c_void);
        }
    }
}

// Safety: It is safe to send `Lines` to a different thread because
// `self.array` is never copied so only one thread will free it.
unsafe impl Send for Lines<'_> {}

// It is *not* safe to share `&Lines` between threads because `ffi::bdiff_diff`
// mutates lines by storing bookkeeping information in `n` and `e`.
static_assertions_next::assert_impl!(Lines<'_>: !Sync);

#[derive(Clone)]
pub struct LinesIter<'a, 'b> {
    lines: &'a Lines<'b>,
    index: usize,
}

impl<'b> Iterator for LinesIter<'_, 'b> {
    type Item = &'b [u8];

    fn next(&mut self) -> Option<Self::Item> {
        if self.index == self.lines.len() {
            return None;
        }
        // Safety: We just checked that the index has not reached the length.
        let line = unsafe { *self.lines.array.add(self.index) };
        self.index += 1;
        // Safety: We assume bdiff.c sets `l` and `len` correctly.
        Some(unsafe {
            std::slice::from_raw_parts(line.l as *const u8, line.len as usize)
        })
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let len = self.lines.len() - self.index;
        (len, Some(len))
    }
}

impl ExactSizeIterator for LinesIter<'_, '_> {}

/// A diff hunk comparing lines [a1,a2) in file A with lines [b1,b2) in file B.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Hunk {
    /// Start line index in file A (inclusive).
    pub a1: u32,
    /// End line index in file A (exclusive).
    pub a2: u32,
    /// Start line index in file B (inclusive).
    pub b1: u32,
    /// End line index in file B (exclusive).
    pub b2: u32,
}

/// A list of matching hunks.
pub struct HunkList {
    /// The head of the linked list, allocated by bdiff.c.
    head: *mut ffi::bdiff_hunk,
    /// Length of the list.
    len: u32,
}

/// Returns a list of hunks that match in `a` and `b`.
pub fn diff(a: &Lines, b: &Lines) -> Result<HunkList, HgError> {
    let mut out = ffi::bdiff_hunk {
        a1: 0,
        a2: 0,
        b1: 0,
        b2: 0,
        next: std::ptr::null_mut(),
    };
    // Safety: We assume bdiff.c sets `array` and `len` correctly; and the
    // out pointer is non-null.
    let result = unsafe {
        ffi::bdiff_diff(a.array, a.len as i32, b.array, b.len as i32, &mut out)
    };
    match u32::try_from(result) {
        Ok(len) => Ok(HunkList {
            // Start with out.next because the first hunk is not meaningful and
            // is not included in len. This matches mercurial/cffi/bdiff.py.
            head: out.next,
            len,
        }),
        Err(_) => Err(HgError::abort_simple("bdiff_diff failed to allocate")),
    }
}

impl HunkList {
    /// Returns the number of hunks.
    pub fn len(&self) -> usize {
        self.len as usize
    }

    /// Returns an iterator over the hunks.
    pub fn iter(&self) -> HunkListIter {
        HunkListIter {
            // Safety: If `self.head` is null, this is safe. If non-null, then:
            // - We assume bdiff.c made it properly aligned.
            // - It's dereferenceable (any bit pattern is ok for `bdiff_hunk`).
            // - It won't be mutated because `HunkListIter` is tied to `&self`.
            next: unsafe { self.head.as_ref() },
            remaining: self.len(),
        }
    }
}

impl Drop for HunkList {
    fn drop(&mut self) {
        // Safety: This is the only place that frees `self.head` (no
        // double-free), and it's in a `Drop` impl (no use-after-free).
        unsafe {
            ffi::bdiff_freehunks(self.head);
        }
    }
}

pub struct HunkListIter<'a> {
    next: Option<&'a ffi::bdiff_hunk>,
    remaining: usize,
}

impl Iterator for HunkListIter<'_> {
    type Item = Hunk;

    fn next(&mut self) -> Option<Self::Item> {
        match self.next {
            Some(hunk) => {
                // Safety: Same reasoning as in `HunkList::iter`.
                self.next = unsafe { hunk.next.as_ref() };
                self.remaining -= 1;
                debug_assert_eq!(hunk.a2 - hunk.a1, hunk.b2 - hunk.b1);
                Some(Hunk {
                    a1: hunk.a1 as u32,
                    a2: hunk.a2 as u32,
                    b1: hunk.b1 as u32,
                    b2: hunk.b2 as u32,
                })
            }
            None => {
                assert_eq!(self.remaining, 0);
                None
            }
        }
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        (self.remaining, Some(self.remaining))
    }
}

impl ExactSizeIterator for HunkListIter<'_> {}

mod ffi {
    #![allow(non_camel_case_types)]

    use std::ffi::{c_char, c_int};

    #[repr(C)]
    #[derive(Debug, Copy, Clone)]
    pub struct bdiff_line {
        pub hash: c_int,
        pub n: c_int,
        pub e: c_int,
        pub len: isize,
        pub l: *const c_char,
    }

    #[repr(C)]
    #[derive(Debug, Copy, Clone)]
    pub struct bdiff_hunk {
        pub a1: c_int,
        pub a2: c_int,
        pub b1: c_int,
        pub b2: c_int,
        pub next: *mut bdiff_hunk,
    }

    #[link(name = "bdiff", kind = "static")]
    extern "C" {
        /// Splits `a` into lines. On success, stores a pointer to an array of
        /// lines in `*lr` and returns its length. On failure, returns
        /// -1. The caller is responsible for freeing the array.
        ///
        /// # Safety
        ///
        /// - `a` must point to an array of `len` chars.
        /// - `lr` must be non-null (but `*lr` can be null).
        pub fn bdiff_splitlines(
            a: *const c_char,
            len: isize,
            lr: *mut *mut bdiff_line,
        ) -> c_int;

        /// Diffs `a` and `b`. On success, stores the head of a linked list of
        /// hunks in `base->next` and returns its length. On failure, returns
        /// -1. The caller is responsible for `bdiff_freehunks(base->next)`.
        ///
        /// # Safety
        ///
        /// - `a` must point to an array of `an` lines.
        /// - `b` must point to an array of `bn` lines.
        /// - `base` must be non-null.
        pub fn bdiff_diff(
            a: *mut bdiff_line,
            an: c_int,
            b: *mut bdiff_line,
            bn: c_int,
            base: *mut bdiff_hunk,
        ) -> c_int;

        /// Frees the linked list of hunks `l`.
        ///
        /// # Safety
        ///
        /// - `l` must be non-null, not already freed, and not used after this.
        pub fn bdiff_freehunks(l: *mut bdiff_hunk);
    }
}

#[cfg(test)]
mod tests {
    fn split(a: &[u8]) -> Vec<&[u8]> {
        super::split_lines(a).unwrap().iter().collect()
    }

    fn diff(a: &[u8], b: &[u8]) -> Vec<(u32, u32, u32, u32)> {
        let la = super::split_lines(a).unwrap();
        let lb = super::split_lines(b).unwrap();
        let hunks = super::diff(&la, &lb).unwrap();
        hunks.iter().map(|h| (h.a1, h.a2, h.b1, h.b2)).collect()
    }

    #[test]
    fn test_split_lines() {
        assert_eq!(split(b""), [] as [&[u8]; 0]);
        assert_eq!(split(b"\n"), [b"\n"]);
        assert_eq!(split(b"\r\n"), [b"\r\n"]);
        assert_eq!(split(b"X\nY"), [b"X\n" as &[u8], b"Y"]);
        assert_eq!(split(b"X\nY\n"), [b"X\n" as &[u8], b"Y\n"]);
        assert_eq!(split(b"X\r\nY\r\n"), [b"X\r\n" as &[u8], b"Y\r\n"]);
    }

    #[test]
    fn test_diff_single_line() {
        assert_eq!(diff(b"", b""), &[(0, 0, 0, 0)]);
        assert_eq!(diff(b"x", b"x"), &[(0, 1, 0, 1), (1, 1, 1, 1)]);
        assert_eq!(diff(b"x", b"y"), &[(1, 1, 1, 1)]);
    }

    #[test]
    fn test_diff_multiple_lines() {
        assert_eq!(
            diff(
                b" line1 \n line2 \n line3 \n line4 \n REMOVED \n",
                b" ADDED \n line1 \n lined2_CHANGED \n line3 \n line4 \n"
            ),
            &[(0, 1, 1, 2), (2, 4, 3, 5), (5, 5, 5, 5)]
        );
    }
}
