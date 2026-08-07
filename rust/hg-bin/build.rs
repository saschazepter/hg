//! Compile the C implementation of chg from `contrib/chg` into this crate,
//! when the "chg" cargo feature is enabled.
const CHG_DIR: &str = "../../contrib/chg";
const CHG_SRCS: &[&str] = &["chg.c", "hgclient.c", "procutil.c", "util.c"];
const CHG_HDRS: &[&str] = &["hgclient.h", "procutil.h", "util.h"];

fn main() {
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
