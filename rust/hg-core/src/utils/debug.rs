//! Utils for debugging hg-core

use crate::config::Config;

/// Write the file path given by the config option `devel.<config_option>` with
/// the suffix `.waiting`, then wait for the file path given by the
/// config option `devel.<config_option>` to appear on disk
/// up to `devel.<config_option>-timeout` seconds.
/// Note that the timeout may be higher because we scale it if global
/// `run-tests` timeouts are raised to prevent flakiness on slower hardware.
///
/// Useful for testing race conditions.
pub fn debug_wait_for_file(
    config: &Config,
    config_option: &str,
) -> Result<(), String> {
    let path_opt = format!("sync.{config_option}");
    let file_path = match config.get_str(b"devel", path_opt.as_bytes()).ok() {
        Some(Some(file_path)) => file_path,
        _ => return Ok(()),
    };

    // TODO make it so `configitems` is shared between Rust and Python so that
    // defaults work out of the box, etc.
    let default_timeout = 2;
    let timeout_opt = format!("sync.{config_option}-timeout");
    let timeout_seconds = match config.get_u32(b"devel", timeout_opt.as_bytes())
    {
        Ok(Some(timeout)) => timeout,
        _ => default_timeout,
    };

    tracing::debug!(
        "Config option `{config_option}` found, \
             waiting for file `{file_path}` to be created"
    );
    debug_wait_for_file_impl(file_path, Some(config_option), timeout_seconds)
}

fn debug_wait_for_file_impl(
    file_path: &str,
    config_option: Option<&str>,
    timeout_seconds: u32,
) -> Result<(), String> {
    let timeout_seconds = timeout_seconds as u64;
    std::fs::File::create(format!("{file_path}.waiting")).ok();

    let timeout_seconds = scale_test_timeout(timeout_seconds);
    let timeout = std::time::Duration::from_secs(timeout_seconds);

    let start = std::time::Instant::now();
    let path = std::path::Path::new(file_path);
    let mut found = false;
    while start.elapsed() < timeout {
        if path.exists() {
            tracing::debug!("File `{file_path}` was created");
            found = true;
            break;
        } else {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    if !found {
        let file_path_explanation = match config_option {
            Some(config_option) => {
                format!(" set by `{config_option}`")
            }
            None => format!(""),
        };
        let msg = format!(
            "File `{file_path}`{file_path_explanation} was not found \
            within the allocated {timeout_seconds} seconds timeout"
        );
        Err(msg)
    } else {
        Ok(())
    }
}

pub fn debug_wait_for_file_or_print(config: &Config, config_option: &str) {
    if let Err(e) = debug_wait_for_file(config, config_option) {
        eprintln!("{e}");
    };
}

/// Scale a timeout (in seconds), to avoid flakiness when global `run-tests`
/// timeouts are raised on slower hardware.
fn scale_test_timeout(timeout_seconds: u64) -> u64 {
    let global_timeout_perc: u64 = std::env::var("HGTEST_TIMEOUT_PERCENTAGE")
        .map(|t| t.parse())
        .unwrap_or(Ok(100))
        .unwrap();
    (timeout_seconds * global_timeout_perc) / 100
}
