//! Integration tests for disk-cleaner-search crate.

use std::fs;
use std::path::Path;

use disk_cleaner_config::api::ProjectScanner;
use disk_cleaner_config::{create_scanner, load_config, load_profile};

fn write_file(root: &Path, relative: &str, content: &str) {
    let full = root.join(relative);
    if let Some(parent) = full.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&full, content).unwrap();
}

fn create_test_config(dir: &Path) -> std::path::PathBuf {
    let config_path = dir.join("profiles.toml");
    fs::write(
        &config_path,
        r#"
[settings]
default_profiles = ["rust"]

[profiles.rust]
name = "Rust (Cargo)"
marker = "Cargo.lock"
type = "command"
command = "cargo clean"
clean_dir = "target"
source_extensions = [".rs", ".toml"]
search_exclude = ["target"]
"#,
    )
    .unwrap();
    config_path
}

/// @covers: search::run (project discovery)
#[test]
fn test_search_finds_projects_by_marker() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "proj-a/Cargo.lock", "");
    write_file(tmp.path(), "proj-b/Cargo.lock", "");
    write_file(tmp.path(), "not-rust/something.txt", "");

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("rust", &config);

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    let found = scanner.scan_for_projects(&profile.all_markers());

    assert_eq!(found.len(), 2);
}

/// @covers: search::run (full pipeline, no crash)
#[test]
fn test_search_run_completes_without_error() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "proj/Cargo.lock", "");
    write_file(tmp.path(), "proj/src/main.rs", "fn main() {}");

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Should not panic
    disk_cleaner_search::run(&scanner, &["rust".to_string()], &config, None);
}

/// @covers: search::run (text search)
#[test]
fn test_search_with_text_pattern_does_not_crash() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "proj/Cargo.lock", "");
    write_file(tmp.path(), "proj/src/main.rs", "fn main() {\n    unsafe { }\n}");

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Should not panic even with text search
    disk_cleaner_search::run(&scanner, &["rust".to_string()], &config, Some("unsafe"));
}

/// @covers: search::run (exclude filter)
#[test]
fn test_search_respects_exclude_filter() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "proj-a/Cargo.lock", "");
    write_file(tmp.path(), "proj-b/Cargo.lock", "");

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("rust", &config);

    let scanner = create_scanner(
        tmp.path().to_path_buf(),
        vec!["proj-b".to_string()],
        vec![],
        false,
        false,
    );
    let found = scanner.scan_for_projects(&profile.all_markers());
    let (to_process, skipped) = scanner.filter_projects(&found);

    assert_eq!(to_process.len(), 1);
    assert_eq!(skipped.len(), 1);
}
