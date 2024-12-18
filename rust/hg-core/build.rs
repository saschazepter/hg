fn main() {
    // The relative paths work locally but won't if published to crates.io.
    println!("cargo::rerun-if-changed=../../mercurial/bdiff.c");
    println!("cargo::rerun-if-changed=../../mercurial/bdiff.h");
    println!("cargo::rerun-if-changed=../../mercurial/compat.h");
    println!("cargo::rerun-if-changed=../../mercurial/bitmanipulation.h");
    cc::Build::new()
        .warnings(true)
        .file("../../mercurial/bdiff.c")
        .compile("bdiff");
}
