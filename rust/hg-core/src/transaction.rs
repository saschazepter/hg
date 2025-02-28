use std::path::Path;

/// The Mercurial transaction system is based on the append-only nature
/// of its core files. This exposes the necessary methods to safely write to
/// the different core datastructures.
pub trait Transaction {
    /// Record the state of an append-only file before update
    fn add(&mut self, file: impl AsRef<Path>, offset: usize);

    // TODO the rest of the methods once we do more in Rust.
}
