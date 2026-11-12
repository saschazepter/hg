//! The user-facing text for the errors of this crate.
//!
//! None of the error types implement [`std::fmt::Display`]: turning an error
//! into text is a decision for the user interface to make, and it has to be
//! made explicitly by calling one of the functions of this module.
//!
//! The output of these functions is the one expected from `hg` itself (with
//! regards to backwards compatibility), which makes them suitable for `rhg`
//! and for anything that gets called from Python.
//! Other user interfaces are free to come up with their own.

use std::io;
use std::io::Write;

use format_bytes::Utf8;
use format_bytes::write_bytes;

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
use crate::utils::files::get_bytes_from_path;
use crate::utils::hg_path::HgPathError;
use crate::utils::hg_path::HgPathErrorKind;
use crate::utils::strings::Escaped;
use crate::utils::strings::join_display;

const INFALLIBLE: &str = "writing to a `Vec` cannot fail";

/// The text that `hg` is expected to show for this error, without the
/// `abort: ` prefix (except for I/O errors, which have it for historical
/// reasons), the exit code or the hint: see the methods of [`HgError`] for
/// those.
///
/// This is bytes and not a string because errors can contain things like
/// paths or config values, which are in an arbitrary encoding.
pub fn hg_error_to_bytes(error: &HgError) -> Vec<u8> {
    let mut buf = vec![];
    write_hg_error(&mut buf, error, true).expect(INFALLIBLE);
    buf
}

/// Same as [`hg_error_to_bytes`], but without the "unsupported feature"
/// prefix of the errors where [`HgError::is_unsupported`] is true, for callers
/// that have their own way of reporting such errors.
pub fn hg_error_to_bytes_without_unsupported_prefix(
    error: &HgError,
) -> Vec<u8> {
    let mut buf = vec![];
    write_hg_error(&mut buf, error, false).expect(INFALLIBLE);
    buf
}

/// The text that `hg` is expected to show for this I/O error
pub fn io_error_to_bytes(error: &HgIoError) -> Vec<u8> {
    let mut buf = vec![];
    write_io_error(&mut buf, error).expect(INFALLIBLE);
    buf
}

/// The text that `hg` is expected to show for this config parsing error
pub fn config_value_parse_error_to_bytes(
    error: &ConfigValueParseError,
) -> Vec<u8> {
    let mut buf = vec![];
    write_config_value_parse_error(&mut buf, error).expect(INFALLIBLE);
    buf
}

/// The text that `hg` is expected to show for this path error, with an
/// optional prefix.
pub fn hg_path_error_to_bytes(
    error: &HgPathError,
    prefix: Option<&str>,
) -> Vec<u8> {
    let mut buf = vec![];
    write_hg_path_error(&mut buf, error, prefix).expect(INFALLIBLE);
    buf
}

/// The prefix for errors where [`HgError::is_unsupported`] is true.
fn unsupported_prefix(with_prefix: bool) -> &'static str {
    if with_prefix {
        "unsupported feature: "
    } else {
        ""
    }
}

fn write_hg_error(
    f: &mut Vec<u8>,
    error: &HgError,
    with_unsupported_prefix: bool,
) -> io::Result<()> {
    match error {
        HgError::IO(io_err) => write_io_error(f, io_err),
        HgError::UnsupportedFeature(kind, backtrace) => {
            let prefix = unsupported_prefix(with_unsupported_prefix);
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
                write_bytes!(f, b"config error at {}", origin)?;
                if let Some(line) = line {
                    write!(f, ":{line}")?;
                }
                f.write_all(b": ")?;
                match kind {
                    ConfigParseErrorKind::CannotInclude { filename, error } => {
                        write_bytes!(
                            f,
                            b"cannot include {} ({})",
                            filename,
                            Utf8(error)
                        )
                    }
                    ConfigParseErrorKind::UnexpectedLeadingWhitespace(line) => {
                        write_bytes!(
                            f,
                            b"unexpected leading whitespace: {}",
                            line
                        )
                    }
                    ConfigParseErrorKind::InvalidLine(line) => {
                        f.write_all(line)
                    }
                }
            }
            ConfigError::MalformedCliOption { arg, backtrace } => {
                write_bytes!(
                    f,
                    b"{}malformed --config option: '{}' \
                    (use --config section.name=value)",
                    backtrace,
                    arg,
                )
            }
            ConfigError::NoUsername { backtrace } => {
                write!(f, "{backtrace}no username supplied")
            }
            ConfigError::WrongQueryType {
                section, item, backtrace, ..
            } => {
                write_bytes!(
                    f,
                    b"{}programming error: wrong query on config \
                    item '{}.{}'",
                    backtrace,
                    section,
                    item
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
        HgError::Path(error) => write_hg_path_error(f, error, None),
        HgError::InterruptReceived => write!(f, "interrupt received"),
        HgError::RepoNotFound { at, backtrace } => {
            write_bytes!(
                f,
                b"{}no repository found in '{}' (.hg not found)!",
                backtrace,
                get_bytes_from_path(at)
            )
        }
        HgError::SharedPathNotFound { shared_path, backtrace } => {
            write_bytes!(
                f,
                b"{}.hg/sharedpath points to nonexistent directory {}",
                backtrace,
                get_bytes_from_path(shared_path)
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
                let prefix = unsupported_prefix(with_unsupported_prefix);
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
            RevlogError::Docket(error) => write_docket_error(f, error),
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
                        write_bytes!(
                            f,
                            b"invalid key in changeset extras: {}",
                            key
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
                let prefix = unsupported_prefix(with_unsupported_prefix);
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
                write_bytes!(
                    f,
                    b"{}path not found: {}",
                    backtrace,
                    path.as_bytes()
                )
            }
            DirstateError::InvalidPath(error) => {
                write_hg_path_error(f, error, None)
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
                write_bytes!(
                    f,
                    b"{}dirstate root node '{}' is not at the root",
                    backtrace,
                    path.as_bytes()
                )
            }
            DirstateError::BadChildPrefix { path, child_path, backtrace } => {
                write_bytes!(
                    f,
                    b"{}path of dirstate child node '{}' \
                    does not start with its parent's path '{}'",
                    backtrace,
                    child_path.as_bytes(),
                    path.as_bytes()
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
            match &*shape_err.kind {
                ShapeErrorKind::EmptyShardName => {
                    write!(f, "{backtrace}shard names must not be empty")
                }
                ShapeErrorKind::DotOrHyphenOnlyShardName(name) => write!(
                    f,
                    "{backtrace}invalid shard name '{name}': \
                    missing lowercase alphanumeric character"
                ),
                ShapeErrorKind::InvalidShardName(name) => write!(
                    f,
                    "{backtrace}invalid shard name '{name}': \
                    only lowercase alphanumeric, hyphen or dot are accepted"
                ),
                ShapeErrorKind::ReservedName(name) => {
                    write!(f, "{backtrace}shard name '{name}' is reserved")
                }
                ShapeErrorKind::CycleInShards(shard_names) => {
                    let cycle = itertools::Itertools::join(
                        &mut shard_names.iter(),
                        "->",
                    );
                    write!(f, "{backtrace}shards form a cycle: {cycle}")
                }
                ShapeErrorKind::PathInMultipleShards(path) => {
                    write_bytes!(
                        f,
                        b"{}path is found in multiple shards: {}",
                        backtrace,
                        path.as_bytes()
                    )
                }
                ShapeErrorKind::DuplicateShard(name) => {
                    write!(
                        f,
                        "{backtrace}shard '{name}' defined multiple times"
                    )
                }
                ShapeErrorKind::ShardMissingPaths(name) => {
                    write!(f, "{backtrace}shard '{name}' needs `paths`")
                }
                ShapeErrorKind::ProfileMissingIncludes(name) => {
                    write!(f, "{backtrace}profile '{name}' needs `includes`")
                }
                ShapeErrorKind::NoShards => {
                    write!(
                        f,
                        "{backtrace}`server-sharding` must include at \
                        least one shard"
                    )
                }
                ShapeErrorKind::UnknownInclude { profile, include } => {
                    write!(
                        f,
                        "{backtrace}profile '{profile}' includes unknown \
                        name '{include}'"
                    )
                }
                ShapeErrorKind::InvalidReadWriteAccess { shard, value } => {
                    write!(
                        f,
                        "{backtrace}invalid read-write-access value \
                        '{value}' for shard '{shard}': only lowercase \
                        alphanumeric, hyphen or dot are accepted, with at \
                        least one alphanumeric character"
                    )
                }
                ShapeErrorKind::InvalidPath(err) => {
                    let prefix =
                        Some("`server-sharding` contains an invalid path: ");
                    write_hg_path_error(f, err, prefix)
                }
                ShapeErrorKind::UnknownVersion(version) => {
                    write!(
                        f,
                        "{backtrace}unknown `server-sharding` \
                        version '{version}'"
                    )
                }
                ShapeErrorKind::ParseError(err) => {
                    write!(
                        f,
                        "{backtrace}error parsing `server-sharding`:\n{err}"
                    )
                }
                ShapeErrorKind::PatternError(err) => {
                    format_pattern_error(f, err)
                }
                ShapeErrorKind::UnknownProfile(name) => {
                    write!(f, "{backtrace}unknown profile '{name}'")
                }
                ShapeErrorKind::NoProfileNames => {
                    write!(f, "{backtrace}at least one profile name is needed")
                }
                ShapeErrorKind::Deserialization(deserialization_error) => {
                    write!(f, "{backtrace}error deserializing shape: ")?;
                    match deserialization_error {
                        DeserializationError::InvalidLength {
                            expected,
                            got,
                        } => {
                            write!(
                                f,
                                "invalid length (expected {}, got {})",
                                expected, got
                            )
                        }
                        DeserializationError::InvalidPath { path } => {
                            write_bytes!(f, b"invalid path '{}'", path)
                        }
                    }
                }
            }
        }
        HgError::Update(error) => {
            write!(f, "{}", error.backtrace)?;
            match &error.kind {
                UpdateErrorKind::UntrackedFilesDiffer => {
                    write!(
                        f,
                        "untracked files in working directory differ \
                        from files in requested revision"
                    )
                }
                UpdateErrorKind::ThreadPool(error) => {
                    write!(f, "{}", error)
                }
                UpdateErrorKind::UnknownDirectoryNotEmpty(path) => {
                    write_bytes!(
                        f,
                        b"conflicting unknown directory '{}' is not empty",
                        get_bytes_from_path(path)
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
                write_bytes!(
                    f,
                    b"{} config cannot have includes after excludes",
                    context
                )
            }
            SparseConfigError::EntryOutsideSection { context, line } => {
                write_bytes!(
                    f,
                    b"{} config entry outside of section: {}",
                    context,
                    line
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
                write_bytes!(
                    f,
                    b"invalid prefix on narrow pattern: {}",
                    pattern
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
                    write_bytes!(
                        f,
                        b"{}HGENCODING value '{}' is not supported",
                        unsupported_prefix(with_unsupported_prefix).as_bytes(),
                        value.as_encoded_bytes()
                    )
                }
                EncodingErrorKind::UnsupportedMode(value) => {
                    write_bytes!(
                        f,
                        b"HGENCODINGMODE value '{}' is not supported",
                        value.as_encoded_bytes()
                    )
                }
                EncodingErrorKind::UnsupportedAmbiguousWidth(value) => {
                    write_bytes!(
                        f,
                        b"HGENCODINGAMBIGUOUS value '{}' is not supported",
                        value.as_encoded_bytes()
                    )
                }
                EncodingErrorKind::InvalidUtf8 { bytes, valid_up_to } => {
                    write_bytes!(
                        f,
                        b"invalid UTF-8 at offset {}: \"{}\"",
                        valid_up_to,
                        bytes.escaped_bytes()
                    )
                }
                EncodingErrorKind::InvalidAscii { bytes } => {
                    write_bytes!(
                        f,
                        b"invalid ASCII: \"{}\"",
                        bytes.escaped_bytes()
                    )
                }
            }
        }
        HgError::Requirements(error) => {
            write!(f, "{}", error.backtrace)?;
            if error.is_unsupported() {
                f.write_all(
                    unsupported_prefix(with_unsupported_prefix).as_bytes(),
                )?;
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
        HgError::Docket(error) => write_docket_error(f, error),
        HgError::FileIndex(error) => {
            write!(f, "{}corrupted fileindex: ", error.backtrace)?;
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

fn write_hg_path_error(
    f: &mut Vec<u8>,
    error: &HgPathError,
    prefix: Option<&str>,
) -> io::Result<()> {
    write!(f, "{}", error.backtrace)?;
    if let Some(prefix) = prefix {
        f.write_all(prefix.as_bytes())?;
    }

    match &error.kind {
        HgPathErrorKind::LeadingSlash(bytes) => {
            write!(f, "invalid HgPath '{:?}': has a leading slash.", bytes)
        }
        HgPathErrorKind::ConsecutiveSlashes {
            bytes,
            second_slash_index: pos,
        } => write!(
            f,
            "invalid HgPath '{:?}': consecutive slashes at pos {}.",
            bytes, pos
        ),
        HgPathErrorKind::ContainsNullByte { bytes, null_byte_index: pos } => {
            write!(
                f,
                "invalid HgPath '{:?}': contains null byte at pos {}.",
                bytes, pos
            )
        }
        HgPathErrorKind::DecodeError(bytes) => {
            write!(f, "invalid HgPath '{:?}': could not be decoded.", bytes)
        }
        HgPathErrorKind::EndsWithSlash(path) => {
            write_bytes!(f, b"path '{}': ends with a slash", path.as_bytes())
        }
        HgPathErrorKind::ContainsIllegalComponent(path) => {
            write_bytes!(
                f,
                b"path contains illegal component: {}",
                path.as_bytes()
            )
        }
        HgPathErrorKind::InsideDotHg(path) => {
            write_bytes!(
                f,
                b"path '{}' is inside the '.hg' folder",
                path.as_bytes()
            )
        }
        HgPathErrorKind::IsInsideNestedRepo { path, nested_repo: nested } => {
            write_bytes!(
                f,
                b"path '{}' is inside nested repo '{}'",
                path.as_bytes(),
                nested.as_bytes()
            )
        }
        HgPathErrorKind::TraversesSymbolicLink { path, symlink } => {
            write_bytes!(
                f,
                b"path '{}' traverses symbolic link '{}'",
                path.as_bytes(),
                symlink.as_bytes()
            )
        }
        HgPathErrorKind::NotFsCompliant(path) => write_bytes!(
            f,
            b"path '{}' cannot be turned into a filesystem path",
            path.as_bytes()
        ),
        HgPathErrorKind::NotUnderRoot { path, root } => write_bytes!(
            f,
            b"path '{}' not under root {}",
            get_bytes_from_path(path),
            get_bytes_from_path(root)
        ),
    }
}

fn write_docket_error(f: &mut Vec<u8>, error: &DocketError) -> io::Result<()> {
    let DocketError { docket_path, kind, backtrace } = error;
    let docket_path = get_bytes_from_path(docket_path);
    match kind {
        DocketErrorKind::Corrupted => {
            write_bytes!(f, b"{}corrupted docket: {}", backtrace, docket_path)
        }
        DocketErrorKind::BadFormatMarker => {
            write_bytes!(
                f,
                b"{}unrecognized format marker in docket {}",
                backtrace,
                docket_path
            )
        }
        DocketErrorKind::DataFileTooSmall { data_path } => {
            write_bytes!(
                f,
                b"{}data file {} is smaller than its 'used size' in \
                docket {}",
                backtrace,
                get_bytes_from_path(data_path),
                docket_path
            )
        }
        DocketErrorKind::ReadRace => {
            write_bytes!(
                f,
                b"{}encountered a race condition between reading \
                docket {} and its data file",
                backtrace,
                docket_path
            )
        }
        DocketErrorKind::ReadRaceExhausted { tries } => {
            write_bytes!(
                f,
                b"{}{} read race happened {} times in a row",
                backtrace,
                docket_path,
                tries
            )
        }
        DocketErrorKind::NonUtf8DataFileId => {
            write_bytes!(
                f,
                b"{}non-UTF-8 {} data file ID",
                backtrace,
                docket_path
            )
        }
        DocketErrorKind::Overflow => {
            write_bytes!(
                f,
                b"{}overflow in {} docket serialization",
                backtrace,
                docket_path
            )
        }
    }
}

fn format_config_items_error(
    f: &mut Vec<u8>,
    items_error: &ConfigItemsError,
) -> io::Result<()> {
    match items_error {
        ConfigItemsError::Toml(error) => write!(f, "{}", error),
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
            write_bytes!(
                f,
                b"invalid pattern for config item '{}.{}': {}",
                section,
                name,
                Utf8(error)
            )
        }
    }
}

fn format_pattern_error(
    f: &mut Vec<u8>,
    pattern_error: &PatternError,
) -> io::Result<()> {
    match pattern_error {
        PatternError::UnsupportedSyntax(syntax, backtrace) => {
            write_bytes!(f, b"{}unsupported syntax '{}'", backtrace, syntax)
        }
        PatternError::IO(error) => write_io_error(f, error),
        PatternError::Path(error) => write_hg_path_error(f, error, None),
        PatternError::NonRegexPattern(pattern, backtrace) => {
            write!(
                f,
                "{backtrace}'{:?}' cannot be turned into a regex",
                pattern
            )
        }
        PatternError::UnclosedGlobAlternation(pattern, backtrace) => {
            write_bytes!(
                f,
                b"{} unclosed glob alternation in pattern '{}'",
                backtrace,
                pattern
            )
        }
        PatternError::RegexError { needle, error, backtrace } => {
            // The needle is likely already in the error, but let's
            // be safe
            writeln!(f, "{backtrace}invalid regex '{needle}':")?;
            match error {
                RegexBuildError::Syntax(error) => write!(f, "{}", error),
                RegexBuildError::Build(error) => write!(f, "{}", error),
            }
        }
        PatternError::NonUtf8Pattern { pattern, valid_up_to, backtrace } => {
            write_bytes!(
                f,
                b"{} non-utf8 regex pattern {}, valid up to byte {}",
                backtrace,
                pattern,
                valid_up_to
            )
        }
        PatternError::UnsupportedSyntaxNarrow(_, backtrace) => {
            write!(f, "{backtrace}only \"path:\" patterns can be fingerprinted")
        }
    }
}

fn write_io_error(f: &mut Vec<u8>, error: &HgIoError) -> io::Result<()> {
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

fn write_graph_error(f: &mut Vec<u8>, error: &GraphError) -> io::Result<()> {
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

fn write_config_value_parse_error(
    f: &mut Vec<u8>,
    error: &ConfigValueParseError,
) -> io::Result<()> {
    // TODO: add origin and line number information, here and in
    // corresponding python code
    write_bytes!(
        f,
        b"config error: {}.{} is not a {} ('{}')",
        error.section,
        error.item,
        error.expected_type.as_bytes(),
        error.value
    )
}

fn write_io_error_context(
    f: &mut Vec<u8>,
    context: &IoErrorContext,
) -> io::Result<()> {
    match context {
        IoErrorContext::ReadingMetadata(path) => {
            write_bytes!(
                f,
                b"when reading metadata of {}",
                get_bytes_from_path(path)
            )
        }
        IoErrorContext::ReadingFile(path) => {
            write_bytes!(f, b"when reading {}", get_bytes_from_path(path))
        }
        IoErrorContext::WritingFile(path) => {
            write_bytes!(f, b"when writing {}", get_bytes_from_path(path))
        }
        IoErrorContext::RemovingFile(path) => {
            write_bytes!(f, b"when removing {}", get_bytes_from_path(path))
        }
        IoErrorContext::RenamingFile { from, to } => {
            write_bytes!(
                f,
                b"when renaming {} to {}",
                get_bytes_from_path(from),
                get_bytes_from_path(to)
            )
        }
        IoErrorContext::CopyingFile { from, to } => {
            write_bytes!(
                f,
                b"when copying {} to {}",
                get_bytes_from_path(from),
                get_bytes_from_path(to)
            )
        }
        IoErrorContext::CanonicalizingPath(path) => {
            write_bytes!(
                f,
                b"when canonicalizing {}",
                get_bytes_from_path(path)
            )
        }
        IoErrorContext::CurrentDir => {
            write!(f, "error getting current working directory")
        }
        IoErrorContext::CurrentExe => {
            write!(f, "error getting current executable")
        }
    }
}
