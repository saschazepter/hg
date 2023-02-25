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
    let timeout_seconds =
        match config.get_u32(b"devel", timeout_opt.as_bytes()) {
            Ok(Some(timeout)) => timeout,
            Err(e) => {
                log::debug!("{e}");
                default_timeout
            }
            _ => default_timeout,
        };
    let timeout_seconds = timeout_seconds as u64;

    log::debug!(
        "Config option `{config_option}` found, \
             waiting for file `{file_path}` to be created"
    );
    std::fs::File::create(format!("{file_path}.waiting")).ok();
    // If the test timeout have been extended, scale the timer relative
    // to the normal timing.
    let global_default_timeout: u64 = std::env::var("HGTEST_TIMEOUT_DEFAULT")
        .map(|t| t.parse())
        .unwrap_or(Ok(0))
        .unwrap();
    let global_timeout_override: u64 = std::env::var("HGTEST_TIMEOUT")
        .map(|t| t.parse())
        .unwrap_or(Ok(0))
        .unwrap();
    let timeout_seconds = if global_default_timeout < global_timeout_override {
        timeout_seconds * global_timeout_override / global_default_timeout
    } else {
        timeout_seconds
    };
    let timeout = std::time::Duration::from_secs(timeout_seconds);

    let start = std::time::Instant::now();
    let path = std::path::Path::new(file_path);
    let mut found = false;
    while start.elapsed() < timeout {
        if path.exists() {
            log::debug!("File `{file_path}` was created");
            found = true;
            break;
        } else {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }
    if !found {
        let msg = format!(
            "File `{file_path}` set by `{config_option}` was not found \
            within the allocated {timeout_seconds} seconds timeout"
        );
        Err(msg)
    } else {
        Ok(())
    }
}

pub fn debug_wait_for_file_or_print(config: &Config, config_option: &str) {
    if let Err(e) = debug_wait_for_file(&config, config_option) {
        eprintln!("{e}");
    };
}
