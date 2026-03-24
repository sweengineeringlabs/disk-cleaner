//! Integration tests for disk-cleaner-monitor crate.
//! Tests history persistence and process scanning.

use std::fs;

use disk_cleaner_monitor::{DefaultHistoryStore, HistoryEntry, HistoryStore};

// ─── History Persistence ─────────────────────────────────────────────────────

/// @covers: DefaultHistoryStore::record, DefaultHistoryStore::load
#[test]
fn test_history_record_and_load() {
    let tmp = tempfile::tempdir().unwrap();
    let store = DefaultHistoryStore::new(tmp.path());

    store.record(HistoryEntry {
        timestamp: "2026-03-24T10:00:00+00:00".to_string(),
        command: "clean".to_string(),
        profiles: "rust".to_string(),
        projects: 5,
        size_bytes: 1048576,
        size_formatted: "1.00 MiB".to_string(),
        path: "/projects".to_string(),
    });

    let entries = store.load();
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].command, "clean");
    assert_eq!(entries[0].projects, 5);
    assert_eq!(entries[0].size_bytes, 1048576);
}

/// @covers: DefaultHistoryStore::record (multiple entries)
#[test]
fn test_history_appends_entries() {
    let tmp = tempfile::tempdir().unwrap();
    let store = DefaultHistoryStore::new(tmp.path());

    for i in 0..5 {
        store.record(HistoryEntry {
            timestamp: String::new(),
            command: "clean".to_string(),
            profiles: "rust".to_string(),
            projects: i,
            size_bytes: (i as i64) * 1024,
            size_formatted: format!("{} B", i * 1024),
            path: "/projects".to_string(),
        });
    }

    let entries = store.load();
    assert_eq!(entries.len(), 5);
    assert_eq!(entries[4].projects, 4);
}

/// @covers: DefaultHistoryStore::record (max 100 entries)
#[test]
fn test_history_keeps_max_100_entries() {
    let tmp = tempfile::tempdir().unwrap();
    let store = DefaultHistoryStore::new(tmp.path());

    for i in 0..110 {
        store.record(HistoryEntry {
            timestamp: String::new(),
            command: "clean".to_string(),
            profiles: "rust".to_string(),
            projects: i,
            size_bytes: 0,
            size_formatted: "0 B".to_string(),
            path: "/projects".to_string(),
        });
    }

    let entries = store.load();
    assert_eq!(entries.len(), 100);
    // First entry should be #10 (oldest 10 dropped)
    assert_eq!(entries[0].projects, 10);
}

/// @covers: DefaultHistoryStore::load (empty file)
#[test]
fn test_history_load_empty_returns_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let store = DefaultHistoryStore::new(tmp.path());

    let entries = store.load();
    assert!(entries.is_empty());
}

/// @covers: DefaultHistoryStore::load (corrupt file)
#[test]
fn test_history_load_corrupt_file_returns_empty() {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("history.json"), "not valid json{{{").unwrap();

    let store = DefaultHistoryStore::new(tmp.path());
    let entries = store.load();
    assert!(entries.is_empty());
}

/// @covers: DefaultHistoryStore::record (auto-timestamps)
#[test]
fn test_history_record_auto_timestamps_empty_timestamp() {
    let tmp = tempfile::tempdir().unwrap();
    let store = DefaultHistoryStore::new(tmp.path());

    store.record(HistoryEntry {
        timestamp: String::new(), // should be auto-filled
        command: "analyze".to_string(),
        profiles: "node".to_string(),
        projects: 3,
        size_bytes: 2048,
        size_formatted: "2.00 KiB".to_string(),
        path: "/data".to_string(),
    });

    let entries = store.load();
    assert_eq!(entries.len(), 1);
    assert!(!entries[0].timestamp.is_empty(), "Timestamp should be auto-filled");
}

// ─── Monitor Run (smoke test) ───────────────────────────────────────────────

/// @covers: monitor::run (does not panic)
#[test]
fn test_monitor_run_history_only_does_not_panic() {
    let tmp = tempfile::tempdir().unwrap();
    let scanner = disk_cleaner_config::create_scanner(
        tmp.path().to_path_buf(),
        vec![],
        vec![],
        false,
        false,
    );

    // Should not panic with empty history
    disk_cleaner_monitor::run(&scanner, tmp.path(), true);
}

/// @covers: monitor::run (full mode)
#[test]
fn test_monitor_run_full_does_not_panic() {
    let tmp = tempfile::tempdir().unwrap();
    let scanner = disk_cleaner_config::create_scanner(
        tmp.path().to_path_buf(),
        vec![],
        vec![],
        false,
        false,
    );

    // Full mode: process scan + history
    disk_cleaner_monitor::run(&scanner, tmp.path(), false);
}
