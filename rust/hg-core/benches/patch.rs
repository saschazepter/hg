//! Benchmarks for `hg::revlog::patch`.
//!
//! Run with `make rust-benchmark` (or
//! `cargo bench -p hg-core --features bench --bench patch` from the `rust`
//! directory).

fn main() {
    // Runs every function annotated with `#[divan::bench]` in this crate.
    divan::main();
}

/// Contains benchmark components for delta folding performance evaluation.
mod delta_folding {
    use hg::revlog::patch::Delta;
    use hg::revlog::patch::Edit;
    use hg::revlog::patch::PlainEdit;
    use hg::revlog::patch::bench::fold_deltas;

    /// Describes how to generate one synthetic `Delta`.
    enum DeltaGenerator {
        /// A single edit replacing `[start, end)` with `final_length` bytes.
        SingleEditDeltaGenerator {
            start: usize,
            end: usize,
            final_length: usize,
        },
    }

    impl DeltaGenerator {
        /// Generates one single delta based on its specification.
        /// Delta might be different at each call (when using RNG for instance).
        /// This gets called once per benchmarking iteration, and thus maps to a
        /// single Delta during that iteration.
        fn generate_delta<'a, P>(&self, data_pool: &'a [u8]) -> Delta<'a, P>
        where
            P: Edit<'a>,
        {
            match *self {
                DeltaGenerator::SingleEditDeltaGenerator {
                    start,
                    end,
                    final_length,
                } => {
                    let mut delta = Delta::empty();
                    delta.chunks.push(P::new_rich(
                        0,
                        start as u32,
                        end as u32,
                        0,
                        &data_pool[0..final_length],
                    ));
                    delta
                }
            }
        }

        /// Size of the data pool this generator needs.
        fn max_data_size(&self) -> usize {
            match *self {
                DeltaGenerator::SingleEditDeltaGenerator {
                    final_length,
                    ..
                } => final_length,
            }
        }
    }

    /// Allocate a data pool large enough for every generator.
    fn data_pool_for(generators: &[DeltaGenerator]) -> Vec<u8> {
        let max_size = generators
            .iter()
            .map(DeltaGenerator::max_data_size)
            .max()
            .expect("Call max on empty generator list");
        vec![0u8; max_size]
    }

    /// Turn a list of generators into a closure building one delta per
    /// generator, borrowing their data from `data_pool`.
    fn generators_to_builder<'a, P>(
        generators: Vec<DeltaGenerator>,
        data_pool: &'a [u8],
    ) -> impl Fn() -> Vec<Delta<'a, P>> + Sync + 'a
    where
        P: Edit<'a> + 'a,
    {
        move || {
            generators
                .iter()
                .map(|generator| generator.generate_delta(data_pool))
                .collect()
        }
    }

    /// Execute a benchmark with the provided Delta specification (generators).
    fn bench_plain(bencher: divan::Bencher, generators: Vec<DeltaGenerator>) {
        let data_pool = data_pool_for(&generators);
        let build_deltas =
            generators_to_builder::<PlainEdit>(generators, &data_pool);

        bencher.with_inputs(build_deltas).bench_values(fold_deltas);
    }
}
