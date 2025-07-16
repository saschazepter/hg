use std::collections::HashSet;
use std::fmt::Display;
use std::path::Path;

use format_bytes::format_bytes;
use format_bytes::write_bytes;
use format_bytes::DisplayBytes;

use crate::errors::HgError;
use crate::exit_codes::STATE_ERROR;
use crate::filepatterns::parse_pattern_file_contents;
use crate::filepatterns::IgnorePattern;
use crate::filepatterns::PatternError;
use crate::filepatterns::PatternSyntax;
use crate::matchers::AlwaysMatcher;
use crate::matchers::DifferenceMatcher;
use crate::matchers::IncludeMatcher;
use crate::matchers::Matcher;
use crate::matchers::UnionMatcher;
use crate::narrow::VALID_PREFIXES;
use crate::operations::cat;
use crate::repo::Repo;
use crate::requirements::SPARSE_REQUIREMENT;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::SliceExt;
use crate::warnings::HgWarningSender;
use crate::Node;
use crate::Revision;
use crate::NULL_REVISION;

/// Command which is triggering the config read
#[derive(Copy, Clone, Debug)]
pub enum SparseConfigContext {
    Sparse,
    Narrow,
}

impl DisplayBytes for SparseConfigContext {
    fn display_bytes(
        &self,
        output: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        match self {
            SparseConfigContext::Sparse => write_bytes!(output, b"sparse"),
            SparseConfigContext::Narrow => write_bytes!(output, b"narrow"),
        }
    }
}

impl Display for SparseConfigContext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SparseConfigContext::Sparse => write!(f, "sparse"),
            SparseConfigContext::Narrow => write!(f, "narrow"),
        }
    }
}

/// Possible warnings when reading sparse configuration
#[derive(Debug, derive_more::From)]
pub enum SparseNarrowWarning {
    /// Warns about improper paths that start with "/"
    RootWarning { context: SparseConfigContext, line: Vec<u8> },
    /// Warns about a profile missing from the given changelog revision
    ProfileNotFound { profile: Vec<u8>, node: Option<Node> },
}

/// Parsed sparse config
#[derive(Debug, Default)]
pub struct SparseConfig {
    // Line-separated
    pub(crate) includes: Vec<u8>,
    // Line-separated
    pub(crate) excludes: Vec<u8>,
    pub(crate) profiles: HashSet<Vec<u8>>,
}

/// All possible errors when reading sparse/narrow config
#[derive(Debug, derive_more::From)]
pub enum SparseConfigError {
    IncludesAfterExcludes {
        context: SparseConfigContext,
    },
    EntryOutsideSection {
        context: SparseConfigContext,
        line: Vec<u8>,
    },
    /// Narrow config does not support '%include' directives
    IncludesInNarrow,
    /// An invalid pattern prefix was given to the narrow spec. Includes the
    /// entire pattern for context.
    InvalidNarrowPrefix(Vec<u8>),
    /// Narrow/sparse patterns can not begin or end in whitespace
    /// because the Python parser strips the whitespace when parsing
    /// the config file.
    WhitespaceAtEdgeOfPattern(Vec<u8>),
    #[from]
    HgError(HgError),
    #[from]
    PatternError(PatternError),
}

impl From<SparseConfigError> for HgError {
    fn from(value: SparseConfigError) -> Self {
        match value {
            SparseConfigError::IncludesAfterExcludes { context } => {
                HgError::abort(
                    format!(
                        "{} config cannot have includes after excludes",
                        context,
                    ),
                    STATE_ERROR,
                    None,
                )
            }
            SparseConfigError::EntryOutsideSection { context, line } => {
                HgError::abort(
                    format!(
                        "{} config entry outside of section: {}",
                        context,
                        String::from_utf8_lossy(&line)
                    ),
                    STATE_ERROR,
                    None,
                )
            }
            SparseConfigError::IncludesInNarrow => HgError::abort(
                "including other spec files using '%include' is not \
                supported in narrowspec"
                    .to_string(),
                STATE_ERROR,
                None,
            ),
            SparseConfigError::InvalidNarrowPrefix(vec) => HgError::abort(
                String::from_utf8_lossy(&format_bytes!(
                    b"invalid prefix on narrow pattern: {}",
                    vec
                ))
                .to_string(),
                STATE_ERROR,
                Some(format!(
                    "narrow patterns must begin with one of the following: {}",
                    VALID_PREFIXES.join(", ")
                )),
            ),
            SparseConfigError::WhitespaceAtEdgeOfPattern(vec) => {
                HgError::abort(
                    String::from_utf8_lossy(&format_bytes!(
                        b"narrow pattern with whitespace at the edge: {}",
                        vec
                    ))
                    .to_string(),
                    STATE_ERROR,
                    Some(
                        "narrow patterns can't begin or end in whitespace"
                            .to_string(),
                    ),
                )
            }
            SparseConfigError::HgError(hg_error) => hg_error,
            SparseConfigError::PatternError(pattern_error) => {
                HgError::abort(pattern_error.to_string(), STATE_ERROR, None)
            }
        }
    }
}

/// Parse sparse config file content.
pub(crate) fn parse_config(
    raw: &[u8],
    context: SparseConfigContext,
    warnings: &HgWarningSender,
) -> Result<SparseConfig, SparseConfigError> {
    let mut includes = vec![];
    let mut excludes = vec![];
    let mut profiles = HashSet::new();

    #[derive(PartialEq, Eq)]
    enum Current {
        Includes,
        Excludes,
        None,
    }

    let mut current = Current::None;
    let mut in_section = false;

    for line in raw.split(|c| *c == b'\n') {
        let line = line.trim();
        if line.is_empty() || line[0] == b'#' {
            // empty or comment line, skip
            continue;
        }
        if line.starts_with(b"%include ") {
            let profile = line[b"%include ".len()..].trim();
            if !profile.is_empty() {
                profiles.insert(profile.into());
            }
        } else if line == b"[include]" {
            if in_section && current == Current::Includes {
                return Err(SparseConfigError::IncludesAfterExcludes {
                    context,
                });
            }
            in_section = true;
            current = Current::Includes;
            continue;
        } else if line == b"[exclude]" {
            in_section = true;
            current = Current::Excludes;
        } else {
            if current == Current::None {
                return Err(SparseConfigError::EntryOutsideSection {
                    context,
                    line: line.into(),
                });
            }
            if line.trim().starts_with(b"/") {
                warnings.send(SparseNarrowWarning::RootWarning {
                    context,
                    line: line.into(),
                });
                continue;
            }
            match current {
                Current::Includes => {
                    includes.push(b'\n');
                    includes.extend(line.iter());
                }
                Current::Excludes => {
                    excludes.push(b'\n');
                    excludes.extend(line.iter());
                }
                Current::None => unreachable!(),
            }
        }
    }

    Ok(SparseConfig { includes, excludes, profiles })
}

fn read_temporary_includes(
    repo: &Repo,
) -> Result<Vec<Vec<u8>>, SparseConfigError> {
    let raw = repo.hg_vfs().try_read("tempsparse")?.unwrap_or_default();
    if raw.is_empty() {
        return Ok(vec![]);
    }
    Ok(raw.split(|c| *c == b'\n').map(ToOwned::to_owned).collect())
}

/// Obtain sparse checkout patterns for the given revision
fn patterns_for_rev(
    repo: &Repo,
    rev: Revision,
    warnings: &HgWarningSender,
) -> Result<Option<SparseConfig>, SparseConfigError> {
    if !repo.has_sparse() {
        return Ok(None);
    }
    let raw = repo.hg_vfs().try_read("sparse")?.unwrap_or_default();

    if raw.is_empty() {
        return Ok(None);
    }

    let mut config = parse_config(&raw, SparseConfigContext::Sparse, warnings)?;

    if !config.profiles.is_empty() {
        let mut profiles: Vec<Vec<u8>> = config.profiles.into_iter().collect();
        let mut visited = HashSet::new();

        while let Some(profile) = profiles.pop() {
            if visited.contains(&profile) {
                continue;
            }
            visited.insert(profile.to_owned());

            let output =
                cat(repo, &rev.to_string(), vec![HgPath::new(&profile)])
                    .map_err(|_| {
                        HgError::corrupted(
                            "dirstate points to non-existent parent node"
                                .to_string(),
                        )
                    })?;
            if output.results.is_empty() {
                warnings.send(SparseNarrowWarning::ProfileNotFound {
                    profile: profile.to_owned(),
                    node: repo.node(rev.into()),
                });
                continue;
            }

            let subconfig = parse_config(
                &output.results[0].1,
                SparseConfigContext::Sparse,
                warnings,
            )?;
            if !subconfig.includes.is_empty() {
                config.includes.push(b'\n');
                config.includes.extend(&subconfig.includes);
            }
            if !subconfig.includes.is_empty() {
                config.includes.push(b'\n');
                config.excludes.extend(&subconfig.excludes);
            }
            profiles.extend(subconfig.profiles.into_iter());
        }

        config.profiles = visited;
    }

    if !config.includes.is_empty() {
        config.includes.extend(b"\n.hg*");
    }

    Ok(Some(config))
}

/// Obtain a matcher for sparse working directories.
pub fn matcher(
    repo: &Repo,
    revs: Option<Vec<Revision>>,
    warnings: &HgWarningSender,
) -> Result<Box<dyn Matcher + Send>, SparseConfigError> {
    if !repo.requirements().contains(SPARSE_REQUIREMENT) {
        return Ok(Box::new(AlwaysMatcher));
    }

    let revs = if let Some(revs) = revs {
        revs
    } else {
        dirstate_parent_revs(repo)?
    };
    let mut matchers = vec![];

    for rev in revs.iter() {
        let config = patterns_for_rev(repo, *rev, warnings);
        if let Ok(Some(config)) = config {
            let mut m: Box<dyn Matcher + Send> = Box::new(AlwaysMatcher);
            if !config.includes.is_empty() {
                let patterns = parse_pattern_file_contents(
                    &config.includes,
                    Path::new(""),
                    Some(PatternSyntax::Glob),
                    false,
                    false,
                    warnings,
                )?;
                m = Box::new(IncludeMatcher::new(patterns)?);
            }
            if !config.excludes.is_empty() {
                let patterns = parse_pattern_file_contents(
                    &config.excludes,
                    Path::new(""),
                    Some(PatternSyntax::Glob),
                    false,
                    false,
                    warnings,
                )?;
                m = Box::new(DifferenceMatcher::new(
                    m,
                    Box::new(IncludeMatcher::new(patterns)?),
                ));
            }
            matchers.push(m);
        }
    }
    let result: Box<dyn Matcher + Send> = match matchers.len() {
        0 => Box::new(AlwaysMatcher),
        1 => matchers.pop().expect("1 is equal to 0"),
        _ => Box::new(UnionMatcher::new(matchers)),
    };

    let matcher =
        force_include_matcher(result, &read_temporary_includes(repo)?)?;
    Ok(matcher)
}

/// Return the revs for non-null dirstate parents
fn dirstate_parent_revs(
    repo: &Repo,
) -> Result<Vec<Revision>, SparseConfigError> {
    let parents = repo.dirstate_parents()?;
    let mut revs = vec![];
    let p1_rev =
        repo.changelog()?.rev_from_node(parents.p1.into()).map_err(|_| {
            HgError::corrupted(
                "dirstate points to non-existent parent node".to_string(),
            )
        })?;
    if p1_rev != NULL_REVISION {
        revs.push(p1_rev)
    }
    let p2_rev =
        repo.changelog()?.rev_from_node(parents.p2.into()).map_err(|_| {
            HgError::corrupted(
                "dirstate points to non-existent parent node".to_string(),
            )
        })?;
    if p2_rev != NULL_REVISION {
        revs.push(p2_rev)
    }
    Ok(revs)
}

pub fn active_profiles(
    repo: &Repo,
    warnings: &HgWarningSender,
) -> Result<HashSet<Vec<u8>>, HgError> {
    let revs = dirstate_parent_revs(repo)?;
    let mut profiles = HashSet::new();
    for rev in revs {
        if let Some(config) = patterns_for_rev(repo, rev, warnings)? {
            profiles.extend(config.profiles.into_iter());
        }
    }
    Ok(profiles)
}

/// Returns a matcher that returns true for any of the forced includes before
/// testing against the actual matcher
fn force_include_matcher(
    result: Box<dyn Matcher + Send>,
    temp_includes: &[Vec<u8>],
) -> Result<Box<dyn Matcher + Send>, PatternError> {
    if temp_includes.is_empty() {
        return Ok(result);
    }
    let forced_include_matcher = IncludeMatcher::new(
        temp_includes
            .iter()
            .map(|include| {
                IgnorePattern::new(PatternSyntax::Path, include, Path::new(""))
            })
            .collect(),
    )?;
    Ok(Box::new(UnionMatcher::new(vec![
        Box::new(forced_include_matcher),
        result,
    ])))
}
