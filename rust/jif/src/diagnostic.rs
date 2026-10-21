//! Rich information for errors and warnings.

use std::ops::Range;

use format_bytes::Message;

/// Source that an error or warning points into, such as a revset or a
/// configuration file.
#[derive(Debug)]
pub struct Snippet {
    /// Where the source comes from, e.g. a path
    pub origin: Option<Vec<u8>>,
    /// The whole source (of unknown encoding), so lines are numbered correctly
    pub source: Vec<u8>,
    /// The first is where the problem is, others give more context
    pub labels: Vec<Label>,
}

/// A part of the source of a [`Snippet`] and what to say about it
#[derive(Debug)]
pub struct Label {
    /// Byte offsets into the source
    pub span: Range<usize>,
    /// What to say about that part, drawn next to it
    pub message: Message,
}

impl Snippet {
    /// A snippet of `source`, without origin or labels yet
    pub fn new(source: impl Into<Vec<u8>>) -> Self {
        Self { origin: None, source: source.into(), labels: vec![] }
    }

    /// Says where the source comes from
    pub fn origin(mut self, origin: impl Into<Vec<u8>>) -> Self {
        self.origin = Some(origin.into());
        self
    }

    /// Adds a label on `span`, the first one being where the problem is
    pub fn label(mut self, span: Range<usize>, message: Message) -> Self {
        self.labels.push(Label { span, message });
        self
    }
}
