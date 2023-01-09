use std::path::Path;

use crate::{
    errors::HgError,
    exit_codes,
    filepatterns::parse_pattern_file_contents,
    matchers::{
        AlwaysMatcher, DifferenceMatcher, IncludeMatcher, Matcher,
        NeverMatcher,
    },
    repo::Repo,
    requirements::NARROW_REQUIREMENT,
    sparse::{self, SparseConfigError, SparseWarning},
};

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
const VALID_PREFIXES: [&str; 2] = ["path:", "rootfilesin:"];

/// Return the matcher for the current narrow spec, and all configuration
/// warnings to display.
pub fn matcher(
    repo: &Repo,
) -> Result<(Box<dyn Matcher + Sync>, Vec<SparseWarning>), SparseConfigError> {
    let mut warnings = vec![];
    if !repo.requirements().contains(NARROW_REQUIREMENT) {
        return Ok((Box::new(AlwaysMatcher), warnings));
    }
    // Treat "narrowspec does not exist" the same as "narrowspec file exists
    // and is empty".
    let store_spec = repo.store_vfs().try_read(FILENAME)?.unwrap_or(vec![]);
    let working_copy_spec =
        repo.hg_vfs().try_read(DIRSTATE_FILENAME)?.unwrap_or(vec![]);
    if store_spec != working_copy_spec {
        return Err(HgError::abort(
            "working copy's narrowspec is stale",
            exit_codes::STATE_ERROR,
            Some("run 'hg tracked --update-working-copy'".into()),
        )
        .into());
    }

    let config = sparse::parse_config(
        &store_spec,
        sparse::SparseConfigContext::Narrow,
    )?;

    warnings.extend(config.warnings);

    if !config.profiles.is_empty() {
        // TODO (from Python impl) maybe do something with profiles?
        return Err(SparseConfigError::IncludesInNarrow);
    }
    validate_patterns(&config.includes)?;
    validate_patterns(&config.excludes)?;

    if config.includes.is_empty() {
        return Ok((Box::new(NeverMatcher), warnings));
    }

    let (patterns, subwarnings) = parse_pattern_file_contents(
        &config.includes,
        Path::new(""),
        None,
        false,
    )?;
    warnings.extend(subwarnings.into_iter().map(From::from));

    let mut m: Box<dyn Matcher + Sync> =
        Box::new(IncludeMatcher::new(patterns)?);

    let (patterns, subwarnings) = parse_pattern_file_contents(
        &config.excludes,
        Path::new(""),
        None,
        false,
    )?;
    if !patterns.is_empty() {
        warnings.extend(subwarnings.into_iter().map(From::from));
        let exclude_matcher = Box::new(IncludeMatcher::new(patterns)?);
        m = Box::new(DifferenceMatcher::new(m, exclude_matcher));
    }

    Ok((m, warnings))
}

fn validate_patterns(patterns: &[u8]) -> Result<(), SparseConfigError> {
    for pattern in patterns.split(|c| *c == b'\n') {
        if pattern.is_empty() {
            continue;
        }
        for prefix in VALID_PREFIXES.iter() {
            if pattern.starts_with(prefix.as_bytes()) {
                return Ok(());
            }
        }
        return Err(SparseConfigError::InvalidNarrowPrefix(
            pattern.to_owned(),
        ));
    }
    Ok(())
}
