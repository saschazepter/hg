// matchers.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Structs and types for matching files and directories.

use format_bytes::format_bytes;
use itertools::Itertools;
use once_cell::sync::OnceCell;
use regex_automata::meta::Regex;
use regex_syntax::hir::Hir;

use crate::{
    dirstate::dirs_multiset::{DirsChildrenMultiset, DirsMultiset},
    filepatterns::{
        build_single_regex, filter_subincludes, get_patterns_from_file,
        GlobSuffix, IgnorePattern, PatternError, PatternFileWarning,
        PatternResult, PatternSyntax, RegexCompleteness,
    },
    pre_regex::PreRegex,
    utils::{
        files::{dir_ancestors, find_dirs},
        hg_path::{HgPath, HgPathBuf, HgPathError},
        strings::Escaped,
    },
    FastHashMap,
};

use crate::dirstate::status::IgnoreFnType;
use crate::filepatterns::normalize_path_bytes;
use std::fmt::{Display, Error, Formatter};
use std::path::{Path, PathBuf};
use std::{borrow::ToOwned, collections::BTreeSet};
use std::{collections::HashSet, str::FromStr};

#[derive(Debug, PartialEq)]
pub enum VisitChildrenSet {
    /// Don't visit anything
    Empty,
    /// Visit this directory and probably its children
    This,
    /// Only visit the children (both files and directories) if they
    /// are mentioned in this set. (empty set corresponds to [`Self::Empty`])
    /// TODO Should we implement a `NonEmptyHashSet`?
    Set(HashSet<HgPathBuf>),
    /// Visit this directory and all subdirectories
    /// (you can stop asking about the children set)
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
    sorted_visitchildrenset_candidates: OnceCell<BTreeSet<HgPathBuf>>,
}

impl FileMatcher {
    pub fn new(files: Vec<HgPathBuf>) -> Result<Self, HgPathError> {
        let dirs = DirsMultiset::from_manifest(&files)?;
        Ok(Self {
            files: HashSet::from_iter(files),
            dirs,
            sorted_visitchildrenset_candidates: OnceCell::new(),
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
        if self.files.is_empty() || !self.dirs.contains(directory) {
            return VisitChildrenSet::Empty;
        }

        let compute_candidates = || -> BTreeSet<HgPathBuf> {
            let mut candidates: BTreeSet<HgPathBuf> =
                self.dirs.iter().cloned().collect();
            candidates.extend(self.files.iter().cloned());
            candidates.remove(HgPath::new(b""));
            candidates
        };
        let candidates =
            if directory.as_ref().is_empty() {
                compute_candidates()
            } else {
                let sorted_candidates = self
                    .sorted_visitchildrenset_candidates
                    .get_or_init(compute_candidates);
                let directory_bytes = directory.as_ref().as_bytes();
                let start: HgPathBuf =
                    format_bytes!(b"{}/", directory_bytes).into();
                let start_len = start.len();
                // `0` sorts after `/`
                let end = format_bytes!(b"{}0", directory_bytes).into();
                BTreeSet::from_iter(sorted_candidates.range(start..end).map(
                    |c| HgPathBuf::from_bytes(&c.as_bytes()[start_len..]),
                ))
            };

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

/// Matches a set of (kind, pat, source) against a 'root' directory.
/// (Currently the 'root' directory is effectively always empty)
/// ```
/// use hg::{
///     matchers::{PatternMatcher, Matcher},
///     filepatterns::{IgnorePattern, PatternSyntax},
///     utils::hg_path::{HgPath, HgPathBuf}
/// };
/// use std::collections::HashSet;
/// use std::path::Path;
/// ///
/// let ignore_patterns : Vec<IgnorePattern> =
///     vec![IgnorePattern::new(PatternSyntax::Regexp, br".*\.c$", Path::new("")),
///          IgnorePattern::new(PatternSyntax::Path, b"foo/a", Path::new("")),
///          IgnorePattern::new(PatternSyntax::RelPath, b"b", Path::new("")),
///          IgnorePattern::new(PatternSyntax::Glob, b"*.h", Path::new("")),
///     ];
/// let matcher = PatternMatcher::new(ignore_patterns).unwrap();
/// ///
/// assert_eq!(matcher.matches(HgPath::new(b"main.c")), true); // matches re:.*\.c$
/// assert_eq!(matcher.matches(HgPath::new(b"b.txt")), false);
/// assert_eq!(matcher.matches(HgPath::new(b"foo/a")), true); // matches path:foo/a
/// assert_eq!(matcher.matches(HgPath::new(b"a")), false); // does not match path:b, since 'root' is 'foo'
/// assert_eq!(matcher.matches(HgPath::new(b"b")), true); // matches relpath:b, since 'root' is 'foo'
/// assert_eq!(matcher.matches(HgPath::new(b"lib.h")), true); // matches glob:*.h
/// assert_eq!(matcher.file_set().unwrap(),
///            &HashSet::from([HgPathBuf::from_bytes(b""), HgPathBuf::from_bytes(b"foo/a"),
///                            HgPathBuf::from_bytes(b""), HgPathBuf::from_bytes(b"b")]));
/// assert_eq!(matcher.exact_match(HgPath::new(b"foo/a")), true);
/// assert_eq!(matcher.exact_match(HgPath::new(b"b")), true);
/// assert_eq!(matcher.exact_match(HgPath::new(b"lib.h")), false); // exact matches are for (rel)path kinds
/// ```
pub struct PatternMatcher<'a> {
    patterns: PatternsDesc,
    match_fn: IgnoreFnType<'a>,
    /// Whether all the patterns match a prefix (i.e. recursively)
    prefix: bool,
    files: HashSet<HgPathBuf>,
    dirs_explicit: HashSet<HgPathBuf>,
    dirs: DirsMultiset,
}

enum PatternsDesc {
    Re(PreRegex),
    RootFilesIn(Vec<Vec<u8>>, GlobSuffix),
}

pub enum ReSyntax {
    Tidy,
    Internal,
}

impl PatternsDesc {
    fn to_re(&self) -> PreRegex {
        match self {
            Self::Re(re) => re.clone(),
            Self::RootFilesIn(patterns, glob_suffix) => {
                let patterns = patterns
                    .clone()
                    .into_iter()
                    .map(|pattern: Vec<u8>| IgnorePattern {
                        syntax: PatternSyntax::RootFilesIn,
                        source: PathBuf::from_str("<rootfilesin-matcher>")
                            .unwrap(),
                        pattern,
                    })
                    .collect_vec();
                build_regex_match_for_debug(&patterns, *glob_suffix).unwrap()
            }
        }
    }

    fn to_pattern_bytes(&self, syntax: ReSyntax) -> Vec<u8> {
        match syntax {
            ReSyntax::Tidy => self.to_re().to_bytes(),
            ReSyntax::Internal => match self {
                PatternsDesc::Re(re) => re.to_hir().to_string().into_bytes(),
                PatternsDesc::RootFilesIn(dirs, _) => {
                    let mut patterns = vec![];
                    patterns.extend(b"rootfilesin: ");
                    let mut dirs_vec = dirs.clone();
                    dirs_vec.sort();
                    patterns.extend(dirs_vec.escaped_bytes());
                    patterns
                }
            },
        }
    }
}

impl core::fmt::Debug for PatternMatcher<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PatternMatcher")
            .field(
                "patterns",
                &String::from_utf8_lossy(
                    &self.patterns.to_pattern_bytes(ReSyntax::Internal),
                ),
            )
            .field("prefix", &self.prefix)
            .field("files", &self.files)
            .field("dirs", &self.dirs)
            .finish()
    }
}

impl<'a> PatternMatcher<'a> {
    pub fn new(ignore_patterns: Vec<IgnorePattern>) -> PatternResult<Self> {
        let RootsDirsAndParents {
            roots,
            dirs: dirs_explicit,
            parents,
        } = roots_dirs_and_parents(&ignore_patterns)?;
        let files = roots;
        let dirs = parents;
        let files: HashSet<HgPathBuf> = HashSet::from_iter(files);

        let prefix = ignore_patterns.iter().all(|k| {
            matches!(k.syntax, PatternSyntax::Path | PatternSyntax::RelPath)
        });
        let (patterns, match_fn) = build_match(
            ignore_patterns,
            GlobSuffix::Empty,
            RegexCompleteness::ExcludeExactFiles,
        )?;

        Ok(Self {
            patterns,
            match_fn,
            prefix,
            files,
            dirs,
            dirs_explicit,
        })
    }
}

impl<'a> Matcher for PatternMatcher<'a> {
    fn file_set(&self) -> Option<&HashSet<HgPathBuf>> {
        Some(&self.files)
    }

    fn exact_match(&self, filename: &HgPath) -> bool {
        self.files.contains(filename)
    }

    fn matches(&self, filename: &HgPath) -> bool {
        if self.files.contains(filename) {
            return true;
        }
        (self.match_fn)(filename)
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        if self.prefix && self.files.contains(directory) {
            return VisitChildrenSet::Recursive;
        }
        if self.dirs.contains(directory) {
            return VisitChildrenSet::This;
        }
        if dir_ancestors(directory).any(|parent_dir| {
            self.files.contains(parent_dir)
                || self.dirs_explicit.contains(parent_dir)
        }) {
            VisitChildrenSet::This
        } else {
            VisitChildrenSet::Empty
        }
    }

    fn matches_everything(&self) -> bool {
        false
    }

    fn is_exact(&self) -> bool {
        false
    }
}

/// A collection of patterns sufficient to construct an `IncludeMatcher`.
pub struct IncludeMatcherPre {
    patterns: Vec<IgnorePattern>,
}

impl IncludeMatcherPre {
    pub fn build_matcher(self) -> PatternResult<IncludeMatcher<'static>> {
        IncludeMatcher::new(self.patterns)
    }

    /// Used to print the full hgignore regex in `hg debugignorerhg`.
    pub fn build_debug_matcher(
        self,
        regex_config: RegexCompleteness,
    ) -> PatternResult<IncludeMatcher<'static>> {
        IncludeMatcher::new_gen(self.patterns, regex_config)
    }

    fn new(patterns: Vec<IgnorePattern>) -> Self {
        Self { patterns }
    }
}

/// Matches files that are included in the ignore rules.
/// ```
/// use hg::{
///     matchers::{IncludeMatcher, Matcher},
///     filepatterns::{IgnorePattern, PatternSyntax},
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
/// ///
/// let ignore_patterns =
/// vec![IgnorePattern::new(PatternSyntax::RootFilesIn, b"dir/subdir", Path::new(""))];
/// let matcher = IncludeMatcher::new(ignore_patterns).unwrap();
/// ///
/// assert!(!matcher.matches(HgPath::new(b"file")));
/// assert!(!matcher.matches(HgPath::new(b"dir/file")));
/// assert!(matcher.matches(HgPath::new(b"dir/subdir/file")));
/// assert!(!matcher.matches(HgPath::new(b"dir/subdir/subsubdir/file")));
/// ```
pub struct IncludeMatcher<'a> {
    patterns: PatternsDesc,
    match_fn: IgnoreFnType<'a>,
    /// Whether all the patterns match a prefix (i.e. recursively)
    prefix: bool,
    roots: HashSet<HgPathBuf>,
    dirs: HashSet<HgPathBuf>,
    parents: DirsMultiset,
}

impl core::fmt::Debug for IncludeMatcher<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("IncludeMatcher")
            .field(
                "patterns",
                &String::from_utf8_lossy(&self.patterns.to_re().to_bytes()),
            )
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
        (self.match_fn)(filename)
    }

    fn visit_children_set(&self, directory: &HgPath) -> VisitChildrenSet {
        let dir = directory;
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

        if self.parents.contains(dir.as_ref()) {
            let multiset = self.get_all_parents_children();
            if let Some(children) = multiset.get(dir) {
                return VisitChildrenSet::Set(
                    children.iter().map(HgPathBuf::from).collect(),
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
                let set: HashSet<_> = m1.intersection(m2).cloned().collect();
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
                m1_files
                    .iter()
                    .filter(|&f| m2.matches(f))
                    .cloned()
                    .collect()
            })
        } else {
            // without exact input file sets, we can't do an exact
            // intersection, so we must over-approximate by
            // unioning instead
            m1.file_set().map(|m1_files| match m2.file_set() {
                Some(m2_files) => m1_files.union(m2_files).cloned().collect(),
                None => m1_files.iter().cloned().collect(),
            })
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
                files.iter().filter(|&f| new.matches(f)).cloned().collect()
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
    base: regex_automata::meta::Regex,
    /// Thread-local variable that holds the `Regex` that is actually queried
    /// from each thread.
    local: thread_local::ThreadLocal<regex_automata::meta::Regex>,
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
#[logging_timer::time("trace")]
fn re_matcher(pattern: &Hir) -> PatternResult<RegexMatcher> {
    let re = regex_automata::meta::Builder::new()
        .configure(
            Regex::config()
                // Big repos with big `.hgignore` will hit the default limit
                // and incur a significant performance hit. One
                // repo's `hg status` hit multiple *minutes*.
                .dfa_size_limit(Some(50 * (1 << 20))),
        )
        .build_from_hir(pattern)
        .map_err(|e| PatternError::UnsupportedSyntax(e.to_string()))?;

    Ok(RegexMatcher {
        base: re,
        local: Default::default(),
    })
}

#[logging_timer::time("trace")]
/// Returns the regex pattern and a function that matches an `HgPath` against
/// said regex formed by the given ignore patterns.
fn build_regex_match<'a>(
    ignore_patterns: &[IgnorePattern],
    glob_suffix: GlobSuffix,
    regex_config: RegexCompleteness,
) -> PatternResult<(PreRegex, IgnoreFnType<'a>)> {
    let mut regexps = vec![];
    let mut exact_set = HashSet::new();

    for pattern in ignore_patterns {
        if let Some(re) =
            build_single_regex(pattern, glob_suffix, regex_config)?
        {
            regexps.push(re);
        } else {
            let exact = normalize_path_bytes(&pattern.pattern);
            exact_set.insert(HgPathBuf::from_bytes(&exact));
        }
    }

    let is_empty = regexps.is_empty();

    let full_regex = PreRegex::Sequence(vec![
        PreRegex::parse(&b"^"[..])?,
        PreRegex::Alternation(regexps),
    ]);

    // An empty pattern would cause the regex engine to incorrectly match the
    // (empty) root directory
    let func = if !is_empty {
        let matcher = re_matcher(&full_regex.to_hir())?;
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

#[logging_timer::time("trace")]
fn build_regex_match_for_debug<'a>(
    ignore_patterns: &[IgnorePattern],
    glob_suffix: GlobSuffix,
) -> PatternResult<PreRegex> {
    let mut regexps = vec![];

    for pattern in ignore_patterns {
        if let Some(re) = build_single_regex(
            pattern,
            glob_suffix,
            RegexCompleteness::Complete,
        )? {
            regexps.push(re);
        } else {
            panic!("RegexCompleteness::Complete should prevent this branch");
        }
    }

    Ok(PreRegex::Sequence(vec![
        PreRegex::parse(&b"^"[..])?,
        PreRegex::Alternation(regexps),
    ]))
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
                    if p.iter()
                        .any(|c| matches!(*c, b'[' | b'{' | b'*' | b'?'))
                    {
                        break;
                    }
                    root.push(HgPathBuf::from_bytes(p).as_ref());
                }
                roots.push(root);
            }
            PatternSyntax::Path
            | PatternSyntax::RelPath
            | PatternSyntax::FilePath => {
                let pat = HgPath::new(if pattern == b"." {
                    &[] as &[u8]
                } else {
                    pattern
                });
                roots.push(pat.to_owned());
            }
            PatternSyntax::RootFilesIn => {
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
    pub parents: DirsMultiset,
}

/// Extract roots, dirs and parents from patterns.
fn roots_dirs_and_parents(
    ignore_patterns: &[IgnorePattern],
) -> PatternResult<RootsDirsAndParents> {
    let (roots, dirs) = roots_and_dirs(ignore_patterns);

    let mut parents = DirsMultiset::from_manifest(&dirs)?;

    for path in &roots {
        parents.add_path(path)?
    }

    Ok(RootsDirsAndParents {
        roots: HashSet::from_iter(roots),
        dirs: HashSet::from_iter(dirs),
        parents,
    })
}

/// Returns a function that checks whether a given file (in the general sense)
/// should be matched.
fn build_match<'a>(
    ignore_patterns: Vec<IgnorePattern>,
    glob_suffix: GlobSuffix,
    regex_config: RegexCompleteness,
) -> PatternResult<(PatternsDesc, IgnoreFnType<'a>)> {
    let mut match_funcs: Vec<IgnoreFnType<'a>> = vec![];
    // For debugging and printing
    let patterns;

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
            .all(|k| k.syntax == PatternSyntax::RootFilesIn)
        {
            let dirs: HashSet<_> = ignore_patterns
                .iter()
                .map(|k| k.pattern.to_owned())
                .collect();
            let mut dirs_vec: Vec<_> = dirs.iter().cloned().collect();

            let match_func = move |path: &HgPath| -> bool {
                let path = path.as_bytes();
                let i = path.iter().rposition(|a| *a == b'/');
                let dir = if let Some(i) = i { &path[..i] } else { b"." };
                dirs.contains(dir)
            };
            match_funcs.push(Box::new(match_func));

            dirs_vec.sort();
            patterns = PatternsDesc::RootFilesIn(dirs_vec, glob_suffix);
        } else {
            let (new_re, match_func) = build_regex_match(
                &ignore_patterns,
                glob_suffix,
                regex_config,
            )?;
            patterns = PatternsDesc::Re(new_re);
            match_funcs.push(match_func)
        }
    } else {
        patterns = PatternsDesc::Re(PreRegex::Empty)
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
pub fn get_ignore_matcher_pre(
    mut all_pattern_files: Vec<PathBuf>,
    root_dir: &Path,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> PatternResult<(IncludeMatcherPre, Vec<PatternFileWarning>)> {
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
    let matcher = IncludeMatcherPre::new(all_patterns);
    Ok((matcher, all_warnings))
}

pub fn get_ignore_matcher<'a>(
    all_pattern_files: Vec<PathBuf>,
    root_dir: &Path,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> PatternResult<(IncludeMatcher<'a>, Vec<PatternFileWarning>)> {
    let (pre_matcher, warnings) = get_ignore_matcher_pre(
        all_pattern_files,
        root_dir,
        inspect_pattern_bytes,
    )?;
    Ok((pre_matcher.build_matcher()?, warnings))
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
    fn new_gen(
        ignore_patterns: Vec<IgnorePattern>,
        regex_config: RegexCompleteness,
    ) -> PatternResult<Self> {
        let RootsDirsAndParents {
            roots,
            dirs,
            parents,
        } = roots_dirs_and_parents(&ignore_patterns)?;
        let prefix = ignore_patterns.iter().all(|k| {
            matches!(k.syntax, PatternSyntax::Path | PatternSyntax::RelPath)
        });
        let (patterns, match_fn) = build_match(
            ignore_patterns,
            GlobSuffix::MoreComponents,
            regex_config,
        )?;

        Ok(Self {
            patterns,
            match_fn,
            prefix,
            roots,
            dirs,
            parents,
        })
    }

    pub fn new(ignore_patterns: Vec<IgnorePattern>) -> PatternResult<Self> {
        Self::new_gen(ignore_patterns, RegexCompleteness::ExcludeExactFiles)
    }

    fn get_all_parents_children(&self) -> DirsChildrenMultiset {
        // TODO cache
        let thing = self
            .dirs
            .iter()
            .chain(self.roots.iter())
            .chain(self.parents.iter());
        DirsChildrenMultiset::new(thing, Some(self.parents.iter()))
    }

    pub fn debug_get_patterns(&self, syntax: ReSyntax) -> Vec<u8> {
        self.patterns.to_pattern_bytes(syntax)
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
            &String::from_utf8_lossy(
                &self.patterns.to_pattern_bytes(ReSyntax::Internal)
            )
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::collections::BTreeMap;
    use std::collections::BTreeSet;
    use std::fmt::Debug;
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

        let parents = DirsMultiset::from_manifest(&[
            HgPathBuf::from_bytes(b"x"),
            HgPathBuf::from_bytes(b"g/x"),
            HgPathBuf::from_bytes(b"g/y"),
        ])
        .unwrap();

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
    fn test_patternmatcher() {
        // VisitdirPrefix
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Path,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        // OPT: This should probably be Recursive if its parent is?
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );

        // VisitchildrensetPrefix
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Path,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Recursive
        );
        // OPT: This should probably be Recursive if its parent is?
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );

        // VisitdirRootfilesin
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RootFilesIn,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );

        // VisitchildrensetRootfilesin
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RootFilesIn,
            b"dir/subdir",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        // FIXME: These should probably be {'dir'}, {'subdir'} and This,
        // respectively
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );

        // VisitdirGlob
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Glob,
            b"dir/z*",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        // OPT: these should probably be False.
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // VisitchildrensetGlob
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Glob,
            b"dir/z*",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        // OPT: these should probably be Empty
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::This
        );

        // VisitdirFilepath
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::FilePath,
            b"dir/z",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
        );

        // VisitchildrensetFilepath
        let m = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::FilePath,
            b"dir/z",
            Path::new(""),
        )])
        .unwrap();
        assert_eq!(
            m.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"folder")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::This
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            m.visit_children_set(HgPath::new(b"dir/subdir/x")),
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
            PatternSyntax::RootFilesIn,
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

        // VisitchildrensetFilePath
        let matcher = IncludeMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::FilePath,
            b"dir/z",
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
        let mut set = HashSet::new();
        set.insert(HgPathBuf::from_bytes(b"z"));
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir")),
            VisitChildrenSet::Set(set)
        );
        // OPT: these should probably be set().
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir")),
            VisitChildrenSet::Empty
        );
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"dir/subdir/x")),
            VisitChildrenSet::Empty
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
            PatternSyntax::RootFilesIn,
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
                PatternSyntax::RootFilesIn,
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
                PatternSyntax::RootFilesIn,
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

    mod invariants {
        pub mod visit_children_set {

            use crate::{
                matchers::{tests::Tree, Matcher, VisitChildrenSet},
                utils::hg_path::HgPath,
            };

            #[allow(dead_code)]
            #[derive(Debug)]
            struct Error<'a, M> {
                matcher: &'a M,
                path: &'a HgPath,
                matching: &'a Tree,
                visit_children_set: &'a VisitChildrenSet,
            }

            fn holds(
                matching: &Tree,
                not_matching: &Tree,
                vcs: &VisitChildrenSet,
            ) -> bool {
                match vcs {
                    VisitChildrenSet::Empty => matching.is_empty(),
                    VisitChildrenSet::This => {
                        // `This` does not come with any obligations.
                        true
                    }
                    VisitChildrenSet::Recursive => {
                        // `Recursive` requires that *everything* in the
                        // subtree matches. This
                        // requirement is relied on for example in
                        // DifferenceMatcher implementation.
                        not_matching.is_empty()
                    }
                    VisitChildrenSet::Set(allowed_children) => {
                        // `allowed_children` does not distinguish between
                        // files and directories: if it's not included, it
                        // must not be matched.
                        for k in matching.dirs.keys() {
                            if !(allowed_children.contains(k)) {
                                return false;
                            }
                        }
                        for k in matching.files.iter() {
                            if !(allowed_children.contains(k)) {
                                return false;
                            }
                        }
                        true
                    }
                }
            }

            pub fn check<M: Matcher + std::fmt::Debug>(
                matcher: &M,
                path: &HgPath,
                matching: &Tree,
                not_matching: &Tree,
                visit_children_set: &VisitChildrenSet,
            ) {
                if !holds(matching, not_matching, visit_children_set) {
                    panic!(
                        "{:#?}",
                        Error {
                            matcher,
                            path,
                            visit_children_set,
                            matching
                        }
                    )
                }
            }
        }
    }

    #[derive(Debug, Clone)]
    pub struct Tree {
        files: BTreeSet<HgPathBuf>,
        dirs: BTreeMap<HgPathBuf, Tree>,
    }

    impl Tree {
        fn len(&self) -> usize {
            let mut n = 0;
            n += self.files.len();
            for d in self.dirs.values() {
                n += d.len();
            }
            n
        }

        fn is_empty(&self) -> bool {
            self.files.is_empty() && self.dirs.is_empty()
        }

        fn make(
            files: BTreeSet<HgPathBuf>,
            dirs: BTreeMap<HgPathBuf, Tree>,
        ) -> Self {
            Self {
                files,
                dirs: dirs
                    .into_iter()
                    .filter(|(_k, v)| (!(v.is_empty())))
                    .collect(),
            }
        }

        fn filter_and_check<M: Matcher + Debug>(
            &self,
            m: &M,
            path: &HgPath,
        ) -> (Self, Self) {
            let (files1, files2): (BTreeSet<HgPathBuf>, BTreeSet<HgPathBuf>) =
                self.files
                    .iter()
                    .map(|v| v.to_owned())
                    .partition(|v| m.matches(&path.join(v)));
            let (dirs1, dirs2): (
                BTreeMap<HgPathBuf, Tree>,
                BTreeMap<HgPathBuf, Tree>,
            ) = self
                .dirs
                .iter()
                .map(|(k, v)| {
                    let path = path.join(k);
                    let (t1, t2) = v.filter_and_check(m, &path);
                    ((k.clone(), t1), (k.clone(), t2))
                })
                .unzip();
            let matching = Self::make(files1, dirs1);
            let not_matching = Self::make(files2, dirs2);
            let vcs = m.visit_children_set(path);
            invariants::visit_children_set::check(
                m,
                path,
                &matching,
                &not_matching,
                &vcs,
            );
            (matching, not_matching)
        }

        fn check_matcher<M: Matcher + Debug>(
            &self,
            m: &M,
            expect_count: usize,
        ) {
            let res = self.filter_and_check(m, &HgPathBuf::new());
            if expect_count != res.0.len() {
                eprintln!(
                    "warning: expected {} matches, got {} for {:#?}",
                    expect_count,
                    res.0.len(),
                    m
                );
            }
        }
    }

    fn mkdir(children: &[(&[u8], &Tree)]) -> Tree {
        let p = HgPathBuf::from_bytes;
        let names = [
            p(b"a"),
            p(b"b.txt"),
            p(b"file.txt"),
            p(b"c.c"),
            p(b"c.h"),
            p(b"dir1"),
            p(b"dir2"),
            p(b"subdir"),
        ];
        let files: BTreeSet<HgPathBuf> = BTreeSet::from(names);
        let dirs = children
            .iter()
            .map(|(name, t)| (p(name), (*t).clone()))
            .collect();
        Tree { files, dirs }
    }

    fn make_example_tree() -> Tree {
        let leaf = mkdir(&[]);
        let abc = mkdir(&[(b"d", &leaf)]);
        let ab = mkdir(&[(b"c", &abc)]);
        let a = mkdir(&[(b"b", &ab)]);
        let dir = mkdir(&[(b"subdir", &leaf), (b"subdir.c", &leaf)]);
        mkdir(&[(b"dir", &dir), (b"dir1", &dir), (b"dir2", &dir), (b"a", &a)])
    }

    #[test]
    fn test_pattern_matcher_visit_children_set() {
        let tree = make_example_tree();
        let pattern_dir1_glob_c =
            PatternMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::Glob,
                b"dir1/*.c",
                Path::new(""),
            )])
            .unwrap();
        let pattern_dir1 = || {
            PatternMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::Path,
                b"dir1",
                Path::new(""),
            )])
            .unwrap()
        };
        let pattern_dir1_a = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::Glob,
            b"dir1/a",
            Path::new(""),
        )])
        .unwrap();
        let pattern_relglob_c = || {
            PatternMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelGlob,
                b"*.c",
                Path::new(""),
            )])
            .unwrap()
        };
        let files = vec![HgPathBuf::from_bytes(b"dir/subdir/b.txt")];
        let file_dir_subdir_b = FileMatcher::new(files).unwrap();

        let files = vec![
            HgPathBuf::from_bytes(b"file.txt"),
            HgPathBuf::from_bytes(b"a/file.txt"),
            HgPathBuf::from_bytes(b"a/b/file.txt"),
            // No file in a/b/c
            HgPathBuf::from_bytes(b"a/b/c/d/file.txt"),
        ];
        let file_abcdfile = FileMatcher::new(files).unwrap();
        let rootfilesin_dir = PatternMatcher::new(vec![IgnorePattern::new(
            PatternSyntax::RootFilesIn,
            b"dir",
            Path::new(""),
        )])
        .unwrap();

        let pattern_filepath_dir_subdir =
            PatternMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::FilePath,
                b"dir/subdir",
                Path::new(""),
            )])
            .unwrap();

        let include_dir_subdir =
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::RelPath,
                b"dir/subdir",
                Path::new(""),
            )])
            .unwrap();

        let more_includematchers = [
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::Glob,
                b"dir/s*",
                Path::new(""),
            )])
            .unwrap(),
            // Test multiple patterns
            IncludeMatcher::new(vec![
                IgnorePattern::new(
                    PatternSyntax::RelPath,
                    b"dir",
                    Path::new(""),
                ),
                IgnorePattern::new(PatternSyntax::Glob, b"s*", Path::new("")),
            ])
            .unwrap(),
            // Test multiple patterns
            IncludeMatcher::new(vec![IgnorePattern::new(
                PatternSyntax::Glob,
                b"**/*.c",
                Path::new(""),
            )])
            .unwrap(),
        ];

        tree.check_matcher(&pattern_dir1(), 25);
        tree.check_matcher(&pattern_dir1_a, 1);
        tree.check_matcher(&pattern_dir1_glob_c, 2);
        tree.check_matcher(&pattern_relglob_c(), 14);
        tree.check_matcher(&AlwaysMatcher, 112);
        tree.check_matcher(&NeverMatcher, 0);
        tree.check_matcher(
            &IntersectionMatcher::new(
                Box::new(pattern_relglob_c()),
                Box::new(pattern_dir1()),
            ),
            3,
        );
        tree.check_matcher(
            &UnionMatcher::new(vec![
                Box::new(pattern_relglob_c()),
                Box::new(pattern_dir1()),
            ]),
            36,
        );
        tree.check_matcher(
            &DifferenceMatcher::new(
                Box::new(pattern_relglob_c()),
                Box::new(pattern_dir1()),
            ),
            11,
        );
        tree.check_matcher(&file_dir_subdir_b, 1);
        tree.check_matcher(&file_abcdfile, 4);
        tree.check_matcher(&rootfilesin_dir, 8);
        tree.check_matcher(&pattern_filepath_dir_subdir, 1);
        tree.check_matcher(&include_dir_subdir, 9);
        tree.check_matcher(&more_includematchers[0], 17);
        tree.check_matcher(&more_includematchers[1], 25);
        tree.check_matcher(&more_includematchers[2], 35);
    }
}
