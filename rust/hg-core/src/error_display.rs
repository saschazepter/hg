//! The user-facing text for the errors of this crate.
//!
//! The output of these functions is the one expected from `hg` itself (with
//! regards to backwards compatibility), which makes them suitable for `rhg`
//! and for anything that gets called from Python.
//! Other user interfaces are free to come up with their own.

use std::fmt;
use std::fmt::Write;

use format_bytes::DisplayBytes;

use crate::config::ConfigError;
use crate::config::ConfigItemsError;
use crate::config::ConfigParseError;
use crate::config::ConfigParseErrorKind;
use crate::config::ConfigValueParseError;
use crate::dirstate::DirstateError;
use crate::dirstate::on_disk::DirstateV2ParseError;
use crate::encoding::EncodingErrorKind;
use crate::errors::HgError;
use crate::errors::HgIoError;
use crate::errors::IoErrorContext;
use crate::errors::UnsupportedFeatureKind;
use crate::file_index::ErrorKind as FileIndexErrorKind;
use crate::file_patterns::PatternError;
use crate::file_patterns::RegexBuildError;
use crate::narrow::shape::DeserializationError;
use crate::narrow::shape::ErrorKind as ShapeErrorKind;
use crate::requirements::RequirementsErrorKind;
use crate::revlog::GraphError;
use crate::revlog::GraphErrorKind;
use crate::revlog::RevlogError;
use crate::revlog::changelog::ChangelogErrorKind;
use crate::segmented_bytes::ErrorKind as SegmentedBytesErrorKind;
use crate::sparse::SparseConfigError;
use crate::update::UpdateErrorKind;
use crate::utils::docket::DocketError;
use crate::utils::docket::DocketErrorKind;
use crate::utils::hg_path::HgPathError;
use crate::utils::hg_path::HgPathErrorKind;
use crate::utils::strings::Escaped;
use crate::utils::strings::join_display;

/// The prefix for errors where [`HgError::is_unsupported`] is true. The
/// alternate form (`{:#}`) can be used to omit it, for callers that have
/// their own way of reporting such errors.
fn unsupported_prefix(f: &fmt::Formatter) -> &'static str {
    if f.alternate() {
        ""
    } else {
        "unsupported feature: "
    }
}

// TODO: use `DisplayBytes` instead to show non-Unicode filenames losslessly?
pub(crate) fn write_hg_error(
    f: &mut fmt::Formatter,
    error: &HgError,
) -> fmt::Result {
    match error {
        HgError::IO(io_err) => write_io_error(f, io_err),
        HgError::UnsupportedFeature(kind, backtrace) => {
            let prefix = unsupported_prefix(f);
            write!(f, "{}{}", backtrace, prefix)?;
            match kind {
                UnsupportedFeatureKind::BundleRepo => {
                    write!(f, "bundle repository")
                }
                UnsupportedFeatureKind::WdirCat => {
                    write!(f, "cat wdir not implemented")
                }
                UnsupportedFeatureKind::WdirFiles => {
                    write!(f, "list wdir files not implemented")
                }
                UnsupportedFeatureKind::Revset(revset) => {
                    write!(f, "cannot parse revset '{revset}'")
                }
            }
        }
        HgError::AllocationFailed { function, backtrace } => {
            write!(f, "{backtrace}{function} failed to allocate")
        }
        HgError::ConfigValueParseError(error) => {
            write_config_value_parse_error(f, error)
        }
        HgError::Config(config_error) => match &**config_error {
            ConfigError::Parse(ConfigParseError { origin, line, kind }) => {
                // TODO: make `ConfigOrigin` not bytes-only
                let mut origin_bytes = vec![];
                origin
                    .display_bytes(&mut origin_bytes)
                    .map_err(|_| fmt::Error)?;
                write!(
                    f,
                    "config error at {}",
                    String::from_utf8_lossy(&origin_bytes)
                )?;
                if let Some(line) = line {
                    write!(f, ":{line}")?;
                }
                f.write_str(": ")?;
                match kind {
                    ConfigParseErrorKind::CannotInclude { filename, error } => {
                        write!(
                            f,
                            "cannot include {} ({})",
                            String::from_utf8_lossy(filename),
                            error
                        )
                    }
                    ConfigParseErrorKind::UnexpectedLeadingWhitespace(line) => {
                        write!(
                            f,
                            "unexpected leading whitespace: {}",
                            String::from_utf8_lossy(line)
                        )
                    }
                    ConfigParseErrorKind::InvalidLine(line) => {
                        f.write_str(&String::from_utf8_lossy(line))
                    }
                }
            }
            ConfigError::MalformedCliOption { arg, backtrace } => {
                write!(
                    f,
                    "{backtrace}malformed --config option: '{}' \
                    (use --config section.name=value)",
                    String::from_utf8_lossy(arg),
                )
            }
            ConfigError::NoUsername { backtrace } => {
                write!(f, "{backtrace}no username supplied")
            }
            ConfigError::WrongQueryType {
                section, item, backtrace, ..
            } => {
                write!(
                    f,
                    "{backtrace}programming error: wrong query on config \
                    item '{}.{}'",
                    String::from_utf8_lossy(section),
                    String::from_utf8_lossy(item)
                )
            }
            ConfigError::InvalidValue { item, expected, backtrace } => {
                write!(f, "{backtrace}{item} not valid, expected {expected}")
            }
            ConfigError::Items(items_error) => {
                format_config_items_error(f, items_error)
            }
            ConfigError::DefaultItems(items_error) => {
                format_config_items_error(f, items_error)
            }
        },
        HgError::Path(error) => {
            f.write_str(&hg_path_error_to_string(error, None)?)
        }
        HgError::InterruptReceived => write!(f, "interrupt received"),
        HgError::RepoNotFound { at, backtrace } => {
            write!(
                f,
                "{backtrace}no repository found in '{}' (.hg not found)!",
                at.display()
            )
        }
        HgError::SharedPathNotFound { shared_path, backtrace } => {
            write!(
                f,
                "{backtrace}.hg/sharedpath points to nonexistent \
                directory {}",
                shared_path.display()
            )
        }
        HgError::Revlog(revlog_error) => match revlog_error {
            RevlogError::InvalidRevision { backtrace, string } => {
                write!(f, "{backtrace}invalid revision identifier: {string}")
            }
            RevlogError::WDirUnsupported { backtrace } => {
                write!(
                    f,
                    "{backtrace}working directory revision cannot be specified",
                )
            }
            RevlogError::AmbiguousPrefix { backtrace, prefix } => {
                write!(f, "{backtrace}ambiguous revision identifier: {prefix}")
            }
            RevlogError::IO(hg_io_error) => write_io_error(f, hg_io_error),
            RevlogError::CorruptedRevisionData { rev, backtrace } => {
                write!(f, "{}invalid data for revision: {}", backtrace, rev)
            }
            RevlogError::CorruptedDelta { backtrace } => {
                write!(f, "{}patch cannot be decoded", backtrace)
            }
            RevlogError::DeltaInsertsTooMuch { backtrace, len, available } => {
                write!(
                    f,
                    "{}patch inserts more data than available: {} < {}",
                    backtrace, len, available
                )
            }
            RevlogError::InvalidLinkRev { rev, backtrace } => {
                write!(f, "{}linkrev for rev {} is invalid", backtrace, rev)
            }
            RevlogError::Graph(graph_error) => {
                write_graph_error(f, graph_error)
            }
            RevlogError::UnknownFlags { flags, backtrace } => {
                write!(f, "{}unknown revlog index flags: {}", backtrace, flags)
            }
            RevlogError::InvalidCompressionMode { backtrace, mode } => {
                write!(
                    f,
                    "{}invalid data compression mode: {}",
                    backtrace, mode
                )
            }
            RevlogError::InvalidSidedataCompressionMode { backtrace, mode } => {
                write!(
                    f,
                    "{}invalid sidedata compression mode: {}",
                    backtrace, mode
                )
            }
            RevlogError::InvalidPhase { backtrace, value } => {
                write!(f, "{}invalid phase value: {}", backtrace, value)
            }
            RevlogError::HashCheckFailed { backtrace, rev } => {
                write!(f, "{}hash check failed for revision {}", backtrace, rev)
            }
            RevlogError::Compression { backtrace, error } => {
                write!(f, "{}compression error: {}", backtrace, error)
            }
            RevlogError::Decompression { backtrace, error } => {
                write!(f, "{}decompression error: {}", backtrace, error)
            }
            RevlogError::UncompressedLengthMismatch {
                backtrace,
                expected,
                got,
            } => write!(
                f,
                "{}uncompressed length does not match: expected {}, got {}",
                backtrace, expected, got
            ),
            RevlogError::PythonCache { backtrace, message } => {
                write!(f, "{}{}", backtrace, message)
            }
            RevlogError::PythonIncompleteBuffer { backtrace, message } => {
                write!(
                    f,
                    "{}failed to fill Python buffer: {}",
                    backtrace, message
                )
            }
            RevlogError::EllipsisNode { backtrace } => {
                let prefix = unsupported_prefix(f);
                write!(f, "{}{}encountered an ellipsis node", backtrace, prefix)
            }
            RevlogError::InlineDelayedWrite { backtrace } => {
                write!(
                    f,
                    "{}revlog with delayed write should not be inline",
                    backtrace
                )
            }
            RevlogError::UnsupportedRevlogVersion { version, backtrace } => {
                write!(f, "{backtrace}unsupported revlog version '{version}'",)
            }
            RevlogError::InvalidInlineRevlogLength {
                backtrace,
                expected,
                got,
            } => {
                write!(
                    f,
                    "{}unexpected inline revlog length: expected {}, got {}",
                    backtrace, expected, got
                )
            }
            RevlogError::TooLittleDataForHeader { backtrace } => {
                write!(f, "{backtrace}too little data for revlog header")
            }
            RevlogError::CensoredRevision { node, backtrace } => {
                write!(
                    f,
                    "{}censored node: {:x}\n\
                    (set censor.policy to ignore errors)",
                    backtrace,
                    node.short()
                )
            }
            RevlogError::Docket(error) => format_docket_error(f, error),
            RevlogError::CorruptedManifest { backtrace } => {
                write!(f, "{backtrace}corrupted manifest")
            }
            RevlogError::BulkReadDuringWrite { backtrace } => {
                write!(
                    f,
                    "{backtrace}cannot bulk read a revlog that is being \
                     written to"
                )
            }
            RevlogError::CorruptedChangelog { kind, backtrace } => {
                write!(f, "{}", backtrace)?;
                match kind {
                    ChangelogErrorKind::TimestampNotUtf8(error) => {
                        write!(f, "timestamp is not valid UTF-8: {error}")
                    }
                    ChangelogErrorKind::InvalidTimestamp(error) => {
                        write!(f, "failed to parse timestamp: {error}")
                    }
                    ChangelogErrorKind::TimestampOutOfRange(timestamp) => {
                        write!(
                            f,
                            "float timestamp out of valid range: \
                            {timestamp}"
                        )
                    }
                    ChangelogErrorKind::MissingTimezone => {
                        write!(f, "missing timezone")
                    }
                    ChangelogErrorKind::TimezoneNotUtf8(error) => {
                        write!(f, "timezone is not valid UTF-8: {error}")
                    }
                    ChangelogErrorKind::InvalidTimezone(error) => {
                        write!(f, "timezone is not an integer: {error}")
                    }
                    ChangelogErrorKind::TimezoneOutOfBounds(_) => {
                        write!(f, "timezone offset out of bounds")
                    }
                    ChangelogErrorKind::EmptyExtraKey => {
                        write!(f, "empty key in changeset extras")
                    }
                    ChangelogErrorKind::InvalidExtraKey(key) => {
                        write!(
                            f,
                            "invalid key in changeset extras: {}",
                            String::from_utf8_lossy(key)
                        )
                    }
                    ChangelogErrorKind::MissingExtraValue(key) => {
                        write!(f, "missing value for changeset extra: {key}")
                    }
                }
            }
            RevlogError::BadDeltaBase { base, rev, backtrace } => {
                write!(f, "{backtrace}bad base {base} <- {rev}")
            }
            RevlogError::UnboundDeltaChain { base, rev, backtrace } => {
                write!(f, "{backtrace}unbound delta chain {base} <- {rev}")
            }
            RevlogError::WriteOutsideContext { backtrace } => {
                write!(
                    f,
                    "{backtrace}adding revision outside of the \
                    `with_write` context"
                )
            }
            RevlogError::NoDelayNorDivert { backtrace } => {
                write!(
                    f,
                    "{backtrace}neither delay nor divert found on this \
                    revlog"
                )
            }
            RevlogError::UnknownRevlogType { value, backtrace } => {
                write!(f, "{backtrace}Unknown revlog type {value}")
            }
            RevlogError::UnexpectedRevlogType { kind, backtrace } => {
                write!(f, "{backtrace}invalid revlog type {kind}")
            }
            RevlogError::UnsupportedCompressionEngine { name, backtrace } => {
                let prefix = unsupported_prefix(f);
                write!(
                    f,
                    "{backtrace}{prefix}Unsupported compression engine \
                    '{name}'"
                )
            }
            RevlogError::InvalidCompressionLevel {
                config_item,
                level,
                max,
                backtrace,
            } => {
                write!(
                    f,
                    "{backtrace}invalid value for `storage.{config_item}` \
                    config: {level}, expected between 0 and {max} included",
                )
            }
        },
        HgError::Dirstate(dirstate_error) => match dirstate_error {
            DirstateError::V2ParseError(parse) => match parse {
                DirstateV2ParseError::CorruptedTreeMetadata {
                    expected_len,
                    got,
                    backtrace,
                } => {
                    write!(
                        f,
                        "{backtrace}corrupted dirstate tree: \
                        Expected at least {expected_len} bytes, got {got}"
                    )
                }
                DirstateV2ParseError::NotEnoughBytes {
                    start,
                    len,
                    backtrace,
                } => {
                    write!(
                        f,
                        "{backtrace}not enough bytes for dirstate: \
                        expected {len} bytes at offset {start}"
                    )
                }
                DirstateV2ParseError::InvalidSlice {
                    expected_len,
                    got,
                    backtrace,
                } => {
                    write!(f, "{backtrace}invalid dirstate slice: ")?;
                    match expected_len {
                        Some(expected_len) => write!(
                            f,
                            "Expected at least {expected_len} bytes, \
                            got {got}"
                        ),
                        None => write!(f, "Expected byte size overflowed"),
                    }
                }
                DirstateV2ParseError::TimestampNotInRange {
                    truncated_seconds,
                    nanoseconds,
                    backtrace,
                } => {
                    write!(
                        f,
                        "{backtrace}dirstate timestamp not in range \
                        ({truncated_seconds} truncated seconds, \
                        {nanoseconds} nanoseconds)"
                    )
                }
                DirstateV2ParseError::SegmentedBytes(error) => {
                    let backtrace = &error.backtrace;
                    match error.kind {
                        SegmentedBytesErrorKind::StartAfterEnd {
                            start,
                            end,
                        } => {
                            write!(
                                f,
                                "{backtrace}range with start > end: \
                                {start} > {end}"
                            )
                        }
                        SegmentedBytesErrorKind::OutOfBounds { end, len } => {
                            write!(
                                f,
                                "{backtrace}range out of bounds {end} > {len}"
                            )
                        }
                        SegmentedBytesErrorKind::SpansExtents {
                            start,
                            end,
                        } => {
                            write!(
                                f,
                                "{backtrace}slice spans extents: \
                                {start} to {end}"
                            )
                        }
                    }
                }
            },
            DirstateError::PathNotFound(path, backtrace) => {
                write!(f, "{}path not found: {}", backtrace, path)
            }
            DirstateError::InvalidPath(error) => {
                f.write_str(&hg_path_error_to_string(error, None)?)
            }
            DirstateError::TooLittleData(size, backtrace) => {
                write!(
                    f,
                    "{}too little data for dirstate: got {} bytes",
                    backtrace, size
                )
            }
            DirstateError::IncompleteEntry {
                entry_idx,
                at_byte,
                backtrace,
            } => {
                write!(
                    f,
                    "{backtrace}dirstate corrupted: ran out of bytes at \
                    entry header {entry_idx}, offset {at_byte}",
                )
            }
            DirstateError::IncompletePath {
                entry_idx,
                at_byte,
                expected_len,
                backtrace,
            } => {
                write!(
                    f,
                    "{backtrace}dirstate corrupted: ran out of bytes at \
                    entry header {entry_idx}, offset {at_byte} \
                    (expected {expected_len} bytes)",
                )
            }
            DirstateError::BadEntryState(state, backtrace) => {
                write!(f, "{backtrace}incorrect dirstate entry state '{state}'")
            }
            DirstateError::RootNotAtRoot(path, backtrace) => {
                write!(
                    f,
                    "{backtrace}dirstate root node '{path}' \
                    is not at the root"
                )
            }
            DirstateError::BadChildPrefix { path, child_path, backtrace } => {
                write!(
                    f,
                    "{backtrace}path of dirstate child node '{child_path}' \
                    does not start with its parent's path '{path}'"
                )
            }
            DirstateError::ParentNodeNotFound { node, backtrace } => {
                write!(
                    f,
                    "{backtrace}working directory has unknown parent \
                    '{:x}'!",
                    node.short()
                )
            }
        },
        HgError::Pattern(pattern_error) => {
            format_pattern_error(f, pattern_error)
        }
        HgError::Shape(shape_err) => {
            let backtrace = &shape_err.backtrace;
            let msg = match &*shape_err.kind {
                ShapeErrorKind::EmptyShardName => {
                    format!("{backtrace}shard names must not be empty")
                }
                ShapeErrorKind::DotOrHyphenOnlyShardName(name) => format!(
                    "{backtrace}invalid shard name '{name}': \
                    missing lowercase alphanumeric character"
                ),
                ShapeErrorKind::InvalidShardName(name) => format!(
                    "{backtrace}invalid shard name '{name}': \
                    only lowercase alphanumeric, hyphen or dot are accepted"
                ),
                ShapeErrorKind::ReservedName(name) => {
                    format!("{backtrace}shard name '{name}' is reserved")
                }
                ShapeErrorKind::CycleInShards(shard_names) => {
                    let cycle = itertools::Itertools::join(
                        &mut shard_names.iter(),
                        "->",
                    );
                    format!("{backtrace}shards form a cycle: {cycle}")
                }
                ShapeErrorKind::PathInMultipleShards(path) => {
                    format!(
                        "{backtrace}path is found in multiple shards: {}",
                        String::from_utf8_lossy(path.as_bytes())
                    )
                }
                ShapeErrorKind::DuplicateShard(name) => {
                    format!("{backtrace}shard '{name}' defined multiple times")
                }
                ShapeErrorKind::ShardMissingPaths(name) => {
                    format!("{backtrace}shard '{name}' needs `paths`")
                }
                ShapeErrorKind::ProfileMissingIncludes(name) => {
                    format!("{backtrace}profile '{name}' needs `includes`")
                }
                ShapeErrorKind::NoShards => {
                    format!(
                        "{backtrace}`server-sharding` must include at \
                        least one shard"
                    )
                }
                ShapeErrorKind::UnknownInclude { profile, include } => {
                    format!(
                        "{backtrace}profile '{profile}' includes unknown \
                        name '{include}'"
                    )
                }
                ShapeErrorKind::InvalidReadWriteAccess { shard, value } => {
                    format!(
                        "{backtrace}invalid read-write-access value \
                        '{value}' for shard '{shard}': only lowercase \
                        alphanumeric, hyphen or dot are accepted, with at \
                        least one alphanumeric character"
                    )
                }
                ShapeErrorKind::InvalidPath(err) => {
                    let prefix =
                        Some("`server-sharding` contains an invalid path: ");
                    hg_path_error_to_string(err, prefix)?
                }
                ShapeErrorKind::UnknownVersion(version) => {
                    format!(
                        "{backtrace}unknown `server-sharding` \
                        version '{version}'"
                    )
                }
                ShapeErrorKind::ParseError(err) => {
                    format!(
                        "{backtrace}error parsing \
                        `server-sharding`:\n{err}"
                    )
                }
                ShapeErrorKind::PatternError(err) => {
                    return format_pattern_error(f, err);
                }
                ShapeErrorKind::UnknownProfile(name) => {
                    format!("{backtrace}unknown profile '{name}'")
                }
                ShapeErrorKind::NoProfileNames => {
                    format!("{backtrace}at least one profile name is needed")
                }
                ShapeErrorKind::Deserialization(deserialization_error) => {
                    let mut msg =
                        format!("{backtrace}error deserializing shape: ");
                    match deserialization_error {
                        DeserializationError::InvalidLength {
                            expected,
                            got,
                        } => {
                            write!(
                                msg,
                                "invalid length \
                                 (expected {}, got {})",
                                expected, got
                            )?;
                        }
                        DeserializationError::InvalidPath { path } => {
                            let path = String::from_utf8_lossy(path);
                            write!(msg, "invalid path '{}'", path)?;
                        }
                    }
                    msg
                }
            };
            f.write_str(&msg)
        }
        HgError::Update(error) => {
            fmt::Display::fmt(&error.backtrace, f)?;
            match &error.kind {
                UpdateErrorKind::UntrackedFilesDiffer => {
                    write!(
                        f,
                        "untracked files in working directory differ \
                        from files in requested revision"
                    )
                }
                UpdateErrorKind::ThreadPool(error) => {
                    fmt::Display::fmt(error, f)
                }
                UpdateErrorKind::UnknownDirectoryNotEmpty(path) => {
                    write!(
                        f,
                        "conflicting unknown directory '{}' is not empty",
                        path.display()
                    )
                }
                UpdateErrorKind::SimulatedDirstateError => {
                    write!(
                        f,
                        "simulated error while recording dirstate updates"
                    )
                }
            }
        }
        HgError::Sparse(sparse_error) => match sparse_error {
            SparseConfigError::IncludesAfterExcludes { context } => {
                write!(
                    f,
                    "{context} config cannot have includes after excludes"
                )
            }
            SparseConfigError::EntryOutsideSection { context, line } => {
                write!(
                    f,
                    "{context} config entry outside of section: {}",
                    String::from_utf8_lossy(line)
                )
            }
            SparseConfigError::IncludesInNarrow => {
                write!(
                    f,
                    "including other spec files using '%include' is not \
                    supported in narrowspec"
                )
            }
            SparseConfigError::InvalidNarrowPrefix(pattern) => {
                write!(
                    f,
                    "invalid prefix on narrow pattern: {}",
                    String::from_utf8_lossy(pattern)
                )
            }
            SparseConfigError::StaleNarrowspec => {
                write!(f, "working copy's narrowspec is stale")
            }
        },
        HgError::Encoding(error) => {
            write!(f, "{}", error.backtrace)?;
            match &error.kind {
                EncodingErrorKind::UnsupportedEncoding(value) => {
                    write!(
                        f,
                        "{}HGENCODING value '{}' is not supported",
                        unsupported_prefix(f),
                        value.to_string_lossy()
                    )
                }
                EncodingErrorKind::UnsupportedMode(value) => {
                    write!(
                        f,
                        "HGENCODINGMODE value '{}' is not supported",
                        value.to_string_lossy()
                    )
                }
                EncodingErrorKind::UnsupportedAmbiguousWidth(value) => {
                    write!(
                        f,
                        "HGENCODINGAMBIGUOUS value '{}' is not supported",
                        value.to_string_lossy()
                    )
                }
                EncodingErrorKind::InvalidUtf8 { bytes, valid_up_to } => {
                    write!(
                        f,
                        "invalid UTF-8 at offset {}: \"{}\"",
                        valid_up_to,
                        String::from_utf8_lossy(&bytes.escaped_bytes())
                    )
                }
                EncodingErrorKind::InvalidAscii { bytes } => {
                    write!(
                        f,
                        "invalid ASCII: \"{}\"",
                        String::from_utf8_lossy(&bytes.escaped_bytes())
                    )
                }
            }
        }
        HgError::Requirements(error) => {
            write!(f, "{}", error.backtrace)?;
            if error.is_unsupported() {
                f.write_str(unsupported_prefix(f))?;
            }
            match &error.kind {
                RequirementsErrorKind::ParseError => {
                    write!(f, "parse error in 'requires' file")
                }
                RequirementsErrorKind::Unknown(unknown) => {
                    write!(
                        f,
                        "repository requires feature unknown to this \
                        Mercurial: {}",
                        join_display(unknown, ", ")
                    )
                }
                RequirementsErrorKind::Missing(missing) => {
                    write!(
                        f,
                        "repository is missing feature required by this \
                        Mercurial: {}",
                        join_display(missing, ", ")
                    )
                }
                RequirementsErrorKind::NeedExactlyOneOf(one, other) => {
                    write!(
                        f,
                        "bad requirements, need exactly one of {one} or \
                        {other}"
                    )
                }
                RequirementsErrorKind::MutuallyExclusive(one, other) => {
                    write!(
                        f,
                        "bad requirements, {one} and {other} are \
                        mutually exclusive"
                    )
                }
                RequirementsErrorKind::ThinWorkingCopy => {
                    write!(f, "rhg does not support thin working copies")
                }
                RequirementsErrorKind::ShareSafeMismatch => {
                    write!(f, "share-safe mismatch")
                }
                RequirementsErrorKind::Changed => {
                    write!(f, "requirements have changed")
                }
            }
        }
        HgError::Docket(error) => format_docket_error(f, error),
        HgError::FileIndex(error) => {
            write!(f, "{}corrupted fileindex: ", &error.backtrace)?;
            match &error.kind {
                FileIndexErrorKind::BadMetaFilesize => {
                    write!(
                        f,
                        "meta file 'used size' is not a multiple of the record size"
                    )
                }
                FileIndexErrorKind::ListFileOutOfBounds => {
                    write!(f, "list file access out of bounds")
                }
                FileIndexErrorKind::MetaFileOutOfBounds => {
                    write!(f, "meta file access out of bounds")
                }
                FileIndexErrorKind::TreeFileOutOfBounds => {
                    write!(f, "tree file access out of bounds")
                }
                FileIndexErrorKind::TreeFileEof => {
                    write!(f, "unexpected EOF while parsing tree file")
                }
                FileIndexErrorKind::BadRootNode => {
                    write!(f, "invalid root node in tree")
                }
                FileIndexErrorKind::BadSingletonTree => {
                    write!(f, "invalid singleton tree")
                }
                FileIndexErrorKind::BadLeafLabel => {
                    write!(f, "invalid label for leaf node")
                }
            }
        }
    }
}

pub fn hg_path_error_to_string(
    error: &HgPathError,
    prefix: Option<&str>,
) -> Result<String, fmt::Error> {
    let mut buf = error.backtrace.to_string();
    if let Some(prefix) = prefix {
        buf.write_str(prefix)?;
    }

    match &error.kind {
        HgPathErrorKind::LeadingSlash(bytes) => {
            write!(buf, "invalid HgPath '{:?}': has a leading slash.", bytes)
        }
        HgPathErrorKind::ConsecutiveSlashes {
            bytes,
            second_slash_index: pos,
        } => write!(
            buf,
            "invalid HgPath '{:?}': consecutive slashes at pos {}.",
            bytes, pos
        ),
        HgPathErrorKind::ContainsNullByte { bytes, null_byte_index: pos } => {
            write!(
                buf,
                "invalid HgPath '{:?}': contains null byte at pos {}.",
                bytes, pos
            )
        }
        HgPathErrorKind::DecodeError(bytes) => {
            write!(buf, "invalid HgPath '{:?}': could not be decoded.", bytes)
        }
        HgPathErrorKind::EndsWithSlash(path) => {
            write!(buf, "path '{}': ends with a slash", path)
        }
        HgPathErrorKind::ContainsIllegalComponent(path) => {
            write!(buf, "path contains illegal component: {}", path)
        }
        HgPathErrorKind::InsideDotHg(path) => {
            write!(buf, "path '{}' is inside the '.hg' folder", path)
        }
        HgPathErrorKind::IsInsideNestedRepo { path, nested_repo: nested } => {
            write!(buf, "path '{}' is inside nested repo '{}'", path, nested)
        }
        HgPathErrorKind::TraversesSymbolicLink { path, symlink } => {
            write!(buf, "path '{}' traverses symbolic link '{}'", path, symlink)
        }
        HgPathErrorKind::NotFsCompliant(path) => write!(
            buf,
            "path '{}' cannot be turned into a \
                 filesystem path",
            path
        ),
        HgPathErrorKind::NotUnderRoot { path, root } => write!(
            buf,
            "path '{}' not under root {}",
            path.display(),
            root.display()
        ),
    }?;
    Ok(buf)
}

fn format_docket_error(
    f: &mut std::fmt::Formatter<'_>,
    error: &DocketError,
) -> Result<(), std::fmt::Error> {
    let DocketError { docket_path, kind, backtrace } = error;
    match kind {
        DocketErrorKind::Corrupted => {
            write!(f, "{backtrace}corrupted docket: {}", docket_path.display())
        }
        DocketErrorKind::BadFormatMarker => {
            write!(
                f,
                "{backtrace}unrecognized format marker in docket {}",
                docket_path.display()
            )
        }
        DocketErrorKind::DataFileTooSmall { data_path } => {
            write!(
                f,
                "{backtrace}data file {} is smaller than its 'used size' in \
                docket {}",
                data_path.display(),
                docket_path.display()
            )
        }
        DocketErrorKind::ReadRace => {
            write!(
                f,
                "{backtrace}encountered a race condition between reading \
                docket {} and its data file",
                docket_path.display()
            )
        }
        DocketErrorKind::ReadRaceExhausted { tries } => {
            write!(
                f,
                "{backtrace}{} read race happened {tries} times in a row",
                docket_path.display()
            )
        }
        DocketErrorKind::NonUtf8DataFileId => {
            write!(
                f,
                "{backtrace}non-UTF-8 {} data file ID",
                docket_path.display()
            )
        }
        DocketErrorKind::Overflow => {
            write!(
                f,
                "{backtrace}overflow in {} docket serialization",
                docket_path.display()
            )
        }
    }
}

fn format_config_items_error(
    f: &mut std::fmt::Formatter<'_>,
    items_error: &ConfigItemsError,
) -> Result<(), std::fmt::Error> {
    match items_error {
        ConfigItemsError::Toml(error) => fmt::Display::fmt(error, f),
        ConfigItemsError::LambdaWithoutReturn => {
            write!(f, "lambda defined with no return value")
        }
        ConfigItemsError::LazyModuleNameNotString => {
            write!(f, "lazy_module module name should be a string")
        }
        ConfigItemsError::LazyModuleWithoutDefault => {
            write!(f, "lazy_module should have a default value")
        }
        ConfigItemsError::InvalidDefaultType(default_type) => {
            write!(f, "invalid default_type '{default_type}'")
        }
        ConfigItemsError::UndefinedTemplate(template) => {
            write!(
                f,
                "template application refers to undefined template \
                '{template}'"
            )
        }
        ConfigItemsError::InvalidPattern { section, name, error } => {
            write!(
                f,
                "invalid pattern for config item '{}.{}': {}",
                String::from_utf8_lossy(section),
                String::from_utf8_lossy(name),
                error
            )
        }
    }
}

fn format_pattern_error(
    f: &mut std::fmt::Formatter<'_>,
    pattern_error: &PatternError,
) -> Result<(), std::fmt::Error> {
    match pattern_error {
        PatternError::UnsupportedSyntax(syntax, backtrace) => {
            write!(
                f,
                "{backtrace}unsupported syntax '{}'",
                String::from_utf8_lossy(syntax)
            )
        }
        PatternError::IO(error) => fmt::Display::fmt(&error, f),
        PatternError::Path(error) => {
            f.write_str(&hg_path_error_to_string(error, None)?)
        }
        PatternError::NonRegexPattern(pattern, backtrace) => {
            write!(
                f,
                "{backtrace}'{:?}' cannot be turned into a regex",
                pattern
            )
        }
        PatternError::UnclosedGlobAlternation(pattern, backtrace) => {
            write!(
                f,
                "{backtrace} unclosed glob alternation in pattern '{}'",
                String::from_utf8_lossy(pattern)
            )
        }
        PatternError::RegexError { needle, error, backtrace } => {
            // The needle is likely already in the error, but let's
            // be safe
            writeln!(f, "{backtrace}invalid regex '{needle}':")?;
            match error {
                RegexBuildError::Syntax(error) => fmt::Display::fmt(error, f),
                RegexBuildError::Build(error) => fmt::Display::fmt(error, f),
            }
        }
        PatternError::NonUtf8Pattern { pattern, valid_up_to, backtrace } => {
            write!(
                f,
                "{backtrace} non-utf8 regex pattern {}, \
                    valid up to byte {valid_up_to}",
                // This is kind of dumb at face value, but it's
                // better than
                // nothing if we *have* to give a UTF8 output and
                // don't
                // know the encoding, since we may give *some* info
                // about
                // what the pattern is.
                String::from_utf8_lossy(pattern)
            )
        }
        PatternError::UnsupportedSyntaxNarrow(_, backtrace) => {
            write!(f, "{backtrace}only \"path:\" patterns can be fingerprinted")
        }
    }
}

pub(crate) fn write_io_error(
    f: &mut fmt::Formatter,
    error: &HgIoError,
) -> fmt::Result {
    match error {
        HgIoError::IO { kind, context, backtrace, raw_os_error: _ } => {
            write!(f, "{}abort: ", backtrace)?;
            write_io_error_context(f, context)?;
            write!(f, ": {}", kind)
        }
        HgIoError::WriteAttemptInReadonlyVfs(backtrace) => {
            write!(f, "{}abort: attempted write in a readonly vfs", backtrace)
        }
        HgIoError::NonUTF8Lock(backtrace) => {
            write!(f, "{}abort: lock contains non-UTF8 bytes", backtrace)
        }
    }
}

fn write_graph_error(
    f: &mut fmt::Formatter,
    error: &GraphError,
) -> fmt::Result {
    match error.kind {
        GraphErrorKind::ParentOutOfRange(revision) => {
            write!(f, "parent out of range ({})", revision)
        }
        GraphErrorKind::ParentOutOfOrder(revision) => {
            write!(f, "parent out of order ({})", revision)
        }
        GraphErrorKind::P1OutOfRange(revision) => {
            write!(f, "p1 out of range ({})", revision)
        }
        GraphErrorKind::P2OutOfRange(revision) => {
            write!(f, "p2 out of range ({})", revision)
        }
        GraphErrorKind::InconsistentGraphData => {
            write!(f, "inconsistent graph data")
        }
    }
}

pub(crate) fn write_config_value_parse_error(
    f: &mut fmt::Formatter,
    error: &ConfigValueParseError,
) -> fmt::Result {
    // TODO: add origin and line number information, here and in
    // corresponding python code
    write!(
        f,
        "config error: {}.{} is not a {} ('{}')",
        String::from_utf8_lossy(&error.section),
        String::from_utf8_lossy(&error.item),
        error.expected_type,
        String::from_utf8_lossy(&error.value)
    )
}

// TODO: use `DisplayBytes` instead to show non-Unicode filenames losslessly?
fn write_io_error_context(
    f: &mut fmt::Formatter,
    context: &IoErrorContext,
) -> fmt::Result {
    match context {
        IoErrorContext::ReadingMetadata(path) => {
            write!(f, "when reading metadata of {}", path.display())
        }
        IoErrorContext::ReadingFile(path) => {
            write!(f, "when reading {}", path.display())
        }
        IoErrorContext::WritingFile(path) => {
            write!(f, "when writing {}", path.display())
        }
        IoErrorContext::RemovingFile(path) => {
            write!(f, "when removing {}", path.display())
        }
        IoErrorContext::RenamingFile { from, to } => {
            write!(f, "when renaming {} to {}", from.display(), to.display())
        }
        IoErrorContext::CopyingFile { from, to } => {
            write!(f, "when copying {} to {}", from.display(), to.display())
        }
        IoErrorContext::CanonicalizingPath(path) => {
            write!(f, "when canonicalizing {}", path.display())
        }
        IoErrorContext::CurrentDir => {
            write!(f, "error getting current working directory")
        }
        IoErrorContext::CurrentExe => {
            write!(f, "error getting current executable")
        }
    }
}
