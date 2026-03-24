use std::path::Path;

use disk_cleaner_config::core::context::DefaultProjectScanner;

use crate::api::ProcessMonitor;
use crate::core::DefaultProcessMonitor;

/// Create and run the monitor feature.
pub fn run(ctx: &DefaultProjectScanner, config_dir: &Path, history_only: bool) {
    let monitor = DefaultProcessMonitor;
    monitor.run(ctx, config_dir, history_only);
}

// Re-export for use by clean/analyze when recording history
pub use crate::api::{HistoryEntry, HistoryStore};
pub use crate::core::DefaultHistoryStore;
