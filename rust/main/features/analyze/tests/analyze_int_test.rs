//! Integration tests for disk-cleaner-analyze crate.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::Ordering;

use disk_cleaner_config::{create_scanner, load_config};

fn write_file(root: &Path, relative: &str, content: &[u8]) {
    let full = root.join(relative);
    if let Some(parent) = full.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let mut f = fs::File::create(&full).unwrap();
    f.write_all(content).unwrap();
}

fn create_test_config(dir: &Path) -> std::path::PathBuf {
    let config_path = dir.join("profiles.toml");
    fs::write(
        &config_path,
        r#"
[settings]
default_profiles = ["node"]

[profiles.node]
name = "Node.js"
marker = "package-lock.json"
type = "remove"
targets = ["node_modules"]
optional_targets = [".next"]
"#,
    )
    .unwrap();
    config_path
}

/// @covers: analyze::run (measures artifact sizes)
#[test]
fn test_analyze_measures_artifact_sizes() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "app/package-lock.json", b"");
    write_file(tmp.path(), "app/node_modules/dep.bin", &vec![0u8; 4096]);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_analyze::run(&scanner, &["node".to_string()], &config, false);

    let total = scanner.total_size_bytes.load(Ordering::Relaxed);
    assert!(total >= 4096, "Expected at least 4096 bytes measured, got {total}");
}

/// @covers: analyze::run (does not delete files)
#[test]
fn test_analyze_does_not_modify_filesystem() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "app/package-lock.json", b"");
    write_file(tmp.path(), "app/node_modules/dep.bin", &vec![0u8; 1024]);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_analyze::run(&scanner, &["node".to_string()], &config, false);

    // Files should still exist
    assert!(tmp.path().join("app/node_modules/dep.bin").exists());
}

/// @covers: analyze::run_disk_usage (generic scan)
#[test]
fn test_analyze_disk_usage_scans_directory() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "docs/readme.txt", &vec![0u8; 512]);
    write_file(tmp.path(), "data/big.bin", &vec![0u8; 8192]);

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Should not panic
    disk_cleaner_analyze::run_disk_usage(&scanner, 2);
}

/// @covers: analyze::run (benchmark mode, no build_command)
#[test]
fn test_analyze_benchmark_empty_build_command_does_not_panic() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "app/package-lock.json", b"");
    write_file(tmp.path(), "app/node_modules/dep.bin", &vec![0u8; 1024]);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    // benchmark=true with a profile that has no build_command should skip gracefully
    disk_cleaner_analyze::run(&scanner, &["node".to_string()], &config, true);

    // Should not panic, and files should remain untouched
    assert!(tmp.path().join("app/node_modules/dep.bin").exists());
}

/// @covers: analyze::run (empty directory)
#[test]
fn test_analyze_empty_directory_reports_zero() {
    let tmp = tempfile::tempdir().unwrap();

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_analyze::run(&scanner, &["node".to_string()], &config, false);

    assert_eq!(scanner.total_size_bytes.load(Ordering::Relaxed), 0);
}
