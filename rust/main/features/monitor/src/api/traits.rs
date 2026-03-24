use std::path::Path;

use disk_cleaner_config::core::context::DefaultProjectScanner;

/// Monitors build processes and displays run history.
pub trait ProcessMonitor {
    fn run(&self, ctx: &DefaultProjectScanner, config_dir: &Path, history_only: bool);
}

/// Persists and loads run history entries.
pub trait HistoryStore {
    fn record(&self, entry: HistoryEntry);
    fn load(&self) -> Vec<HistoryEntry>;
}

/// A single run history entry.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct HistoryEntry {
    pub timestamp: String,
    pub command: String,
    pub profiles: String,
    pub projects: u32,
    pub size_bytes: i64,
    pub size_formatted: String,
    pub path: String,
}

/// Info about a running build process.
#[derive(Debug)]
pub struct BuildProcessInfo {
    pub pid: u32,
    pub name: String,
    pub cpu_seconds: f64,
    pub memory_bytes: u64,
}
