//! Build script of the front desk.
//!
//! It records what `setup.py` says about the Mercurial installation this
//! binary is built for, and compiles the C implementation of chg from
//! `contrib/chg` into this crate when the "chg" cargo feature is enabled.

/// Environment variable through which `setup.py` gives the module policy
/// built into the Python package (the value of its `__modulepolicy__`).
const MODULE_POLICY_VAR: &str = "HG_BIN_MODULE_POLICY";
/// Environment variable through which `setup.py` tells whether the Rust
/// extensions are installed: `1` when they are, `0` otherwise.
const RUST_AVAILABLE_VAR: &str = "HG_BIN_RUST_AVAILABLE";
/// Compile-time cfg set when the Rust extensions are installed.
const RUST_AVAILABLE_CFG: &str = "rust_available";
/// The module policies the Python code knows (see `mercurial/policy.py`).
const MODULE_POLICIES: &[&str] =
    &["c", "allow", "rust+c", "rust+c-allow", "py", "cffi", "cffi-allow"];

const CHG_DIR: &str = "../../contrib/chg";
const CHG_SRCS: &[&str] = &["chg.c", "hgclient.c", "procutil.c", "util.c"];
const CHG_HDRS: &[&str] = &["hgclient.h", "procutil.h", "util.h"];

fn main() {
    describe_installation();
    compile_chg();
}

/// Turn what `setup.py` says about the installation into compile-time
/// facts for the `module_policy` module: the built-in module policy as an
/// `env!` constant, the availability of the Rust extensions as a `cfg`.
///
/// A build outside `setup.py` (a plain `cargo build`) describes a plain C
/// installation: `c` policy, no Rust extensions.
fn describe_installation() {
    println!("cargo::rerun-if-env-changed={MODULE_POLICY_VAR}");
    println!("cargo::rerun-if-env-changed={RUST_AVAILABLE_VAR}");
    let policy = match std::env::var(MODULE_POLICY_VAR) {
        Ok(policy) if MODULE_POLICIES.contains(&policy.as_str()) => policy,
        Ok(policy) => {
            fail(&format!("{MODULE_POLICY_VAR}: unknown policy {policy:?}"))
        }
        Err(std::env::VarError::NotPresent) => "c".to_string(),
        Err(err) => fail(&format!("{MODULE_POLICY_VAR}: {err}")),
    };
    let rust_available = match std::env::var(RUST_AVAILABLE_VAR) {
        Ok(value) if value == "1" => true,
        Ok(value) if value == "0" => false,
        Ok(value) => fail(&format!(
            "{RUST_AVAILABLE_VAR}: expected 0 or 1, got {value:?}"
        )),
        Err(std::env::VarError::NotPresent) => false,
        Err(err) => fail(&format!("{RUST_AVAILABLE_VAR}: {err}")),
    };
    println!("cargo::rustc-env={MODULE_POLICY_VAR}={policy}");
    println!("cargo::rustc-check-cfg=cfg({RUST_AVAILABLE_CFG})");
    if rust_available {
        println!("cargo::rustc-cfg={RUST_AVAILABLE_CFG}");
    }
}

/// Stop the build with `message`.
fn fail(message: &str) -> ! {
    eprintln!("hg-bin build: {message}");
    std::process::exit(1);
}

/// Compile the C implementation of chg into this crate, when the "chg"
/// cargo feature is enabled.
fn compile_chg() {
    // We use the `c` version of chg for now as that version has been
    // extensively battle tested. Using the rust version of chg (that lives
    // in `rust/chg`) would be nice but would require more extensive testing.
    //
    // In addition, the `chg` source code is still living in `contrib` instead
    // of within the `hg-bin` source tree because we don't want to break the
    // "old school" way to build and install chg yet. Feel free to clean
    // that up during the 7.4 cycle.
    if std::env::var_os("CARGO_FEATURE_CHG").is_some() {
        // The relative paths work locally but won't if published to crates.io.
        let mut build = cc::Build::new();
        build
            .warnings(true)
            // match the flags used by contrib/chg/Makefile
            .flag("-std=gnu99")
            .define("_GNU_SOURCE", None);
        for src in CHG_SRCS {
            let path = format!("{CHG_DIR}/{src}");
            println!("cargo::rerun-if-changed={path}");
            build.file(path);
        }
        for hdr in CHG_HDRS {
            println!("cargo::rerun-if-changed={CHG_DIR}/{hdr}");
        }
        build.compile("chg");
    }
}
