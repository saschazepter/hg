//! Progress-bar related things

/// A generic determinate progress bar trait
pub trait Progress: Send + Sync + 'static {
    /// Set the current position and optionally the total
    fn update(&self, pos: u64, total: Option<u64>);
    /// Increment the current position and optionally the total
    fn increment(&self, step: u64, total: Option<u64>);
    /// Declare that progress is over and the progress bar should be deleted
    fn complete(self);
}
