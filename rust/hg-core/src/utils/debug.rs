//! Utils for debugging hg-core

use crate::config::Config;

#[derive(Debug, Clone)]
// "active", in the sense of being enabled in the config
struct ActiveSyncPoint {
    file_path: String,
    timeout_seconds: u32,
    config_option: String,
}

#[derive(Debug, Clone, Default)]
pub struct SyncPoint {
    active: Option<ActiveSyncPoint>,
}

impl SyncPoint {
    pub fn read_from_config(config: &Config, config_option: &str) -> Self {
        let path_opt = format!("sync.{config_option}");
        let file_path = match config.get_str(b"devel", path_opt.as_bytes()).ok()
        {
            Some(Some(file_path)) => file_path,
            _ => return SyncPoint { active: None },
        };

        // TODO make it so `configitems` is shared between Rust and Python so
        // that defaults work out of the box, etc.
        let default_timeout = 2;
        let timeout_opt = format!("sync.{config_option}-timeout");
        let timeout_seconds =
            match config.get_u32(b"devel", timeout_opt.as_bytes()) {
                Ok(Some(timeout)) => timeout,
                _ => default_timeout,
            };
        SyncPoint {
            active: Some(ActiveSyncPoint {
                file_path: file_path.to_owned(),
                timeout_seconds,
                config_option: config_option.to_owned(),
            }),
        }
    }
}

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
    let sync_point = SyncPoint::read_from_config(config, config_option);

    match &sync_point.active {
        None => Ok(()),
        Some(body) => {
            let config_option = &body.config_option;
            let file_path = &body.file_path;
            tracing::debug!(
                "Config option `{config_option}` found, \
                    waiting for file `{file_path}` to be created"
            );
            debug_wait_for_sync_point(&sync_point)
        }
    }
}

fn debug_wait_for_sync_point(sync_point: &SyncPoint) -> Result<(), String> {
    let Some(sync_point) = &sync_point.active else {
        return Ok(());
    };
    let ActiveSyncPoint { file_path, timeout_seconds, config_option } =
        sync_point;
    let timeout_seconds = *timeout_seconds as u64;
    std::fs::File::create(format!("{file_path}.waiting")).ok();

    let timeout_seconds = scale_test_timeout(timeout_seconds);
    let timeout = std::time::Duration::from_secs(timeout_seconds);

    let start = std::time::Instant::now();
    let path = std::path::Path::new(&file_path);
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
        let msg = format!(
            "File `{file_path}` set by `{config_option} was not found \
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

pub fn debug_wait_for_sync_point_or_print(sync_point: &SyncPoint) {
    if let Err(e) = debug_wait_for_sync_point(sync_point) {
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
