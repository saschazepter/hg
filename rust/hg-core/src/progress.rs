//! Progress-bar related things

use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use indicatif::{ProgressBar, ProgressDrawTarget, ProgressStyle};

/// A generic determinate progress bar trait
pub trait Progress: Send + Sync + 'static {
    /// Set the current position and optionally the total
    fn update(&self, pos: u64, total: Option<u64>);
    /// Increment the current position and optionally the total
    fn increment(&self, step: u64, total: Option<u64>);
    /// Declare that progress is over and the progress bar should be deleted
    fn complete(self);
}

const PROGRESS_DELAY: Duration = Duration::from_secs(1);

/// A generic (determinate) progress bar. Stays hidden until `PROGRESS_DELAY`
/// to prevent flickering a progress bar for super fast operations.
pub struct HgProgressBar {
    progress: ProgressBar,
    has_been_shown: AtomicBool,
}

impl HgProgressBar {
    // TODO pass config to check progress.disable/assume-tty/delay/etc.
    /// Return a new progress bar with `topic` as the prefix.
    /// The progress and total are both set to 0, and it is hidden until the
    /// next call to `update` given that more than a second has elapsed.
    pub fn new(topic: &str) -> Self {
        let template =
            format!("{} {{wide_bar}} {{pos}}/{{len}} {{eta}} ", topic);
        let style = ProgressStyle::with_template(&template).unwrap();
        let progress_bar = ProgressBar::new(0).with_style(style);
        // Hide the progress bar and only show it if we've elapsed more
        // than a second
        progress_bar.set_draw_target(ProgressDrawTarget::hidden());
        Self {
            progress: progress_bar,
            has_been_shown: false.into(),
        }
    }

    /// Called whenever the progress changes to determine whether to start
    /// showing the progress bar
    fn maybe_show(&self) {
        if self.progress.is_hidden()
            && self.progress.elapsed() > PROGRESS_DELAY
        {
            // Catch a race condition whereby we check if it's hidden, then
            // set the draw target from another thread, then do it again from
            // this thread, which results in multiple progress bar lines being
            // left drawn.
            let has_been_shown =
                self.has_been_shown.fetch_or(true, Ordering::Relaxed);
            if !has_been_shown {
                // Here we are certain that we're the only thread that has
                // set `has_been_shown` and we can change the draw target
                self.progress.set_draw_target(ProgressDrawTarget::stderr());
                self.progress.tick();
            }
        }
    }
}

impl Progress for HgProgressBar {
    fn update(&self, pos: u64, total: Option<u64>) {
        self.progress.update(|state| {
            state.set_pos(pos);
            if let Some(t) = total {
                state.set_len(t)
            }
        });
        self.maybe_show();
    }

    fn increment(&self, step: u64, total: Option<u64>) {
        self.progress.inc(step);
        if let Some(t) = total {
            self.progress.set_length(t)
        }
        self.maybe_show();
    }

    fn complete(self) {
        self.progress.finish_and_clear();
    }
}
