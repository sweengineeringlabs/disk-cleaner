//! Integration tests for disk-cleaner-clean crate.
//! Tests the clean pipeline: scan, filter, dry-run, remove-type cleaning.

use std::fs;
use std::io::Write;
use std::path::Path;

use disk_cleaner_config::api::ProjectScanner;
use disk_cleaner_config::{create_scanner, load_config, load_profile};

use disk_cleaner_clean::api::ProjectCleaner;
use disk_cleaner_clean::core::DefaultCleaner;

// ─── Helpers ─────────────────────────────────────────────────────────────────

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
alt_markers = ["yarn.lock"]
type = "remove"
targets = ["node_modules"]
optional_targets = [".next", "dist"]
source_extensions = [".js", ".ts"]
search_exclude = ["node_modules"]

[profiles.python]
name = "Python"
marker = "pyproject.toml"
type = "remove"
targets = [".venv"]
recursive_targets = ["__pycache__"]
source_extensions = [".py"]
search_exclude = [".venv", "__pycache__"]
"#,
    )
    .unwrap();
    config_path
}

fn create_node_project(root: &Path, name: &str, nm_size: usize, next_size: usize) {
    write_file(root, &format!("{name}/package-lock.json"), b"");
    write_file(root, &format!("{name}/node_modules/dep.bin"), &vec![0u8; nm_size]);
    if next_size > 0 {
        write_file(root, &format!("{name}/.next/cache.bin"), &vec![0u8; next_size]);
    }
}

// ─── Remove-type Cleaning ────────────────────────────────────────────────────

/// @covers: DefaultCleaner::clean_project (remove-type)
#[test]
fn test_clean_project_remove_type_deletes_targets() {
    let tmp = tempfile::tempdir().unwrap();
    create_node_project(tmp.path(), "test-app", 2048, 1024);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let cleaner = DefaultCleaner;
    let freed = cleaner.clean_project(&profile, &tmp.path().join("test-app"));

    // Directories should be gone
    assert!(!tmp.path().join("test-app/node_modules").exists());
    assert!(!tmp.path().join("test-app/.next").exists());

    // Size should be tracked (node_modules + .next)
    assert!(freed >= 3072, "Expected at least 3072 bytes freed, got {freed}");
}

/// @covers: DefaultCleaner::clean_project (remove-type, missing optional)
#[test]
fn test_clean_project_remove_type_skips_missing_optional_targets() {
    let tmp = tempfile::tempdir().unwrap();
    // Create project with node_modules but no .next
    create_node_project(tmp.path(), "test-app", 2048, 0);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let cleaner = DefaultCleaner;
    let freed = cleaner.clean_project(&profile, &tmp.path().join("test-app"));

    assert!(!tmp.path().join("test-app/node_modules").exists());
    assert!(freed >= 2048);
}

/// @covers: DefaultCleaner::clean_project (recursive targets)
#[test]
fn test_clean_project_remove_type_recursive_targets() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "proj/pyproject.toml", b"[project]\nname = \"test\"");
    write_file(tmp.path(), "proj/src/__pycache__/mod.pyc", &vec![0u8; 512]);
    write_file(tmp.path(), "proj/tests/__pycache__/test.pyc", &vec![0u8; 256]);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("python", &config);

    let cleaner = DefaultCleaner;
    let freed = cleaner.clean_project(&profile, &tmp.path().join("proj"));

    assert!(!tmp.path().join("proj/src/__pycache__").exists());
    assert!(!tmp.path().join("proj/tests/__pycache__").exists());
    assert!(freed >= 768);
}

// ─── Scan + Clean Pipeline ──────────────────────────────────────────────────

/// @covers: DefaultCleaner::run (scan, filter, clean pipeline)
#[test]
fn test_clean_pipeline_scans_filters_and_cleans() {
    let tmp = tempfile::tempdir().unwrap();
    create_node_project(tmp.path(), "app-web", 1024, 0);
    create_node_project(tmp.path(), "app-api", 1024, 0);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    // Verify scan finds both
    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    let found = scanner.scan_for_projects(&profile.all_markers());
    assert_eq!(found.len(), 2);

    // Clean via full pipeline
    disk_cleaner_clean::run(&scanner, &["node".to_string()], &config, false, false);

    // Both should be cleaned
    assert!(!tmp.path().join("app-web/node_modules").exists());
    assert!(!tmp.path().join("app-api/node_modules").exists());
}

/// @covers: DefaultCleaner::run (exclude filter)
#[test]
fn test_clean_pipeline_respects_exclude_filter() {
    let tmp = tempfile::tempdir().unwrap();
    create_node_project(tmp.path(), "app-web", 1024, 0);
    create_node_project(tmp.path(), "app-api", 1024, 0);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(
        tmp.path().to_path_buf(),
        vec!["app-api".to_string()],
        vec![],
        false,
        false,
    );

    disk_cleaner_clean::run(&scanner, &["node".to_string()], &config, false, false);

    // app-web cleaned, app-api still exists
    assert!(!tmp.path().join("app-web/node_modules").exists());
    assert!(tmp.path().join("app-api/node_modules").exists());
}

// ─── Dry Run ────────────────────────────────────────────────────────────────

/// @covers: DefaultCleaner::run (dry_run does not modify)
#[test]
fn test_clean_dry_run_does_not_remove_directories() {
    let tmp = tempfile::tempdir().unwrap();
    create_node_project(tmp.path(), "test-app", 2048, 1024);

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    disk_cleaner_clean::run(&scanner, &["node".to_string()], &config, true, false);

    // Directories should still exist
    assert!(tmp.path().join("test-app/node_modules").exists());
    assert!(tmp.path().join("test-app/.next").exists());
}

// ─── Parallel Mode ──────────────────────────────────────────────────────────

/// @covers: DefaultCleaner::run (parallel mode)
#[test]
fn test_clean_parallel_mode_cleans_all_projects() {
    let tmp = tempfile::tempdir().unwrap();

    // Create 3 node projects
    create_node_project(tmp.path(), "proj-a", 1024, 0);
    create_node_project(tmp.path(), "proj-b", 1024, 0);
    create_node_project(tmp.path(), "proj-c", 1024, 0);

    // Verify all 3 exist before cleaning
    assert!(tmp.path().join("proj-a/node_modules").exists());
    assert!(tmp.path().join("proj-b/node_modules").exists());
    assert!(tmp.path().join("proj-c/node_modules").exists());

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Clean with parallel=true
    disk_cleaner_clean::run(&scanner, &["node".to_string()], &config, false, true);

    // All 3 projects should be cleaned
    assert!(
        !tmp.path().join("proj-a/node_modules").exists(),
        "proj-a/node_modules should have been removed"
    );
    assert!(
        !tmp.path().join("proj-b/node_modules").exists(),
        "proj-b/node_modules should have been removed"
    );
    assert!(
        !tmp.path().join("proj-c/node_modules").exists(),
        "proj-c/node_modules should have been removed"
    );
}
