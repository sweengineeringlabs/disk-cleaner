use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU32, Ordering};

use crate::api::ProjectScanner;

/// Shared state for disk-cleaner operations.
pub struct DefaultProjectScanner {
    pub search_path: PathBuf,
    pub exclude_patterns: Vec<String>,
    pub include_patterns: Vec<String>,
    pub clean_all: bool,
    pub json_output: bool,
    pub cancelled: AtomicBool,

    pub total_projects: AtomicU32,
    pub total_cleaned: AtomicU32,
    pub total_skipped: AtomicU32,
    pub total_size_bytes: AtomicI64,
}

impl DefaultProjectScanner {
    pub fn new(
        search_path: PathBuf,
        exclude: Vec<String>,
        include: Vec<String>,
        clean_all: bool,
        json_output: bool,
    ) -> Self {
        Self {
            search_path,
            exclude_patterns: exclude,
            include_patterns: include,
            clean_all,
            json_output,
            cancelled: AtomicBool::new(false),
            total_projects: AtomicU32::new(0),
            total_cleaned: AtomicU32::new(0),
            total_skipped: AtomicU32::new(0),
            total_size_bytes: AtomicI64::new(0),
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Relaxed)
    }

    pub fn relative_path(&self, full_path: &Path) -> PathBuf {
        full_path
            .strip_prefix(&self.search_path)
            .unwrap_or(full_path)
            .to_path_buf()
    }

    fn should_include(&self, project_path: &Path) -> bool {
        if self.clean_all {
            return true;
        }

        let rel = self.relative_path(project_path);
        let rel_str = rel.to_string_lossy();

        for pattern in &self.exclude_patterns {
            if rel_str.contains(pattern.as_str()) {
                return false;
            }
        }

        if !self.include_patterns.is_empty() {
            for pattern in &self.include_patterns {
                if rel_str.contains(pattern.as_str()) {
                    return true;
                }
            }
            return false;
        }

        true
    }
}

impl ProjectScanner for DefaultProjectScanner {
    fn scan_for_projects(&self, markers: &[&str]) -> Vec<PathBuf> {
        let mut found = Vec::new();

        for marker in markers {
            if self.is_cancelled() {
                break;
            }
            for entry in walkdir::WalkDir::new(&self.search_path)
                .into_iter()
                .filter_map(|e| e.ok())
            {
                if self.is_cancelled() {
                    break;
                }
                if entry.file_name().to_string_lossy() == *marker {
                    if let Some(parent) = entry.path().parent() {
                        let dir = parent.to_path_buf();
                        if !found.contains(&dir) {
                            found.push(dir);
                        }
                    }
                }
            }
        }

        found
    }

    fn filter_projects(&self, found: &[PathBuf]) -> (Vec<PathBuf>, Vec<PathBuf>) {
        let mut to_process = Vec::new();
        let mut skipped = Vec::new();

        let mut sorted = found.to_vec();
        sorted.sort();

        for dir in sorted {
            if self.should_include(&dir) {
                to_process.push(dir);
            } else {
                skipped.push(dir);
            }
        }

        (to_process, skipped)
    }
}

/// Calculate total size of a directory in bytes.
pub fn dir_size_bytes(path: &Path) -> u64 {
    if !path.exists() {
        return 0;
    }
    walkdir::WalkDir::new(path)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter_map(|e| e.metadata().ok())
        .map(|m| m.len())
        .sum()
}

/// Format bytes into human-readable size string.
pub fn format_size(bytes: u64) -> String {
    const GIB: u64 = 1024 * 1024 * 1024;
    const MIB: u64 = 1024 * 1024;
    const KIB: u64 = 1024;

    if bytes >= GIB {
        format!("{:.2} GiB", bytes as f64 / GIB as f64)
    } else if bytes >= MIB {
        format!("{:.2} MiB", bytes as f64 / MIB as f64)
    } else if bytes >= KIB {
        format!("{:.2} KiB", bytes as f64 / KIB as f64)
    } else {
        format!("{bytes} B")
    }
}
