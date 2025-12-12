use std::cmp::Ordering;
use std::path::Path;

use crate::errors::HgError;
use crate::exit_codes;
use crate::file_patterns::parse_pattern_file_contents;
use crate::file_patterns::FilePattern;
use crate::file_patterns::PatternSyntax;
use crate::matchers::AlwaysMatcher;
use crate::matchers::DifferenceMatcher;
use crate::matchers::IncludeMatcher;
use crate::matchers::Matcher;
use crate::matchers::NeverMatcher;
use crate::narrow::shape::ShardTreeNode;
use crate::repo::Repo;
use crate::requirements::NARROW_REQUIREMENT;
use crate::sparse::SparseConfigError;
use crate::sparse::{self};
use crate::warnings::HgWarningSender;

pub mod shape;

/// The file in .hg/store/ that indicates which paths exit in the store
const FILENAME: &str = "narrowspec";
/// The file in .hg/ that indicates which paths exit in the dirstate
const DIRSTATE_FILENAME: &str = "narrowspec.dirstate";

/// Pattern prefixes that are allowed in narrow patterns. This list MUST
/// only contain patterns that are fast and safe to evaluate. Keep in mind
/// that patterns are supplied by clients and executed on remote servers
/// as part of wire protocol commands. That means that changes to this
/// data structure influence the wire protocol and should not be taken
/// lightly - especially removals.
pub const VALID_PREFIXES: [&str; 2] = ["path:", "rootfilesin:"];

/// Compares two patterns.
///
/// [`FilePattern`] does not implement [`Ord`] because it's complicated with
/// [`PatternSyntax::Include`], but for narrowspecs we only have to deal with
/// the types of patterns allowed by [`VALID_PREFIXES`].
fn cmp_patterns(lhs: &FilePattern, rhs: &FilePattern) -> Ordering {
    let kind = |pattern: &FilePattern| match pattern.syntax {
        PatternSyntax::Path => 0,
        PatternSyntax::RootFilesIn => 1,
        _ => panic!("narrowspec only allows path: and rootfilesin:"),
    };
    let key = |pattern| (kind(pattern), &pattern.raw);
    Ord::cmp(&key(lhs), &key(rhs))
}

/// Return the matcher for the current narrow spec, and all configuration
/// warnings to display.
pub fn matcher(
    repo: &Repo,
    warnings: &HgWarningSender,
) -> Result<Box<dyn Matcher + Send>, SparseConfigError> {
    if !repo.requirements().contains(NARROW_REQUIREMENT) {
        return Ok(Box::new(AlwaysMatcher));
    }
    let patterns = store_patterns(warnings, repo)?;

    let Some((include_patterns, exclude_patterns)) = patterns else {
        return Ok(Box::new(NeverMatcher));
    };

    // The old way only works for simple cases. Nested excludes/includes
    // don't work and we need them for shapes, but only for `path:` patterns.
    //
    // `rootfilesin:` does not use the new logic yet because they make the code
    // more complex and are not needed by shapes. Maybe we'll end up
    // implementing it.
    if let Ok(tree) =
        ShardTreeNode::from_patterns(&include_patterns, &exclude_patterns)
    {
        let new_matcher = tree.matcher();
        return Ok(new_matcher);
    }

    // Fall back to the old way of matching
    let mut m: Box<dyn Matcher + Send> =
        Box::new(IncludeMatcher::new(include_patterns)?);

    if !exclude_patterns.is_empty() {
        let exclude_matcher = Box::new(IncludeMatcher::new(exclude_patterns)?);
        m = Box::new(DifferenceMatcher::new(m, exclude_matcher));
    }

    Ok(m)
}

/// Get the store narrow patterns for `repo`.
///
/// # Errors
///
/// Will return an error if the working copy's narrowspec doesn't contain the
/// same patterns as the one from the store, or if either fail to parse.
pub fn store_patterns(
    warnings: &HgWarningSender,
    repo: &Repo,
) -> Result<Option<NarrowPatterns>, HgError> {
    // Treat "narrowspec does not exist" the same as "narrowspec file exists
    // and is empty
    let store_patterns = patterns_from_spec(
        warnings,
        &repo.store_vfs().try_read(FILENAME)?.unwrap_or_default(),
    )?;
    let working_copy_patterns = patterns_from_spec(
        warnings,
        &repo.hg_vfs().try_read(DIRSTATE_FILENAME)?.unwrap_or_default(),
    )?;
    if store_patterns != working_copy_patterns {
        return Err(HgError::abort(
            "abort: working copy's narrowspec is stale",
            exit_codes::STATE_ERROR,
            Some("run 'hg tracked --update-working-copy'".into()),
        ));
    }
    Ok(store_patterns)
}

/// Raw patterns as deserialized and validated
type NarrowPatterns = (Vec<FilePattern>, Vec<FilePattern>);

/// Get the validated narrow patterns for a given spec
pub fn patterns_from_spec(
    warnings: &HgWarningSender,
    spec: &[u8],
) -> Result<Option<NarrowPatterns>, SparseConfigError> {
    let config = sparse::parse_config(
        spec,
        sparse::SparseConfigContext::Narrow,
        warnings,
    )?;
    if !config.profiles.is_empty() {
        // TODO (from Python impl) maybe do something with profiles?
        return Err(SparseConfigError::IncludesInNarrow);
    }
    validate_patterns(&config.includes)?;
    validate_patterns(&config.excludes)?;
    if config.includes.is_empty() {
        return Ok(None);
    }
    let mut include_patterns = parse_pattern_file_contents(
        &config.includes,
        Path::new(""),
        None,
        false,
        true,
        warnings,
    )?;
    let mut exclude_patterns = parse_pattern_file_contents(
        &config.excludes,
        Path::new(""),
        None,
        false,
        true,
        warnings,
    )?;
    include_patterns.sort_by(cmp_patterns);
    exclude_patterns.sort_by(cmp_patterns);
    Ok(Some((include_patterns, exclude_patterns)))
}

fn is_whitespace(b: &u8) -> bool {
    // should match what .strip() in Python does
    b.is_ascii_whitespace() || *b == 0x0b
}

fn starts_or_ends_with_whitespace(s: &[u8]) -> bool {
    let w = |b: Option<&u8>| b.map(is_whitespace).unwrap_or(false);
    w(s.first()) || w(s.last())
}

fn validate_pattern(pattern: &[u8]) -> Result<(), SparseConfigError> {
    if starts_or_ends_with_whitespace(pattern) {
        return Err(SparseConfigError::WhitespaceAtEdgeOfPattern(
            pattern.to_owned(),
        ));
    }
    for prefix in VALID_PREFIXES.iter() {
        if pattern.starts_with(prefix.as_bytes()) {
            return Ok(());
        }
    }
    Err(SparseConfigError::InvalidNarrowPrefix(pattern.to_owned()))
}

fn validate_patterns(patterns: &[u8]) -> Result<(), SparseConfigError> {
    for pattern in patterns.split(|c| *c == b'\n') {
        if pattern.is_empty() {
            // TODO: probably not intentionally allowed (only because `split`
            // produces "fake" empty line at the end)
            continue;
        }
        validate_pattern(pattern)?
    }
    Ok(())
}
