pub type ExitCode = i32;

/// Successful exit
pub const OK: ExitCode = 0;

/// Generic abort
pub const ABORT: ExitCode = 255;

// Abort when there is a config related error
pub const CONFIG_ERROR_ABORT: ExitCode = 30;

/// Indicates that the operation might work if retried in a different state.
/// Examples: Unresolved merge conflicts, unfinished operations
pub const STATE_ERROR: ExitCode = 20;

// Abort when there is an error while parsing config
pub const CONFIG_PARSE_ERROR_ABORT: ExitCode = 10;

/// Generic something completed but did not succeed
pub const UNSUCCESSFUL: ExitCode = 1;

/// Command or feature not implemented by rhg
pub const UNIMPLEMENTED: ExitCode = 252;

/// The fallback path is not valid
pub const INVALID_FALLBACK: ExitCode = 253;
