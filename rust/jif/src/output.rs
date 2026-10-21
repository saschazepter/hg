//! Where commands write what they produce.

/// How machines get output
#[derive(Clone, Copy, PartialEq, clap::ValueEnum)]
pub enum Format {
    Json,
}
