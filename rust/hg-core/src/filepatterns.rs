// filepatterns.rs
//
// Copyright 2019 Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

//! Handling of Mercurial-specific patterns.

use crate::{
    pre_regex::PreRegex,
    utils::{
        files::{canonical_path, get_bytes_from_path, get_path_from_bytes},
        hg_path::{path_to_hg_path_buf, HgPathBuf, HgPathError},
        strings::SliceExt,
    },
    FastHashMap,
};
use lazy_static::lazy_static;
use regex::bytes::{NoExpand, Regex};
use std::mem;
use std::path::{Path, PathBuf};
use std::vec::Vec;
use std::{fmt, ops::Deref};

#[derive(Debug, derive_more::From)]
pub enum PatternError {
    #[from]
    Path(HgPathError),
    UnsupportedSyntax(String),
    UnsupportedSyntaxInFile(String, String, usize),
    TooLong(usize),
    #[from]
    IO(std::io::Error),
    /// Needed a pattern that can be turned into a regex but got one that
    /// can't. This should only happen through programmer error.
    NonRegexPattern(IgnorePattern),
}

impl fmt::Display for PatternError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            PatternError::UnsupportedSyntax(syntax) => {
                write!(f, "Unsupported syntax {}", syntax)
            }
            PatternError::UnsupportedSyntaxInFile(syntax, file_path, line) => {
                write!(
                    f,
                    "{}:{}: unsupported syntax {}",
                    file_path, line, syntax
                )
            }
            PatternError::TooLong(size) => {
                write!(f, "matcher pattern is too long ({} bytes)", size)
            }
            PatternError::IO(error) => error.fmt(f),
            PatternError::Path(error) => error.fmt(f),
            PatternError::NonRegexPattern(pattern) => {
                write!(f, "'{:?}' cannot be turned into a regex", pattern)
            }
        }
    }
}

lazy_static! {
    static ref RE_ESCAPE: Vec<Vec<u8>> = {
        let mut v: Vec<Vec<u8>> = (0..=255).map(|byte| vec![byte]).collect();
        let to_escape = b"()[]{}?*+-|^$\\.&~#\t\n\r\x0b\x0c";
        for byte in to_escape {
            v[*byte as usize].insert(0, b'\\');
        }
        v
    };
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PatternSyntax {
    /// A regular expression
    Regexp,
    /// Glob that matches at the front of the path
    RootGlob,
    /// Glob that matches at any suffix of the path (still anchored at
    /// slashes)
    Glob,
    /// a path relative to repository root, which is matched recursively
    Path,
    /// a single exact path relative to repository root
    FilePath,
    /// A path relative to cwd
    RelPath,
    /// an unrooted glob (*.rs matches Rust files in all dirs)
    RelGlob,
    /// A regexp that needn't match the start of a name
    RelRegexp,
    /// A path relative to repository root, which is matched non-recursively
    /// (will not match subdirectories)
    RootFilesIn,
    /// A file of patterns to read and include
    Include,
    /// A file of patterns to match against files under the same directory
    SubInclude,
    /// SubInclude with the result of parsing the included file
    ///
    /// Note: there is no ExpandedInclude because that expansion can be done
    /// in place by replacing the Include pattern by the included patterns.
    /// SubInclude requires more handling.
    ///
    /// Note: `Box` is used to minimize size impact on other enum variants
    ExpandedSubInclude(Box<SubInclude>),
}

/// A wildcard parsed from a glob
#[derive(Debug, Clone, Copy)]
enum GlobWildcard {
    /// `**/` matches any sequence of characters ending at a path
    /// component boundary
    AnyComponents,
    /// `*`: matches any sequence of characters within one path component
    AnyNonSlash,
    /// `**`: matches any sequence of characters including slashes
    Anything,
}
impl GlobWildcard {
    /// Optimization to simplify the regex prefixes for unrooted globs.
    /// It's unclear if this is worth it for performance, but it also has
    /// some cosmetic effect by making these regexes easier to understand.
    fn make_unrooted(wildcard: Option<GlobWildcard>) -> GlobWildcard {
        match wildcard {
            None => Self::AnyComponents,
            Some(Self::AnyComponents) => Self::AnyComponents,
            Some(Self::AnyNonSlash) => Self::Anything,
            Some(Self::Anything) => Self::Anything,
        }
    }

    fn to_re(self) -> PreRegex {
        match self {
            Self::AnyComponents => PreRegex::preceding_dir_components(),
            Self::AnyNonSlash => PreRegex::NonslashStar,
            Self::Anything => PreRegex::DotStar,
        }
    }
}

fn glob_parse_after_star(input: &mut &[u8]) -> GlobWildcard {
    if let Some((b'*', rest)) = input.split_first() {
        if let Some((b'/', rest)) = rest.split_first() {
            *input = rest;
            GlobWildcard::AnyComponents
        } else {
            *input = rest;
            GlobWildcard::Anything
        }
    } else {
        GlobWildcard::AnyNonSlash
    }
}

/// The result of glob to re conversion.
/// The start of the regular expression `start` is tracked
/// separately for a pattern simplification opportunity
/// (see `GlobWildcard::make_unrooted`)
pub struct GlobToRe {
    start: Option<GlobWildcard>,
    rest: Vec<PreRegex>,
}

impl GlobToRe {
    /// Convert to a regex. `rooted` specifies if the glob should match
    /// at the root of the repo (true), or anywhere in the repo (false)
    fn into_re(self, rooted: bool) -> PreRegex {
        let wildcard = if !rooted {
            Some(GlobWildcard::make_unrooted(self.start))
        } else {
            self.start
        };

        let mut res: Vec<_> =
            wildcard.into_iter().map(|x| x.to_re()).collect();
        res.extend(self.rest);
        PreRegex::Sequence(res)
    }
}

/// Transforms a glob pattern into a regex.
pub fn glob_to_re(pat: &[u8]) -> PatternResult<GlobToRe> {
    let mut start = None;
    let mut res: Vec<PreRegex> = vec![];
    let mut input = pat;

    let mut group_stack = vec![];

    let add_byte = |out: &mut Vec<PreRegex>, b: u8| match out.last_mut() {
        Some(PreRegex::Bytes(v)) => {
            v.push(b);
        }
        _ => out.push(PreRegex::Bytes(vec![b])),
    };

    while let Some((c, rest)) = input.split_first() {
        input = rest;

        match c {
            b'*' => {
                let wildcard = glob_parse_after_star(&mut input);
                if res.is_empty() && start.is_none() {
                    start = Some(wildcard)
                } else {
                    res.push(wildcard.to_re())
                }
            }
            b'?' => res.push(PreRegex::Dot),
            b'[' => {
                match input.iter().skip(1).position(|b| *b == b']') {
                    None => res.push(PreRegex::Byte(b'[')),
                    Some(end) => {
                        // Account for the one we skipped
                        let end = end + 1;

                        // TODO: parse charsets ourselves?
                        let mut class = vec![];
                        class.extend(b"[");

                        for (i, b) in input[..end].iter().enumerate() {
                            if *b == b'!' && i == 0 {
                                class.extend(b"^")
                            } else if *b == b'^' && i == 0 {
                                class.extend(b"\\^")
                            } else if *b == b'\\' {
                                class.extend(b"\\\\")
                            } else {
                                class.push(*b)
                            }
                        }
                        class.extend(b"]");

                        res.push(PreRegex::parse(&class)?);

                        input = &input[end + 1..];
                    }
                }
            }
            b'{' => {
                group_stack.push((mem::take(&mut res), vec![]));
            }
            b'}' if !group_stack.is_empty() => {
                let hir = PreRegex::Sequence(mem::take(&mut res));
                let (old_res, mut alt) = group_stack.pop().unwrap();
                alt.push(hir);
                res = old_res;
                res.push(PreRegex::Alternation(alt));
            }
            b',' if !group_stack.is_empty() => {
                let frame = group_stack.last_mut().unwrap();
                frame.1.push(PreRegex::Sequence(mem::take(&mut res)));
            }
            b'\\' => {
                let c = {
                    if let Some((c, rest)) = input.split_first() {
                        input = rest;
                        c
                    } else {
                        c
                    }
                };
                add_byte(&mut res, *c)
            }
            _ => add_byte(&mut res, *c),
        }
    }
    if !group_stack.is_empty() {
        return Err(PatternError::UnsupportedSyntax(
            "error: invalid glob, has unclosed alternation ('{')".to_string(),
        ));
    }
    Ok(GlobToRe { start, rest: res })
}

pub fn parse_pattern_syntax_kind(
    kind: &[u8],
) -> Result<PatternSyntax, PatternError> {
    match kind {
        b"re" => Ok(PatternSyntax::Regexp),
        b"path" => Ok(PatternSyntax::Path),
        b"filepath" => Ok(PatternSyntax::FilePath),
        b"relpath" => Ok(PatternSyntax::RelPath),
        b"rootfilesin" => Ok(PatternSyntax::RootFilesIn),
        b"relglob" => Ok(PatternSyntax::RelGlob),
        b"relre" => Ok(PatternSyntax::RelRegexp),
        b"glob" => Ok(PatternSyntax::Glob),
        b"rootglob" => Ok(PatternSyntax::RootGlob),
        b"include" => Ok(PatternSyntax::Include),
        b"subinclude" => Ok(PatternSyntax::SubInclude),
        _ => Err(PatternError::UnsupportedSyntax(
            String::from_utf8_lossy(kind).to_string(),
        )),
    }
}

lazy_static! {
    static ref FLAG_RE: Regex = Regex::new(r"^\(\?[aiLmsux]+\)").unwrap();
}

/// Extra path components to match at the end of the pattern
#[derive(Clone, Copy)]
pub enum GlobSuffix {
    /// `Empty` means the pattern only matches files, not directories,
    /// so the path needs to match exactly.
    Empty,
    /// `MoreComponents` means the pattern matches directories as well,
    /// so any path that has the pattern as a prefix, should match.
    MoreComponents,
}

impl GlobSuffix {
    pub fn to_re(self) -> PreRegex {
        match self {
            Self::Empty => PreRegex::Eof,
            Self::MoreComponents => PreRegex::SlashOrEof,
        }
    }
}

/// Builds the regex that corresponds to the given pattern.
/// If within a `syntax: regexp` context, returns the pattern,
/// otherwise, returns the corresponding regex.
fn _build_single_regex(
    entry: &IgnorePattern,
    glob_suffix: GlobSuffix,
) -> PatternResult<PreRegex> {
    let IgnorePattern {
        syntax, pattern, ..
    } = entry;
    if pattern.is_empty() {
        return Ok(PreRegex::Empty);
    }
    match syntax {
        PatternSyntax::Regexp => PreRegex::parse(pattern),
        PatternSyntax::RelRegexp => {
            // The `regex` crate accepts `**` while `re2` and Python's `re`
            // do not. Checking for `*` correctly triggers the same error all
            // engines.
            if pattern[0] == b'^'
                || pattern[0] == b'*'
                || pattern.starts_with(b".*")
            {
                return PreRegex::parse(pattern);
            }
            let re = match FLAG_RE.find(pattern) {
                Some(mat) => {
                    let s = mat.start();
                    let e = mat.end();
                    [
                        &b"(?"[..],
                        &pattern[s + 2..e - 1],
                        &b":"[..],
                        if pattern[e] == b'^'
                            || pattern[e] == b'*'
                            || pattern[e..].starts_with(b".*")
                        {
                            &b""[..]
                        } else {
                            &b".*"[..]
                        },
                        &pattern[e..],
                        &b")"[..],
                    ]
                    .concat()
                }
                None => [&b".*"[..], pattern].concat(),
            };
            PreRegex::parse(&re)
        }
        PatternSyntax::Path | PatternSyntax::RelPath => {
            if pattern == b"." {
                return Ok(PreRegex::Empty);
            }
            Ok(PreRegex::Sequence(vec![
                PreRegex::literal(pattern),
                GlobSuffix::MoreComponents.to_re(),
            ]))
        }
        PatternSyntax::RootFilesIn => {
            let re = if pattern == b"." {
                PreRegex::Empty
            } else {
                // Pattern is a directory name.
                let mut pattern = pattern.clone();
                pattern.push(b'/');
                PreRegex::Bytes(pattern)
            };

            // Anything after the pattern must be a non-directory.
            Ok(PreRegex::Sequence(vec![re, PreRegex::parse(b"[^/]+$")?]))
        }
        PatternSyntax::RelGlob => {
            let glob_re = glob_to_re(pattern)?;
            Ok(PreRegex::Sequence(vec![
                glob_re.into_re(false),
                glob_suffix.to_re(),
            ]))
        }
        PatternSyntax::Glob | PatternSyntax::RootGlob => {
            let glob_re = glob_to_re(pattern)?;
            Ok(PreRegex::Sequence(vec![
                glob_re.into_re(true),
                glob_suffix.to_re(),
            ]))
        }
        PatternSyntax::Include
        | PatternSyntax::SubInclude
        | PatternSyntax::ExpandedSubInclude(_)
        | PatternSyntax::FilePath => unreachable!(),
    }
}

const GLOB_SPECIAL_CHARACTERS: [u8; 7] =
    [b'*', b'?', b'[', b']', b'{', b'}', b'\\'];

/// TODO support other platforms
#[cfg(unix)]
pub fn normalize_path_bytes(bytes: &[u8]) -> Vec<u8> {
    if bytes.is_empty() {
        return b".".to_vec();
    }
    let sep = b'/';

    let mut initial_slashes = bytes.iter().take_while(|b| **b == sep).count();
    if initial_slashes > 2 {
        // POSIX allows one or two initial slashes, but treats three or more
        // as single slash.
        initial_slashes = 1;
    }
    let components = bytes
        .split(|b| *b == sep)
        .filter(|c| !(c.is_empty() || c == b"."))
        .fold(vec![], |mut acc, component| {
            if component != b".."
                || (initial_slashes == 0 && acc.is_empty())
                || (!acc.is_empty() && acc[acc.len() - 1] == b"..")
            {
                acc.push(component)
            } else if !acc.is_empty() {
                acc.pop();
            }
            acc
        });
    let mut new_bytes = components.join(&sep);

    if initial_slashes > 0 {
        let mut buf: Vec<_> = (0..initial_slashes).map(|_| sep).collect();
        buf.extend(new_bytes);
        new_bytes = buf;
    }
    if new_bytes.is_empty() {
        b".".to_vec()
    } else {
        new_bytes
    }
}

/// Controls whether we want the emitted regex to cover all cases
/// or just the cases that are not covered by optimized code paths.
#[derive(Debug, Clone, Copy)]
pub enum RegexCompleteness {
    /// `Complete` emits a regex that handles all files, including the ones
    /// that are typically handled by a different code path.
    /// This is used in `hg debugignorerhg -a` to avoid missing some rules.
    Complete,
    /// `ExcludeExactFiles` excludes the patterns that correspond to exact
    /// file matches. This is the normal behavior, and gives a potentially
    /// much smaller regex.
    ExcludeExactFiles,
}

impl RegexCompleteness {
    fn may_exclude_exact_files(self) -> bool {
        match self {
            Self::Complete => false,
            Self::ExcludeExactFiles => true,
        }
    }
}

/// Wrapper function to `_build_single_regex` that short-circuits 'exact' globs
/// that don't need to be transformed into a regex.
pub fn build_single_regex(
    entry: &IgnorePattern,
    glob_suffix: GlobSuffix,
    regex_config: RegexCompleteness,
) -> Result<Option<PreRegex>, PatternError> {
    let IgnorePattern {
        pattern, syntax, ..
    } = entry;
    let pattern = match syntax {
        PatternSyntax::RootGlob
        | PatternSyntax::Path
        | PatternSyntax::RelGlob
        | PatternSyntax::RelPath
        | PatternSyntax::RootFilesIn => normalize_path_bytes(pattern),
        PatternSyntax::Include | PatternSyntax::SubInclude => {
            return Err(PatternError::NonRegexPattern(entry.clone()))
        }
        _ => pattern.to_owned(),
    };
    let is_simple_rootglob = *syntax == PatternSyntax::RootGlob
        && !pattern.iter().any(|b| GLOB_SPECIAL_CHARACTERS.contains(b));
    if regex_config.may_exclude_exact_files()
        && (is_simple_rootglob || syntax == &PatternSyntax::FilePath)
    {
        Ok(None)
    } else {
        let mut entry = entry.clone();
        entry.pattern = pattern;
        Ok(Some(_build_single_regex(&entry, glob_suffix)?))
    }
}

lazy_static! {
    static ref SYNTAXES: FastHashMap<&'static [u8], PatternSyntax> = {
        let mut m = FastHashMap::default();

        m.insert(b"re:".as_ref(), PatternSyntax::Regexp);
        m.insert(b"regexp:".as_ref(), PatternSyntax::Regexp);
        m.insert(b"path:".as_ref(), PatternSyntax::Path);
        m.insert(b"filepath:".as_ref(), PatternSyntax::FilePath);
        m.insert(b"relpath:".as_ref(), PatternSyntax::RelPath);
        m.insert(b"rootfilesin:".as_ref(), PatternSyntax::RootFilesIn);
        m.insert(b"relglob:".as_ref(), PatternSyntax::RelGlob);
        m.insert(b"relre:".as_ref(), PatternSyntax::RelRegexp);
        m.insert(b"glob:".as_ref(), PatternSyntax::Glob);
        m.insert(b"rootglob:".as_ref(), PatternSyntax::RootGlob);
        m.insert(b"include:".as_ref(), PatternSyntax::Include);
        m.insert(b"subinclude:".as_ref(), PatternSyntax::SubInclude);

        m
    };
}

#[derive(Debug)]
pub enum PatternFileWarning {
    /// (file path, syntax bytes)
    InvalidSyntax(PathBuf, Vec<u8>),
    /// File path
    NoSuchFile(PathBuf),
}

pub fn parse_one_pattern(
    pattern: &[u8],
    source: &Path,
    default: PatternSyntax,
    normalize: bool,
) -> IgnorePattern {
    let mut pattern_bytes: &[u8] = pattern;
    let mut syntax = default;

    for (s, val) in SYNTAXES.iter() {
        if let Some(rest) = pattern_bytes.drop_prefix(s) {
            syntax = val.clone();
            pattern_bytes = rest;
            break;
        }
    }

    let pattern = match syntax {
        PatternSyntax::RootGlob
        | PatternSyntax::Path
        | PatternSyntax::Glob
        | PatternSyntax::RelGlob
        | PatternSyntax::RelPath
        | PatternSyntax::RootFilesIn
            if normalize =>
        {
            normalize_path_bytes(pattern_bytes)
        }
        _ => pattern_bytes.to_vec(),
    };

    IgnorePattern {
        syntax,
        pattern,
        source: source.to_owned(),
    }
}

pub fn parse_pattern_file_contents(
    lines: &[u8],
    file_path: &Path,
    default_syntax_override: Option<PatternSyntax>,
    warn: bool,
    relativize: bool,
) -> Result<(Vec<IgnorePattern>, Vec<PatternFileWarning>), PatternError> {
    let comment_regex = Regex::new(r"((?:^|[^\\])(?:\\\\)*)#.*").unwrap();

    #[allow(clippy::trivial_regex)]
    let comment_escape_regex = Regex::new(r"\\#").unwrap();
    let mut inputs: Vec<IgnorePattern> = vec![];
    let mut warnings: Vec<PatternFileWarning> = vec![];

    let mut current_syntax =
        default_syntax_override.unwrap_or(PatternSyntax::RelRegexp);

    for mut line in lines.split(|c| *c == b'\n') {
        let line_buf;
        if line.contains(&b'#') {
            if let Some(cap) = comment_regex.captures(line) {
                line = &line[..cap.get(1).unwrap().end()]
            }
            line_buf = comment_escape_regex.replace_all(line, NoExpand(b"#"));
            line = &line_buf;
        }

        let line = line.trim_end();

        if line.is_empty() {
            continue;
        }

        if let Some(syntax) = line.drop_prefix(b"syntax:") {
            let syntax = syntax.trim();

            if let Some(parsed) =
                SYNTAXES.get([syntax, &b":"[..]].concat().as_slice())
            {
                current_syntax = parsed.clone();
            } else if warn {
                warnings.push(PatternFileWarning::InvalidSyntax(
                    file_path.to_owned(),
                    syntax.to_owned(),
                ));
            }
        } else {
            let pattern = parse_one_pattern(
                line,
                file_path,
                current_syntax.clone(),
                false,
            );
            inputs.push(if relativize {
                pattern.to_relative()
            } else {
                pattern
            })
        }
    }
    Ok((inputs, warnings))
}

pub fn parse_pattern_args(
    patterns: Vec<Vec<u8>>,
    cwd: &Path,
    root: &Path,
) -> Result<Vec<IgnorePattern>, HgPathError> {
    let mut ignore_patterns: Vec<IgnorePattern> = Vec::new();
    for pattern in patterns {
        let pattern = parse_one_pattern(
            &pattern,
            Path::new("<args>"),
            PatternSyntax::RelPath,
            true,
        );
        match pattern.syntax {
            PatternSyntax::RelGlob | PatternSyntax::RelPath => {
                let name = get_path_from_bytes(&pattern.pattern);
                let canon = canonical_path(root, cwd, name)?;
                ignore_patterns.push(IgnorePattern {
                    syntax: pattern.syntax,
                    pattern: get_bytes_from_path(canon),
                    source: pattern.source,
                })
            }
            _ => ignore_patterns.push(pattern.to_owned()),
        };
    }
    Ok(ignore_patterns)
}

pub fn read_pattern_file(
    file_path: &Path,
    warn: bool,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> Result<(Vec<IgnorePattern>, Vec<PatternFileWarning>), PatternError> {
    match std::fs::read(file_path) {
        Ok(contents) => {
            inspect_pattern_bytes(file_path, &contents);
            parse_pattern_file_contents(&contents, file_path, None, warn, true)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok((
            vec![],
            vec![PatternFileWarning::NoSuchFile(file_path.to_owned())],
        )),
        Err(e) => Err(e.into()),
    }
}

/// Represents an entry in an "ignore" file.
#[derive(Debug, Eq, PartialEq, Clone)]
pub struct IgnorePattern {
    pub syntax: PatternSyntax,
    pub pattern: Vec<u8>,
    pub source: PathBuf,
}

impl IgnorePattern {
    pub fn new(syntax: PatternSyntax, pattern: &[u8], source: &Path) -> Self {
        Self {
            syntax,
            pattern: pattern.to_owned(),
            source: source.to_owned(),
        }
    }

    pub fn to_relative(self) -> Self {
        let Self {
            syntax,
            pattern,
            source,
        } = self;
        Self {
            syntax: match syntax {
                PatternSyntax::Regexp => PatternSyntax::RelRegexp,
                PatternSyntax::Glob => PatternSyntax::RelGlob,
                x => x,
            },
            pattern,
            source,
        }
    }
}

pub type PatternResult<T> = Result<T, PatternError>;

/// Wrapper for `read_pattern_file` that also recursively expands `include:`
/// and `subinclude:` patterns.
///
/// The former are expanded in place, while `PatternSyntax::ExpandedSubInclude`
/// is used for the latter to form a tree of patterns.
pub fn get_patterns_from_file(
    pattern_file: &Path,
    root_dir: &Path,
    inspect_pattern_bytes: &mut impl FnMut(&Path, &[u8]),
) -> PatternResult<(Vec<IgnorePattern>, Vec<PatternFileWarning>)> {
    let (patterns, mut warnings) =
        read_pattern_file(pattern_file, true, inspect_pattern_bytes)?;
    let patterns = patterns
        .into_iter()
        .flat_map(|entry| -> PatternResult<_> {
            Ok(match &entry.syntax {
                PatternSyntax::Include => {
                    let inner_include =
                        root_dir.join(get_path_from_bytes(&entry.pattern));
                    let (inner_pats, inner_warnings) = get_patterns_from_file(
                        &inner_include,
                        root_dir,
                        inspect_pattern_bytes,
                    )?;
                    warnings.extend(inner_warnings);
                    inner_pats
                }
                PatternSyntax::SubInclude => {
                    let mut sub_include = SubInclude::new(
                        root_dir,
                        &entry.pattern,
                        &entry.source,
                    )?;
                    let (inner_patterns, inner_warnings) =
                        get_patterns_from_file(
                            &sub_include.path,
                            &sub_include.root,
                            inspect_pattern_bytes,
                        )?;
                    sub_include.included_patterns = inner_patterns;
                    warnings.extend(inner_warnings);
                    vec![IgnorePattern {
                        syntax: PatternSyntax::ExpandedSubInclude(Box::new(
                            sub_include,
                        )),
                        ..entry
                    }]
                }
                _ => vec![entry],
            })
        })
        .flatten()
        .collect();

    Ok((patterns, warnings))
}

/// Holds all the information needed to handle a `subinclude:` pattern.
#[derive(Debug, PartialEq, Eq, Clone)]
pub struct SubInclude {
    /// Will be used for repository (hg) paths that start with this prefix.
    /// It is relative to the current working directory, so comparing against
    /// repository paths is painless.
    pub prefix: HgPathBuf,
    /// The file itself, containing the patterns
    pub path: PathBuf,
    /// Folder in the filesystem where this it applies
    pub root: PathBuf,

    pub included_patterns: Vec<IgnorePattern>,
}

impl SubInclude {
    pub fn new(
        root_dir: &Path,
        pattern: &[u8],
        source: &Path,
    ) -> Result<SubInclude, HgPathError> {
        let normalized_source =
            normalize_path_bytes(&get_bytes_from_path(source));

        let source_root = get_path_from_bytes(&normalized_source);
        let source_root = source_root.parent().unwrap_or(source_root);

        let path = source_root.join(get_path_from_bytes(pattern));
        let new_root = path.parent().unwrap_or_else(|| path.deref());

        let prefix = canonical_path(root_dir, root_dir, new_root)?;

        Ok(Self {
            prefix: path_to_hg_path_buf(prefix).map(|mut p| {
                if !p.is_empty() {
                    p.push_byte(b'/');
                }
                p
            })?,
            path: path.to_owned(),
            root: new_root.to_owned(),
            included_patterns: Vec::new(),
        })
    }
}

/// Separate and pre-process subincludes from other patterns for the "ignore"
/// phase.
pub fn filter_subincludes(
    ignore_patterns: Vec<IgnorePattern>,
) -> Result<(Vec<SubInclude>, Vec<IgnorePattern>), HgPathError> {
    let mut subincludes = vec![];
    let mut others = vec![];

    for pattern in ignore_patterns {
        if let PatternSyntax::ExpandedSubInclude(sub_include) = pattern.syntax
        {
            subincludes.push(*sub_include);
        } else {
            others.push(pattern)
        }
    }
    Ok((subincludes, others))
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;

    fn escape_pattern(pattern: &[u8]) -> Vec<u8> {
        pattern
            .iter()
            .flat_map(|c| RE_ESCAPE[*c as usize].clone())
            .collect()
    }

    #[test]
    fn escape_pattern_test() {
        let untouched =
            br#"!"%',/0123456789:;<=>@ABCDEFGHIJKLMNOPQRSTUVWXYZ_`abcdefghijklmnopqrstuvwxyz"#;
        assert_eq!(escape_pattern(untouched), untouched.to_vec());
        // All escape codes
        assert_eq!(
            escape_pattern(br"()[]{}?*+-|^$\\.&~#\t\n\r\v\f"),
            br"\(\)\[\]\{\}\?\*\+\-\|\^\$\\\\\.\&\~\#\\t\\n\\r\\v\\f".to_vec()
        );
    }

    fn glob_to_re(pat: &[u8]) -> Vec<u8> {
        super::glob_to_re(pat).unwrap().into_re(true).to_bytes()
    }

    #[test]
    fn glob_test() {
        assert_eq!(glob_to_re(br"?"), br".");
        assert_eq!(glob_to_re(br"*"), br"[^/]*");
        assert_eq!(glob_to_re(br"**"), br".*");
        assert_eq!(glob_to_re(br"**/a"), br"(?:.*/)?a");
        assert_eq!(glob_to_re(br"a/**/b"), br"a/(?:.*/)?b");
        assert_eq!(glob_to_re(br"[a*?!^][^b][!c]"), br"[a*?!^][\^b][^c]");
        assert_eq!(glob_to_re(br"{a,b}"), br"(?:a|b)");
        assert_eq!(glob_to_re(br".\*\?"), br"\.\*\?");
    }

    #[test]
    fn test_parse_pattern_file_contents() {
        let lines = b"syntax: glob\n*.elc";

        assert_eq!(
            parse_pattern_file_contents(
                lines,
                Path::new("file_path"),
                None,
                false,
                true,
            )
            .unwrap()
            .0,
            vec![IgnorePattern::new(
                PatternSyntax::RelGlob,
                b"*.elc",
                Path::new("file_path")
            )],
        );

        let lines = b"syntax: include\nsyntax: glob";

        assert_eq!(
            parse_pattern_file_contents(
                lines,
                Path::new("file_path"),
                None,
                false,
                true,
            )
            .unwrap()
            .0,
            vec![]
        );
        let lines = b"glob:**.o";
        assert_eq!(
            parse_pattern_file_contents(
                lines,
                Path::new("file_path"),
                None,
                false,
                true,
            )
            .unwrap()
            .0,
            vec![IgnorePattern::new(
                PatternSyntax::RelGlob,
                b"**.o",
                Path::new("file_path")
            )]
        );
    }

    pub fn build_single_regex(
        entry: &IgnorePattern,
        glob_suffix: GlobSuffix,
    ) -> Result<Option<Vec<u8>>, PatternError> {
        super::build_single_regex(
            entry,
            glob_suffix,
            RegexCompleteness::ExcludeExactFiles,
        )
        .map(|re_opt| re_opt.map(|re| re.to_bytes()))
    }

    #[test]
    fn test_build_single_regex() {
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RelGlob,
                    b"rust/target/",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(br"(?:.*/)?rust/target(?:/|$)".to_vec()),
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::Regexp,
                    br"rust/target/\d+",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(br"rust/target/\d+".to_vec()),
        );
    }

    #[test]
    fn test_build_single_regex_shortcut() {
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RootGlob,
                    b"",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            None,
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RootGlob,
                    b"whatever",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            None,
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RootGlob,
                    b"*.o",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(br"[^/]*\.o(?:/|$)".to_vec()),
        );
    }

    #[test]
    fn test_build_single_relregex() {
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RelRegexp,
                    b"^ba{2}r",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(b"^ba{2}r".to_vec()),
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RelRegexp,
                    b"ba{2}r",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(b".*ba{2}r".to_vec()),
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RelRegexp,
                    b"(?i)ba{2}r",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(b"(?i:.*ba{2}r)".to_vec()),
        );
        assert_eq!(
            build_single_regex(
                &IgnorePattern::new(
                    PatternSyntax::RelRegexp,
                    b"(?i)^ba{2}r",
                    Path::new("")
                ),
                GlobSuffix::MoreComponents
            )
            .unwrap(),
            Some(b"(?i:^ba{2}r)".to_vec()),
        );
    }
}
