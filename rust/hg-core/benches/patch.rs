//! Benchmarks for `hg::revlog::patch`.
//!
//! Run with `make rust-benchmark` (or
//! `cargo bench -p hg-core --features bench --bench patch` from the `rust`
//! directory).

fn main() {
    // Runs every function annotated with `#[divan::bench]` in this crate.
    divan::main();
}
