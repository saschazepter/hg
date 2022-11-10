// matchers.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Structs and types for matching files and directories.

use crate::{
    dirstate::dirs_multiset::DirsChildrenMultiset,
    filepatterns::{
        build_single_regex, filter_subincludes, get_patterns_from_file,
        PatternFileWarning, PatternResult,
    },
    utils::{
        files::find_dirs,
        hg_path::{HgPath, HgPathBuf},
        Escaped,
    },
    DirsMultiset, DirstateMapError, FastHashMap, IgnorePattern, PatternError,
    PatternSyntax,
};

use crate::dirstate::status::IgnoreFnType;
use crate::filepatterns::normalize_path_bytes;
use std::borrow::ToOwned;
use std::collections::HashSet;
use std::fmt::{Display, Error, Formatter};
use std::iter::FromIterator;
use std::ops::Deref;
use std::path::{Path, PathBuf};

use micro_timer::timed;

#[derive(Debug, PartialEq)]
pub enum VisitChildrenSet {
    /// Don't visit anything
    Empty,
    /// Only visit this directory
    This,
    /// Visit this directory and these subdirectories
    /// TODO Should we implement a `NonEmptyHashSet`?
    Set(HashSet<HgPathBuf>),
    /// Visit this directory and all subdirectories
    Recursive,
}

pub trait Matcher: core::fmt::Debug {
    /// Explicitly listed files
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>>;
    /// Returns whether `filename` is in `file_set`
    fn exact_match(&self, filename: &HgPath) -> bool;
    /// Returns whether `filename` is matched by this matcher
    fn matches(&self, filename: &HgPath) -> bool;
    /// Decides whether a directory should be visited based on whether it
    /// has potential matches in it or one of its subdirectories, and
    /// potentially lists which subdirectories of that directory should be
    /// visited. This is based on the match's primary, included, and excluded
    /// patterns.
    ///
    /// # Example
    ///
    /// Assume matchers `['path:foo/bar', 'rootfilesin:qux']`, we would
    /// return the following values (assuming the implementation of
    /// visit_children_set is capable of recognizing this; some implementations
    /// are not).
    ///
    /// ```text
    /// ```ignore
    /// '' -> {'foo', 'qux'}
    /// 'baz' -> set()
    /// 'foo' -> {'bar'}
    /// // Ideally this would be `Recursive`, but since the prefix nature of
    /// // matchers is applied to the entire matcher, we have to downgrade this
    /// // to `This` due to the (yet to be implemented in Rust) non-prefix
    /// // `RootFilesIn'-kind matcher being mixed in.
    /// 'foo/bar' -> 'this'
    /// 'qux' -> 'this'
    /// ```
    /// # Important
    ///
    /// Most matchers do not know if they're representing files or
    /// directories. They see `['path:dir/f']` and don't know whether `f` is a
    /// file or a directory, so `visit_children_set('dir')` for most matchers
    /// will return `HashSet{ HgPath { "f" } }`, but if the matcher knows it's
    /// a file (like the yet to be implemented in Rust `ExactMatcher` does),
    /// it may return `VisitChildrenSet::This`.
    /// Do not rely on the return being a `HashSet` indicating that there are
    /// no files in this dir to investigate (or equivalently that if there are
    /// files to investigate in 'dir' that it will always return
    /// `VisitChildrenSet::This`).
    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet;
    /// Matcher will match everything and `files_set()` will be empty:
    /// optimization might be possible.
    fn matches_everything(&self) -> bool;
    /// Matcher will match exactly the files in `files_set()`: optimization
    /// might be possible.
    fn is_exact(&self) -> bool;
}

/// Matches everything.
///```
/// use hg::{ matchers::{Matcher, AlwaysMatcher}, utils::hg_path::HgPath };
///
/// let matcher = AlwaysMatcher;
///
/// assert_eq!(matcher.matches(HgPath::new(b"whatever")), true);
/// assert_eq!(matcher.matches(HgPath::new(b"b.txt")), true);
/// assert_eq!(matcher.matches(HgPath::new(b"main.c")), true);
/// assert_eq!(matcher.matches(HgPath::new(br"re:.*\.c$")), true);
/// ```
#[derive(Debug)]
pub struct AlwaysMatcher;

impl Matcher for AlwaysMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        None
    }
    fn exact_match(&self, _filename: &HgPath) -> bool {
        false
    }
    fn matches(&self, _filename: &HgPath) -> bool {
        true
    }
    fn visit_children_set(&self, _directory: &HgPath) -> VisitChildrenSet {
        VisitChildrenSet::Recursive
    }
    fn matches_everything(&self) -> bool {
        true
    }
    fn is_exact(&self) -> bool {
        false
    }
}

/// Matches nothing.
#[derive(Debug)]
pub struct NeverMatcher;

impl Matcher for NeverMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        None
    }
    fn exact_match(&self, _filename: &HgPath) -> bool {
        false
    }
    fn matches(&self, _filename: &HgPath) -> bool {
        false
    }
    fn visit_children_set(&self, _directory: &HgPath) -> VisitChildrenSet {
        VisitChildrenSet::Empty
    }
    fn matches_everything(&self) -> bool {
        false
    }
    fn is_exact(&self) -> bool {
        true
    }
}

/// Matches the input files exactly. They are interpreted as paths, not
/// patterns.
///
///```
/// use hg::{ matchers::{Matcher, FileMatcher}, utils::hg_path::{HgPath, HgPathBuf} };
///
/// let files = vec![HgPathBuf::from_bytes(b"a.txt"), HgPathBuf::from_bytes(br"re:.*\.c$")];
/// let matcher = FileMatcher::new(files).unwrap();
///
/// assert_eq!(matcher.matches(HgPath::new(b"a.txt")), true);
/// assert_eq!(matcher.matches(HgPath::new(b"b.txt")), false);
/// assert_eq!(matcher.matches(HgPath::new(b"main.c")), false);
/// assert_eq!(matcher.matches(HgPath::new(br"re:.*\.c$")), true);
/// ```
#[derive(Debug)]
pub struct FileMatcher {
    files: HashSet<HgPathBuf>,
    dirs: DirsMultiset,
}

impl FileMatcher {
    pub fn new(files: Vec<HgPathBuf>) -> Result<Self, DirstateMapError> {
        let dirs = DirsMultiset::from_manifest(&files)?;
        Ok(Self {
            files: HashSet::from_iter(files.into_iter()),
            dirs,
        })
    }
    fn inner_matches(&self, filename: &HgPath) -> bool {
        self.files.contains(filename.as_ref())
    }
}

impl Matcher for FileMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        Some(&self.files)
    }
    fn exact_match(&self, filename: &HgPath) -> bool {
        self.inner_matches(filename)
    }
    fn matches(&self, filename: &HgPath) -> bool {
        self.inner_matches(filename)
    }
    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        if self.files.is_empty() || !self.dirs.contains(&directory) {
            return VisitChildrenSet::Empty;
        }
        let mut candidates: HashSet<HgPathBuf> =
            self.dirs.iter().cloned().collect();

        candidates.extend(self.files.iter().cloned());
        candidates.remove(HgPath::new(b""));

        if !directory.as_ref().is_empty() {
            let directory = [directory.as_ref().as_bytes(), b"/"].concat();
            candidates = candidates
                .iter()
                .filter_map(|c| {
                    if c.as_bytes().starts_with(&directory) {
                        Some(HgPathBuf::from_bytes(
                            &c.as_bytes()[directory.len()..],
                        ))
                    } else {
                        None
                    }
                })
                .collect();
        }

        // `self.dirs` includes all of the directories, recursively, so if
        // we're attempting to match 'foo/bar/baz.txt', it'll have '', 'foo',
        // 'foo/bar' in it. Thus we can safely ignore a candidate that has a
        // '/' in it, indicating it's for a subdir-of-a-subdir; the immediate
        // subdir will be in there without a slash.
        VisitChildrenSet::Set(
            candidates
                .into_iter()
                .filter_map(|c| {
                    if c.bytes().all(|b| *b != b'/') {
                        Some(c)
                    } else {
                        None
                    }
                })
                .collect(),
        )
    }
    fn matches_everything(&self) -> bool {
        false
    }
    fn is_exact(&self) -> bool {
        true
    }
}

/// Matches files that are included in the ignore rules.
/// ```
/// use hg::{
///     matchers::{IncludeMatcher, Matcher},
///     IgnorePattern,
///     PatternSyntax,
///     utils::hg_path::HgPath
/// };
/// use std::path::Path;
/// ///
/// let ignore_patterns =
/// vec![IgnorePattern::new(PatternSyntax::RootGlob, b"this*", Path::new(""))];
/// let matcher = IncludeMatcher::new(ignore_patterns).unwrap();
/// ///
/// assert_eq!(matcher.matches(HgPath::new(b"testing")), false);
/// assert_eq!(matcher.matches(HgPath::new(b"this should work")), true);
/// assert_eq!(matcher.matches(HgPath::new(b"this also")), true);
/// assert_eq!(matcher.matches(HgPath::new(b"but not this")), false);
/// ```
pub struct IncludeMatcher<'a> {
    patterns: Vec<u8>,
    match_fn: IgnoreFnType<'a>,
    /// Whether all the patterns match a prefix (i.e. recursively)
    prefix: bool,
    roots: HashSet<HgPathBuf>,
    dirs: HashSet<HgPathBuf>,
    parents: HashSet<HgPathBuf>,
}

impl core::fmt::Debug for IncludeMatcher<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IncludeMatcher")
            .field("patterns", &String::from_utf8_lossy(&self.patterns))
            .field("prefix", &self.prefix)
            .field("roots", &self.roots)
            .field("dirs", &self.dirs)
            .field("parents", &self.parents)
            .finish()
    }
}

impl<'a> Matcher for IncludeMatcher<'a> {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        None
    }

    fn exact_match(&self, _filename: &HgPath) -> bool {
        false
    }

    fn matches(&self, filename: &HgPath) -> bool {
        (self.match_fn)(filename.as_ref())
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        let dir = directory.as_ref();
        if self.prefix && self.roots.contains(dir) {
            return VisitChildrenSet::Recursive;
        }
        if self.roots.contains(HgPath::new(b""))
            || self.roots.contains(dir)
            || self.dirs.contains(dir)
            || find_dirs(dir).any(|parent_dir| self.roots.contains(parent_dir))
        {
            return VisitChildrenSet::This;
        }

        if self.parents.contains(directory.as_ref()) {
            let multiset = self.get_all_parents_children();
            if let Some(children) = multiset.get(dir) {
                return VisitChildrenSet::Set(
                    children.into_iter().map(HgPathBuf::from).collect(),
                );
            }
        }
        VisitChildrenSet::Empty
    }

    fn matches_everything(&self) -> bool {
        false
    }

    fn is_exact(&self) -> bool {
        false
    }
}

/// The union of multiple matchers. Will match if any of the matchers match.
#[derive(Debug)]
pub struct UnionMatcher {
    matchers: Vec<Box<dyn Matcher + Sync>>,
}

impl Matcher for UnionMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        None
    }

    fn exact_match(&self, _filename: &HgPath) -> bool {
        false
    }

    fn matches(&self, filename: &HgPath) -> bool {
        self.matchers.iter().any(|m| m.matches(filename))
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        let mut result = HashSet::new();
        let mut this = false;
        for matcher in self.matchers.iter() {
            let visit = matcher.visit_children_set(directory);
            match visit {
                VisitChildrenSet::Empty => continue,
                VisitChildrenSet::This => {
                    this = true;
                    // Don't break, we might have an 'all' in here.
                    continue;
                }
                VisitChildrenSet::Set(set) => {
                    result.extend(set);
                }
                VisitChildrenSet::Recursive => {
                    return visit;
                }
            }
        }
        if this {
            return VisitChildrenSet::This;
        }
        if result.is_empty() {
            VisitChildrenSet::Empty
        } else {
            VisitChildrenSet::Set(result)
        }
    }

    fn matches_everything(&self) -> bool {
        // TODO Maybe if all are AlwaysMatcher?
        false
    }

    fn is_exact(&self) -> bool {
        false
    }
}

impl UnionMatcher {
    pub fn new(matchers: Vec<Box<dyn Matcher + Sync>>) -> Self {
        Self { matchers }
    }
}

#[derive(Debug)]
pub struct IntersectionMatcher {
    m1: Box<dyn Matcher + Sync>,
    m2: Box<dyn Matcher + Sync>,
    files: Option<HashSet<HgPathBuf>>,
}

impl Matcher for IntersectionMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        self.files.as_ref()
    }

    fn exact_match(&self, filename: &HgPath) -> bool {
        self.files.as_ref().map_or(false, |f| f.contains(filename))
    }

    fn matches(&self, filename: &HgPath) -> bool {
        self.m1.matches(filename) && self.m2.matches(filename)
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        let m1_set = self.m1.visit_children_set(directory);
        if m1_set == VisitChildrenSet::Empty {
            return VisitChildrenSet::Empty;
        }
        let m2_set = self.m2.visit_children_set(directory);
        if m2_set == VisitChildrenSet::Empty {
            return VisitChildrenSet::Empty;
        }

        if m1_set == VisitChildrenSet::Recursive {
            return m2_set;
        } else if m2_set == VisitChildrenSet::Recursive {
            return m1_set;
        }

        match (&m1_set, &m2_set) {
            (VisitChildrenSet::Recursive, _) => m2_set,
            (_, VisitChildrenSet::Recursive) => m1_set,
            (VisitChildrenSet::This, _) | (_, VisitChildrenSet::This) => {
                VisitChildrenSet::This
            }
            (VisitChildrenSet::Set(m1), VisitChildrenSet::Set(m2)) => {
                let set: HashSet<_> = m1.intersection(&m2).cloned().collect();
                if set.is_empty() {
                    VisitChildrenSet::Empty
                } else {
                    VisitChildrenSet::Set(set)
                }
            }
            _ => unreachable!(),
        }
    }

    fn matches_everything(&self) -> bool {
        self.m1.matches_everything() && self.m2.matches_everything()
    }

    fn is_exact(&self) -> bool {
        self.m1.is_exact() || self.m2.is_exact()
    }
}

impl IntersectionMatcher {
    pub fn new(
        mut m1: Box<dyn Matcher + Sync>,
        mut m2: Box<dyn Matcher + Sync>,
    ) -> Self {
        let files = if m1.is_exact() || m2.is_exact() {
            if !m1.is_exact() {
                std::mem::swap(&mut m1, &mut m2);
            }
            m1.file_set().map(|m1_files| {
                m1_files.iter().cloned().filter(|f| m2.matches(f)).collect()
            })
        } else {
            None
        };
        Self { m1, m2, files }
    }
}

#[derive(Debug)]
pub struct DifferenceMatcher {
    base: Box<dyn Matcher + Sync>,
    excluded: Box<dyn Matcher + Sync>,
    files: Option<HashSet<HgPathBuf>>,
}

impl Matcher for DifferenceMatcher {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        self.files.as_ref()
    }

    fn exact_match(&self, filename: &HgPath) -> bool {
        self.files.as_ref().map_or(false, |f| f.contains(filename))
    }

    fn matches(&self, filename: &HgPath) -> bool {
        self.base.matches(filename) && !self.excluded.matches(filename)
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        let excluded_set = self.excluded.visit_children_set(directory);
        if excluded_set == VisitChildrenSet::Recursive {
            return VisitChildrenSet::Empty;
        }
        let base_set = self.base.visit_children_set(directory);
        // Possible values for base: 'recursive', 'this', set(...), set()
        // Possible values for excluded:          'this', set(...), set()
        // If excluded has nothing under here that we care about, return base,
        // even if it's 'recursive'.
        if excluded_set == VisitChildrenSet::Empty {
            return base_set;
        }
        match base_set {
            VisitChildrenSet::This | VisitChildrenSet::Recursive => {
                // Never return 'recursive' here if excluded_set is any kind of
                // non-empty (either 'this' or set(foo)), since excluded might
                // return set() for a subdirectory.
                VisitChildrenSet::This
            }
            set => {
                // Possible values for base:         set(...), set()
                // Possible values for excluded: 'this', set(...)
                // We ignore excluded set results. They're possibly incorrect:
                //  base = path:dir/subdir
                //  excluded=rootfilesin:dir,
                //  visit_children_set(''):
                //   base returns {'dir'}, excluded returns {'dir'}, if we
                //   subtracted we'd return set(), which is *not* correct, we
                //   still need to visit 'dir'!
                set
            }
        }
    }

    fn matches_everything(&self) -> bool {
        false
    }

    fn is_exact(&self) -> bool {
        self.base.is_exact()
    }
}

impl DifferenceMatcher {
    pub fn new(
        base: Box<dyn Matcher + Sync>,
        excluded: Box<dyn Matcher + Sync>,
    ) -> Self {
        let base_is_exact = base.is_exact();
        let base_files = base.file_set().map(ToOwned::to_owned);
        let mut new = Self {
            base,
            excluded,
            files: None,
        };
        if base_is_exact {
            new.files = base_files.map(|files| {
                files.iter().cloned().filter(|f| new.matches(f)).collect()
            });
        }
        new
    }
}

/// Wraps [`regex::bytes::Regex`] to improve performance in multithreaded
/// contexts.
///
/// The `status` algorithm makes heavy use of threads, and calling `is_match`
/// from many threads at once is prone to contention, probably within the
/// scratch space needed as the regex DFA is built lazily.
///
/// We are in the process of raising the issue upstream, but for now
/// the workaround used here is to store the `Regex` in a lazily populated
/// thread-local variable, sharing the initial read-only compilation, but
/// not the lazy dfa scratch space mentioned above.
///
/// This reduces the contention observed with 16+ threads, but does not
/// completely remove it. Hopefully this can be addressed upstream.
struct RegexMatcher {
    /// Compiled at the start of the status algorithm, used as a base for
    /// cloning in each thread-local `self.local`, thus sharing the expensive
    /// first compilation.
    base: regex::bytes::Regex,
    /// Thread-local variable that holds the `Regex` that is actually queried
    /// from each thread.
    local: thread_local::ThreadLocal<regex::bytes::Regex>,
}

impl RegexMatcher {
    /// Returns whether the path matches the stored `Regex`.
    pub fn is_match(&self, path: &HgPath) -> bool {
        self.local
            .get_or(|| self.base.clone())
            .is_match(path.as_bytes())
    }
}

/// Returns a function that matches an `HgPath` against the given regex
/// pattern.
///
/// This can fail when the pattern is invalid or not supported by the
/// underlying engine (the `regex` crate), for instance anything with
/// back-references.
#[timed]
fn re_matcher(pattern: &[u8]) -> PatternResult<RegexMatcher> {
    use std::io::Write;

    // The `regex` crate adds `.*` to the start and end of expressions if there
    // are no anchors, so add the start anchor.
    let mut escaped_bytes = vec![b'^', b'(', b'?', b':'];
    for byte in pattern {
        if *byte > 127 {
            write!(escaped_bytes, "\\x{:x}", *byte).unwrap();
        } else {
            escaped_bytes.push(*byte);
        }
    }
    escaped_bytes.push(b')');

    // Avoid the cost of UTF8 checking
    //
    // # Safety
    // This is safe because we escaped all non-ASCII bytes.
    let pattern_string = unsafe { String::from_utf8_unchecked(escaped_bytes) };
    let re = regex::bytes::RegexBuilder::new(&pattern_string)
        .unicode(false)
        // Big repos with big `.hgignore` will hit the default limit and
        // incur a significant performance hit. One repo's `hg status` hit
        // multiple *minutes*.
        .dfa_size_limit(50 * (1 << 20))
        .build()
        .map_err(|e| PatternError::UnsupportedSyntax(e.to_string()))?;

    Ok(RegexMatcher {
        base: re,
        local: Default::default(),
    })
}

/// Returns the regex pattern and a function that matches an `HgPath` against
/// said regex formed by the given ignore patterns.
fn build_regex_match<'a, 'b>(
    ignore_patterns: &'a [IgnorePattern],
) -> PatternResult<(Vec<u8>, IgnoreFnType<'b>)> {
    let mut regexps = vec![];
    let mut exact_set = HashSet::new();

    for pattern in ignore_patterns {
        if let Some(re) = build_single_regex(pattern)? {
            regexps.push(re);
        } else {
            let exact = normalize_path_bytes(&pattern.pattern);
            exact_set.insert(HgPathBuf::from_bytes(&exact));
        }
    }

    let full_regex = regexps.join(&b'|');

    // An empty pattern would cause the regex engine to incorrectly match the
    // (empty) root directory
    let func = if !(regexps.is_empty()) {
        let matcher = re_matcher(&full_regex)?;
        let func = move |filename: &HgPath| {
            exact_set.contains(filename) || matcher.is_match(filename)
        };
        Box::new(func) as IgnoreFnType
    } else {
        let func = move |filename: &HgPath| exact_set.contains(filename);
        Box::new(func) as IgnoreFnType
    };

    Ok((full_regex, func))
}

/// Returns roots and directories corresponding to each pattern.
///
/// This calculates the roots and directories exactly matching the patterns and
/// returns a tuple of (roots, dirs). It does not return other directories
/// which may also need to be considered, like the parent directories.
fn roots_and_dirs(
    ignore_patterns: &[IgnorePattern],
) -> (Vec<HgPathBuf>, Vec<HgPathBuf>) {
    let mut roots = Vec::new();
    let mut dirs = Vec::new();

    for ignore_pattern in ignore_patterns {
        let IgnorePattern {
            syntax, pattern, ..
        } = ignore_pattern;
        match syntax {
            PatternSyntax::RootGlob | PatternSyntax::Glob => {
                let mut root = HgPathBuf::new();
                for p in pattern.split(|c| *c == b'/') {
                    if p.iter().any(|c| match *c {
                        b'[' | b'{' | b'*' | b'?' => true,
                        _ => false,
                    }) {
                        break;
                    }
                    root.push(HgPathBuf::from_bytes(p).as_ref());
                }
                roots.push(root);
            }
            PatternSyntax::Path | PatternSyntax::RelPath => {
                let pat = HgPath::new(if pattern == b"." {
                    &[] as &[u8]
                } else {
                    pattern
                });
                roots.push(pat.to_owned());
            }
            PatternSyntax::RootFiles => {
                let pat = if pattern == b"." {
                    &[] as &[u8]
                } else {
                    pattern
                };
                dirs.push(HgPathBuf::from_bytes(pat));
            }
            _ => {
                roots.push(HgPathBuf::new());
            }
        }
    }
    (roots, dirs)
}

/// Paths extracted from patterns
#[derive(Debug, PartialEq)]
struct RootsDirsAndParents {
    /// Directories to match recursively
    pub roots: HashSet<HgPathBuf>,
    /// Directories to match non-recursively
    pub dirs: HashSet<HgPathBuf>,
    /// Implicitly required directories to go to items in either roots or dirs
    pub parents: HashSet<HgPathBuf>,
}

/// Extract roots, dirs and parents from patterns.
fn roots_dirs_and_parents(
    ignore_patterns: &[IgnorePattern],
) -> PatternResult<RootsDirsAndParents> {
    let (roots, dirs) = roots_and_dirs(ignore_patterns);

    let mut parents = HashSet::new();

    parents.extend(
        DirsMultiset::from_manifest(&dirs)
            .map_err(|e| match e {
                DirstateMapError::InvalidPath(e) => e,
                _ => unreachable!(),
            })?
            .iter()
            .map(ToOwned::to_owned),
    );
    parents.extend(
        DirsMultiset::from_manifest(&roots)
            .map_err(|e| match e {
                DirstateMapError::InvalidPath(e) => e,
                _ => unreachable!(),
            })?
            .iter()
            .map(ToOwned::to_owned),
    );

    Ok(RootsDirsAndParents {
        roots: HashSet::from_iter(roots),
        dirs: HashSet::from_iter(dirs),
        parents,
    })
}

/// Returns a function that checks whether a given file (in the general sense)
/// should be matched.
fn build_match<'a, 'b>(
    ignore_patterns: Vec<IgnorePattern>,
) -> PatternResult<(Vec<u8>, IgnoreFnType<'b>)> {
    let mut match_funcs: Vec<IgnoreFnType<'b>> = vec![];
    // For debugging and printing
    let mut patterns = vec![];

    let (subincludes, ignore_patterns) = filter_subincludes(ignore_patterns)?;

    if !subincludes.is_empty() {
        // Build prefix-based matcher functions for subincludes
        let mut submatchers = FastHashMap::default();
        let mut prefixes = vec![];

        for sub_include in subincludes {
            let matcher = IncludeMatcher::new(sub_include.included_patterns)?;
            let match_fn =
                Box::new(move |path: &HgPath| matcher.matches(path));
            prefixes.push(sub_include.prefix.clone());
            submatchers.insert(sub_include.prefix.clone(), match_fn);
        }

        let match_subinclude = move |filename: &HgPath| {
            for prefix in prefixes.iter() {
                if let Some(rel) = filename.relative_to(prefix) {
                    if (submatchers[prefix])(rel) {
                        return true;
                    }
                }
            }
            false
        };

        match_funcs.push(Box::new(match_subinclude));
    }

    if !ignore_patterns.is_empty() {
        // Either do dumb matching if all patterns are rootfiles, or match
        // with a regex.
        if ignore_patterns
            .iter()
            .all(|k| k.syntax == PatternSyntax::RootFiles)
        {
            let dirs: HashSet<_> = ignore_patterns
                .iter()
                .map(|k| k.pattern.to_owned())
                .collect();
            let mut dirs_vec: Vec<_> = dirs.iter().cloned().collect();

            let match_func = move |path: &HgPath| -> bool {
                let path = path.as_bytes();
                let i = path.iter().rfind(|a| **a == b'/');
                let dir = if let Some(i) = i {
                    &path[..*i as usize]
                } else {
                    b"."
                };
                dirs.contains(dir.deref())
            };
            match_funcs.push(Box::new(match_func));

            patterns.extend(b"rootfilesin: ");
            dirs_vec.sort();
            patterns.extend(dirs_vec.escaped_bytes());
        } else {
            let (new_re, match_func) = build_regex_match(&ignore_patterns)?;
            patterns = new_re;
            match_funcs.push(match_func)
        }
    }

    Ok(if match_funcs.len() == 1 {
        (patterns, match_funcs.remove(0))
    } else {
        (
            patterns,
            Box::new(move |f: &HgPath| -> bool {
                match_funcs.iter().any(|match_func| match_func(f))
            }),
        )
    })
}

/// Parses all "ignore" files with their recursive includes and returns a
/// function that checks whether a given file (in the general sense) should be
/// ignored.
pub fn get_ignore_matcher<'a>(
    mut all_pattern_files: Vec<PathBuf>,
    root_dir: &Path,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> PatternResult<(IncludeMatcher<'a>, Vec<PatternFileWarning>)> {
    let mut all_patterns = vec![];
    let mut all_warnings = vec![];

    // Sort to make the ordering of calls to `inspect_pattern_bytes`
    // deterministic even if the ordering of `all_pattern_files` is not (such
    // as when a iteration order of a Python dict or Rust HashMap is involved).
    // Sort by "string" representation instead of the default by component
    // (with a Rust-specific definition of a component)
    all_pattern_files
        .sort_unstable_by(|a, b| a.as_os_str().cmp(b.as_os_str()));

    for pattern_file in &all_pattern_files {
        let (patterns, warnings) = get_patterns_from_file(
            pattern_file,
            root_dir,
            inspect_pattern_bytes,
        )?;

        all_patterns.extend(patterns.to_owned());
        all_warnings.extend(warnings);
    }
    let matcher = IncludeMatcher::new(all_patterns)?;
    Ok((matcher, all_warnings))
}

/// Parses all "ignore" files with their recursive includes and returns a
/// function that checks whether a given file (in the general sense) should be
/// ignored.
pub fn get_ignore_function<'a>(
    all_pattern_files: Vec<PathBuf>,
    root_dir: &Path,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> PatternResult<(IgnoreFnType<'a>, Vec<PatternFileWarning>)> {
    let res =
        get_ignore_matcher(all_pattern_files, root_dir, inspect_pattern_bytes);
    res.map(|(matcher, all_warnings)| {
        let res: IgnoreFnType<'a> =
            Box::new(move |path: &HgPath| matcher.matches(path));

        (res, all_warnings)
    })
}

impl<'a> IncludeMatcher<'a> {
    pub fn new(ignore_patterns: Vec<IgnorePattern>) -> PatternResult<Self> {
        let RootsDirsAndParents {
            roots,
            dirs,
            parents,
        } = roots_dirs_and_parents(&ignore_patterns)?;
        let prefix = ignore_patterns.iter().all(|k| match k.syntax {
            PatternSyntax::Path | PatternSyntax::RelPath => true,
            _ => false,
        });
        let (patterns, match_fn) = build_match(ignore_patterns)?;

        Ok(Self {
            patterns,
            match_fn,
            prefix,
            roots,
            dirs,
            parents,
        })
    }

    fn get_all_parents_children(&self) -> DirsChildrenMultiset {
        // TODO cache
        let thing = self
            .dirs
            .iter()
            .chain(self.roots.iter())
            .chain(self.parents.iter());
        DirsChildrenMultiset::new(thing, Some(&self.parents))
    }

    pub fn debug_get_patterns(&self) -> &[u8] {
        self.patterns.as_ref()
    }
}

impl<'a> Display for IncludeMatcher<'a> {
    fn fmt(&self, f: &mut Formatter<'_>) -> Result<(), Error> {
        // XXX What about exact matches?
        // I'm not sure it's worth it to clone the HashSet and keep it
        // around just in case someone wants to display the matcher, plus
        // it's going to be unreadable after a few entries, but we need to
        // inform in this display that exact matches are being used and are
        // (on purpose) missing from the `includes`.
        write!(
            f,
            "IncludeMatcher(includes='{}')",
            String::from_utf8_lossy(&self.patterns.escaped_bytes())
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::path::Path;

    #[test]
    fn test_roots_and_dirs() {
        let pats = vec![
            IgnorePattern::new(PatternSyntax::Glob, b"g/h/*", Path::new("")),
            IgnorePattern::new(PatternSyntax::Glob, b"g/h", Path::new("")),
            IgnorePattern::new(PatternSyntax::Glob, b"g*", Path::new("")),
        ];
        let (roots, dirs) = roots_and_dirs(&pats);

        assert_eq!(
            roots,
            vec!(
                HgPathBuf::from_bytes(b"g/h"),
                HgPathBuf::from_bytes(b"g/h"),
                HgPathBuf::new()
            ),
        );
        assert_eq!(dirs, vec!());
    }

    #[test]
    fn test_roots_dirs_and_parents() {
        let pats = vec![
            IgnorePattern::new(PatternSyntax::Glob, b"g/h/*", Path::new("")),
            IgnorePattern::new(PatternSyntax::Glob, b"g/h", Path::new("")),
            IgnorePattern::new(PatternSyntax::Glob, b"g*", Path::new("")),
        ];

        let mut roots = HashSet::new();
        roots.insert(HgPathBuf::from_bytes(b"g/h"));
        roots.insert(HgPathBuf::new());

        let dirs = HashSet::new();

        let mut parents = HashSet::new();
        parents.insert(HgPathBuf::new());
        parents.insert(HgPathBuf::from_bytes(b"g"));

        assert_eq!(
            roots_dirs_and_parents(&pats).unwrap(),
            RootsDirsAndParents {
                roots,
                dirs,
                parents
            }
        );
    }

    #[test]
    fn test_filematcher_visit_children_set() {
        // Visitchildrenset
        let files = vec![HgPathBuf::from_bytes(b"dir/subdir/foo.txt")];
        let matcher = FileMatcher::new(files).unwrap();

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"foo.txt"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Set(set)
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/foo.txt")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
    }

    #[test]
    fn test_filematcher_visit_children_set_files_and_dirs() {
        let files = vec![
            HgPathBuf::from_bytes(b"rootfile.txt"),
            HgPathBuf::from_bytes(b"a/file1.txt"),
            HgPathBuf::from_bytes(b"a/b/file2.txt"),
            // No file in a/b/c
            HgPathBuf::from_bytes(b"a/b/c/d/file4.txt"),
        ];
        let matcher = FileMatcher::new(files).unwrap();

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"a"));
        set.insert(HgPathBuf::from_bytes(b"rootfile.txt"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"b"));
        set.insert(HgPathBuf::from_bytes(b"file1.txt"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"a")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"c"));
        set.insert(HgPathBuf::from_bytes(b"file2.txt"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"a/b")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"d"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"a/b/c")),
            VisitChildrenSet::Set(set)
        );
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"file4.txt"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"a/b/c/d")),
            VisitChildrenSet::Set(set)
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"a/b/c/d/e")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
    }

    #[test]
    fn test_includematcher() {
        // VisitchildrensetPrefix
        let matcher = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        // OPT: This should probably be 'all' if its parent is?
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );

        // VisitchildrensetRootfilesin
        let matcher = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RootFiles,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );

        // VisitchildrensetGlob
        let matcher = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Glob,
            b"dir/z*",
            Path::new(""),
        )])
        .unwrap();

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        // OPT: these should probably be set().
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // Test multiple patterns
        let matcher = IncludeMatcher::new(vec![
            IgnorePattern::new(PatternSyntax::RelPath, b"foo", Path::new("")),
            IgnorePattern::new(PatternSyntax::Glob, b"g*", Path::new("")),
        ])
        .unwrap();

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );

        // Test multiple patterns
        let matcher = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Glob,
            b"**/*.exe",
            Path::new(""),
        )])
        .unwrap();

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
    }

    #[test]
    fn test_unionmatcher() {
        // Path + Rootfiles
        let m1 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        let m2 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RootFiles,
            b"dir",
            Path::new(""),
        )])
        .unwrap();
        let matcher = UnionMatcher::new(vec![Box::new(m1), Box::new(m2)]);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );

        // OPT: These next two could be 'all' instead of 'this'.
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // Path + unrelated Path
        let m1 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        let m2 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"folder",
            Path::new(""),
        )])
        .unwrap();
        let matcher = UnionMatcher::new(vec![Box::new(m1), Box::new(m2)]);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"folder"));
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Recursive
        );
        // OPT: These next two could be 'all' instead of 'this'.
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // Path + subpath
        let m1 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"dir/subdir/x",
            Path::new(""),
        )])
        .unwrap();
        let m2 = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RelPath,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        let matcher = UnionMatcher::new(vec![Box::new(m1), Box::new(m2)]);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Recursive
        );
        // OPT: this should probably be 'all' not 'this'.
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::This
        );
    }

    #[test]
    fn test_intersectionmatcher() {
        // Include path + Include rootfiles
        let m1 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir",
                Path::new(""),
            )])
            .unwrap(),
        );
        let m2 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RootFiles,
                b"dir",
                Path::new(""),
            )])
            .unwrap(),
        );
        let matcher = IntersectionMatcher::new(m1, m2);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );

        // Non intersecting paths
        let m1 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir",
                Path::new(""),
            )])
            .unwrap(),
        );
        let m2 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"folder",
                Path::new(""),
            )])
            .unwrap(),
        );
        let matcher = IntersectionMatcher::new(m1, m2);

        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );

        // Nested paths
        let m1 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir/x",
                Path::new(""),
            )])
            .unwrap(),
        );
        let m2 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir",
                Path::new(""),
            )])
            .unwrap(),
        );
        let matcher = IntersectionMatcher::new(m1, m2);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"x"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::Empty
        );
        // OPT: this should probably be 'all' not 'this'.
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // Diverging paths
        let m1 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir/x",
                Path::new(""),
            )])
            .unwrap(),
        );
        let m2 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir/z",
                Path::new(""),
            )])
            .unwrap(),
        );
        let matcher = IntersectionMatcher::new(m1, m2);

        // OPT: these next two could probably be Empty as well.
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );
        // OPT: these next two could probably be Empty as well.
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );
    }

    #[test]
    fn test_differencematcher() {
        // Two alwaysmatchers should function like a nevermatcher
        let m1 = AlwaysMatcher;
        let m2 = AlwaysMatcher;
        let matcher = DifferenceMatcher::new(Box::new(m1), Box::new(m2));

        for case in &[
            &b""[..],
            b"dir",
            b"dir/subdir",
            b"dir/subdir/z",
            b"dir/foo",
            b"dir/subdir/x",
            b"folder",
        ] {
            assert_eq!(
                matcher.visit_children_set(HgPath::new(case)),
                VisitChildrenSet::Empty
            );
        }

        // One always and one never should behave the same as an always
        let m1 = AlwaysMatcher;
        let m2 = NeverMatcher;
        let matcher = DifferenceMatcher::new(Box::new(m1), Box::new(m2));

        for case in &[
            &b""[..],
            b"dir",
            b"dir/subdir",
            b"dir/subdir/z",
            b"dir/foo",
            b"dir/subdir/x",
            b"folder",
        ] {
            assert_eq!(
                matcher.visit_children_set(HgPath::new(case)),
                VisitChildrenSet::Recursive
            );
        }

        // Two include matchers
        let m1 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir",
                Path::new("/repo"),
            )])
            .unwrap(),
        );
        let m2 = Box::new(
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RootFiles,
                b"dir",
                Path::new("/repo"),
            )])
            .unwrap(),
        );

        let matcher = DifferenceMatcher::new(m1, m2);

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"dir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(set)
        );

        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"subdir"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/foo")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/z")),
            VisitChildrenSet::This
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
    }
}
