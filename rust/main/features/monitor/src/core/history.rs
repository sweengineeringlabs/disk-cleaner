use std::path::{Path, PathBuf};

use crate::api::{HistoryEntry, HistoryStore};

const MAX_ENTRIES: usize = 100;

/// JSON file-backed history store matching the PowerShell RunHistory class.
pub struct DefaultHistoryStore {
    file_path: PathBuf,
}

impl DefaultHistoryStore {
    pub fn new(config_dir: &Path) -> Self {
        Self {
            file_path: config_dir.join("history.json"),
        }
    }
}

impl HistoryStore for DefaultHistoryStore {
    fn record(&self, mut entry: HistoryEntry) {
        if entry.timestamp.is_empty() {
            entry.timestamp = chrono::Local::now().to_rfc3339();
        }

        let mut entries = self.load();
        entries.push(entry);

        // Keep last MAX_ENTRIES
        if entries.len() > MAX_ENTRIES {
            entries = entries.split_off(entries.len() - MAX_ENTRIES);
        }

        if let Ok(json) = serde_json::to_string_pretty(&entries) {
            let _ = std::fs::write(&self.file_path, json);
        }
    }

    fn load(&self) -> Vec<HistoryEntry> {
        if !self.file_path.exists() {
            return Vec::new();
        }

        match std::fs::read_to_string(&self.file_path) {
            Ok(raw) => {
                if raw.trim().is_empty() {
                    return Vec::new();
                }
                serde_json::from_str(&raw).unwrap_or_default()
            }
            Err(_) => Vec::new(),
        }
    }
}
