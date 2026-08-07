//! Bridge to the chg client logic from `contrib/chg`.
//!
//! The C code is compiled into this crate by `build.rs` when the `chg`
//! cargo feature is enabled, and exposes its entry point as the `chg_main`
//! function (see `contrib/chg/chg.c`). The daemonization policy handling
//! is available regardless of the feature.

/// Environment variable controlling the use of a command server.
pub const POLICY_ENV_VAR: &str = "HGDAEMONIZEPOLICY";
/// Policy value requesting a command server when supported.
pub const POLICY_AUTO: &str = "auto";
/// Policy value requiring a command server.
pub const POLICY_ALWAYS: &str = "always";

/// Daemonization requested through `$HGDAEMONIZEPOLICY` (see the crate
/// documentation for the exact semantics of each value).
pub enum Policy {
    /// never run through a Daemon.
    Never,
    /// use a Daemon if available.
    Auto,
    /// use a Daemon, abort when the feature is unavailable.
    Always,
}

impl Policy {
    /// Read the daemonization policy from `$HGDAEMONIZEPOLICY`. An unset
    /// variable or an unrecognized value is read as `Never`.
    pub fn from_env() -> Self {
        match std::env::var_os(POLICY_ENV_VAR) {
            Some(value) if value == POLICY_AUTO => Policy::Auto,
            Some(value) if value == POLICY_ALWAYS => Policy::Always,
            _ => Policy::Never,
        }
    }
}

/// Should the command be handed over to the chg client logic (`run`)?
///
/// Follows the `$HGDAEMONIZEPOLICY` policy (see the crate documentation).
#[cfg(feature = "chg")]
pub fn enabled() -> bool {
    match Policy::from_env() {
        Policy::Never => false,
        Policy::Auto | Policy::Always => true,
    }
}

/// Should the command be handed over to the chg client logic (`run`)?
///
/// This binary was built without chg support: abort when the
/// `$HGDAEMONIZEPOLICY` policy requires a command server (`always`).
#[cfg(not(feature = "chg"))]
pub fn enabled() -> bool {
    match Policy::from_env() {
        Policy::Never | Policy::Auto => false,
        Policy::Always => {
            eprintln!(
                "chg: abort: this hg binary was built without chg support"
            );
            std::process::exit(255);
        }
    }
}

/// Stub for builds without chg support: `enabled()` never returns `true`
/// there, so this is never called (it only exists to keep the call site
/// free of conditional compilation).
#[cfg(not(feature = "chg"))]
pub fn run(_hg_py: &std::path::Path) -> ! {
    unreachable!("chg::run() called without chg support");
}

#[cfg(feature = "chg")]
unsafe extern "C" {
    /// The chg client logic, compiled from `contrib/chg` (see `build.rs`).
    ///
    /// Safety: the function signature matches exactly the C signature
    fn chg_main(
        argc: std::ffi::c_int,
        argv: *const *const std::ffi::c_char,
    ) -> std::ffi::c_int;
}

/// Hand the whole command over to the chg client logic
#[cfg(feature = "chg")]
pub fn run(hg_py: &std::path::Path) -> ! {
    use std::ffi::CString;
    use std::ffi::c_char;
    use std::ffi::c_int;
    use std::os::unix::ffi::OsStrExt;

    // The policy only applies to the current invocation: strip it from the
    // environment (forwarded to the command server) so that `hg` processes
    // spawned by the commands we run do not inherit it, mirroring how
    // children of a chg-run command used to run the plain binary.
    //
    // This might be legacy logic we could avoid now, but
    // `test-clonebundles-autogen.t` fails without it, so it would have to
    // be properly investigated first.
    //
    // Safety: We are in the main thread at an early stage of initialization, no
    // other thread should exist to race us on this.
    unsafe { std::env::remove_var(POLICY_ENV_VAR) };
    // explicitly point the chg logic to the python entry point.
    //
    // This ignores any preexisting $CHGHG value because in the "hg-bin" mode
    // there is no ambiguity about where to find Mercurial.
    //
    // NOTE: once we drop the old way of building an independent `chg`, we
    // should just simplify the code to remove the various options to select
    // where to find hg and pass it as argument to `chg_main`. In the
    // meantime, updating CHGHG seems good enough.
    //
    // Safety: We are in the main thread at an early stage of initialization, no
    // other thread should exist to race us on this.
    unsafe { std::env::set_var("CHGHG", hg_py) };
    let args: Vec<CString> = std::env::args_os()
        .map(|arg| {
            CString::new(arg.as_bytes())
                // TODO have a proper return code matching what mercurial's
                // python would do here.
                .expect("NUL byte in command line argument")
        })
        .collect();
    let mut argv: Vec<*const c_char> =
        args.iter().map(|arg| arg.as_ptr()).collect();
    argv.push(std::ptr::null());
    // SAFETY: argv is a NULL-terminated array of NUL-terminated strings
    // matching the layout of a C main()'s argv, and `args` keeps the
    // strings alive for the whole call.
    let exit_code = unsafe { chg_main(args.len() as c_int, argv.as_ptr()) };
    std::process::exit(exit_code);
}
