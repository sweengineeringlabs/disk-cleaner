//! End-to-end tests for disk-cleaner-clean crate.
//! Tests complete clean workflow across multiple profiles and project types.

use std::fs;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::Ordering;

use disk_cleaner_config::api::ProjectScanner;
use disk_cleaner_config::{create_scanner, load_config};

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn write_file(root: &Path, relative: &str, content: &[u8]) {
    let full = root.join(relative);
    if let Some(parent) = full.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let mut f = fs::File::create(&full).unwrap();
    f.write_all(content).unwrap();
}

fn create_full_config(dir: &Path) -> std::path::PathBuf {
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
optional_targets = [".next"]

[profiles.python]
name = "Python"
marker = "pyproject.toml"
type = "remove"
targets = [".venv"]
recursive_targets = ["__pycache__"]
"#,
    )
    .unwrap();
    config_path
}

// ─── E2E: Multi-profile clean ───────────────────────────────────────────────

/// @covers: full clean workflow across multiple profiles
#[test]
fn test_e2e_clean_multi_profile_removes_all_artifacts() {
    let tmp = tempfile::tempdir().unwrap();

    // Node project
    write_file(tmp.path(), "web/package-lock.json", b"");
    write_file(tmp.path(), "web/node_modules/react/index.js", &vec![0u8; 1024]);
    write_file(tmp.path(), "web/.next/build.js", &vec![0u8; 512]);

    // Python project
    write_file(tmp.path(), "ml/pyproject.toml", b"[project]\nname = \"ml\"");
    write_file(tmp.path(), "ml/.venv/lib/pkg.py", &vec![0u8; 2048]);
    write_file(tmp.path(), "ml/src/__pycache__/main.pyc", &vec![0u8; 256]);

    let config_path = create_full_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Clean both profiles
    disk_cleaner_clean::run(
        &scanner,
        &["node".to_string(), "python".to_string()],
        &config,
        false,
        false,
    );

    // Node artifacts gone
    assert!(!tmp.path().join("web/node_modules").exists());
    assert!(!tmp.path().join("web/.next").exists());

    // Python artifacts gone
    assert!(!tmp.path().join("ml/.venv").exists());
    assert!(!tmp.path().join("ml/src/__pycache__").exists());

    // Source files still exist
    assert!(tmp.path().join("web/package-lock.json").exists());
    assert!(tmp.path().join("ml/pyproject.toml").exists());

    // Totals tracked
    assert!(scanner.total_cleaned.load(Ordering::Relaxed) >= 2);
    assert!(scanner.total_size_bytes.load(Ordering::Relaxed) > 0);
}

/// @covers: scan then clean on same tree (cross-feature)
#[test]
fn test_e2e_scan_does_not_interfere_with_clean() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "app/package-lock.json", b"");
    write_file(tmp.path(), "app/node_modules/lib.bin", &vec![0u8; 512]);

    let config_path = create_full_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    // First: scan (should not modify)
    let scan_ctx = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    let profile = disk_cleaner_config::load_profile("node", &config);
    let found = scan_ctx.scan_for_projects(&profile.all_markers());
    assert_eq!(found.len(), 1);
    assert!(tmp.path().join("app/node_modules").exists());

    // Second: clean (should remove)
    let clean_ctx = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_clean::run(&clean_ctx, &["node".to_string()], &config, false, false);
    assert!(!tmp.path().join("app/node_modules").exists());
}

/// @covers: clean with yarn.lock alt marker
#[test]
fn test_e2e_clean_detects_via_alt_marker() {
    let tmp = tempfile::tempdir().unwrap();

    // Project with yarn.lock (alt marker), not package-lock.json
    write_file(tmp.path(), "app/yarn.lock", b"");
    write_file(tmp.path(), "app/node_modules/dep.js", &vec![0u8; 1024]);

    let config_path = create_full_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_clean::run(&scanner, &["node".to_string()], &config, false, false);

    assert!(!tmp.path().join("app/node_modules").exists());
    assert_eq!(scanner.total_cleaned.load(Ordering::Relaxed), 1);
}
