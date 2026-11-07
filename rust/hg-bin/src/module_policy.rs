//! Control of the module policy of the Python code.
//!
//! The module policy (see `mercurial/policy.py`) selects the implementation
//! of the modules the Python code loads, the Rust extensions among them.
//! Every installation has a built-in policy, that the `[policy] rust-pyext`
//! configuration adjusts: the front desk hands the adjusted policy to the
//! Python code through `$HGMODULEPOLICY`, unless the variable is already set
//! to a non-empty value.
//!
//! The built-in policy, and whether the Rust extensions are installed, are
//! known since the build of this binary (see `build.rs`). `auto` and `always`
//! turn `c` into `rust+c` and the permissive `allow` of an in-place build into
//! `rust+c-allow`; any other built-in policy becomes `rust+c`, the Python code
//! being left to complain when its C extensions are missing.

use crate::policy::Policy;

/// Environment variable through which the Python code reads its module
/// policy (it ignores an empty value, like a missing one).
pub const ENV_VAR: &str = "HGMODULEPOLICY";
/// Configuration item controlling the use of the Rust extensions.
pub const CONFIG_ITEM: &[u8] = b"rust-pyext";
/// Module policy built into the installation this binary belongs to.
const BUILTIN: &str = env!("HG_BIN_MODULE_POLICY");
/// Are the Rust extensions installed? (see `build.rs`)
const RUST_AVAILABLE: bool = cfg!(rust_available);

/// Set `$HGMODULEPOLICY` for the Python code according to the
/// `[policy] rust-pyext` configuration, unless the variable is already set
/// to a non-empty value.
///
/// Aborts the command when the configuration requires Rust extensions the
/// installation does not include.
pub fn apply(config: &hg::config::Config) {
    let preset =
        std::env::var_os(ENV_VAR).is_some_and(|value| !value.is_empty());
    if preset {
        return;
    }
    let policy = Policy::from_config(config, CONFIG_ITEM);
    if let Policy::Always = policy
        && !RUST_AVAILABLE
    {
        let message = "abort: this Mercurial installation does not include \
                       the Rust extensions\n\
                       (policy.rust-pyext is \"always\", \"auto\" would skip \
                       them)";
        eprintln!("{message}");
        std::process::exit(255);
    }
    let use_rust = match policy {
        Policy::Default => return,
        Policy::Never => false,
        Policy::Auto => RUST_AVAILABLE,
        Policy::Always => true,
    };
    let module_policy = match BUILTIN {
        "c" | "rust+c" => match use_rust {
            true => "rust+c",
            false => "c",
        },
        "allow" | "rust+c-allow" => match use_rust {
            true => "rust+c-allow",
            false => "allow",
        },
        // no Rust variant of their own (`py`, `cffi`): `rust+c` has to do
        builtin => match use_rust {
            true => "rust+c",
            false => builtin,
        },
    };
    // NOTE: like a user-set variable, it is inherited by the processes
    // Mercurial starts (hooks, ssh, ...).
    //
    // Safety: We are in the main thread at an early stage of initialization,
    // no other thread should exist to race us on this.
    unsafe { std::env::set_var(ENV_VAR, module_policy) };
}
