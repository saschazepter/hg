//! Policies driving the front-desk features from the configuration.
//!
//! Each feature of the front desk (daemonization, Rust extensions) follows a
//! four-valued policy read from the `[policy]` section of the non-repository
//! configuration, possibly overridden by an environment variable of its own
//! (see the crate documentation for the sources each feature consults).

/// Policy value using a feature when the installation supports it.
pub const POLICY_AUTO: &[u8] = b"auto";
/// Policy value requiring a feature.
pub const POLICY_ALWAYS: &[u8] = b"always";
/// Policy value disabling a feature.
pub const POLICY_NEVER: &[u8] = b"never";
/// Policy value deferring to the next policy source.
pub const POLICY_DEFAULT: &[u8] = b"default";

/// A policy value, as read from one source (environment or configuration).
///
/// See the crate documentation for the exact semantics of each value for
/// each feature.
#[derive(Debug, PartialEq, Eq)]
pub enum Policy {
    /// never use the feature.
    Never,
    /// use the feature if available.
    Auto,
    /// use the feature, abort when it is unavailable.
    Always,
    /// ignore that source and rely on the next one (in this order):
    /// - environment,
    /// - config,
    /// - built-in default.
    Default,
}

impl Policy {
    /// Parse a policy value, shared by environment variables and the
    /// configuration.
    ///
    /// An empty value is read as `Default`.
    /// An unrecognized one as `Never`.
    pub fn from_bytes(value: &[u8]) -> Self {
        match value {
            b"" => Policy::Default,
            POLICY_AUTO => Policy::Auto,
            POLICY_ALWAYS => Policy::Always,
            POLICY_NEVER => Policy::Never,
            POLICY_DEFAULT => Policy::Default,
            _ => Policy::Never,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_known_values() {
        assert_eq!(Policy::from_bytes(b"never"), Policy::Never);
        assert_eq!(Policy::from_bytes(b"auto"), Policy::Auto);
        assert_eq!(Policy::from_bytes(b"always"), Policy::Always);
        assert_eq!(Policy::from_bytes(b"default"), Policy::Default);
    }

    #[test]
    fn empty_value_defers() {
        assert_eq!(Policy::from_bytes(b""), Policy::Default);
    }

    #[test]
    fn unknown_value_disables() {
        assert_eq!(Policy::from_bytes(b"maybe"), Policy::Never);
        assert_eq!(Policy::from_bytes(b"Auto"), Policy::Never);
    }
}
