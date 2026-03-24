//! End-to-end tests for disk-cleaner-search crate.

use std::fs;
use std::path::Path;
use std::sync::atomic::Ordering;

use disk_cleaner_config::{create_scanner, load_config};

fn write_file(root: &Path, relative: &str, content: &str) {
    let full = root.join(relative);
    if let Some(parent) = full.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(&full, content).unwrap();
}

fn create_multi_config(dir: &Path) -> std::path::PathBuf {
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
source_extensions = [".rs"]
search_exclude = ["target"]

[profiles.node]
name = "Node.js"
marker = "package-lock.json"
type = "remove"
targets = ["node_modules"]
source_extensions = [".js"]
search_exclude = ["node_modules"]
"#,
    )
    .unwrap();
    config_path
}

/// @covers: search across multiple profiles
#[test]
fn test_e2e_search_multi_profile() {
    let tmp = tempfile::tempdir().unwrap();

    write_file(tmp.path(), "rust-app/Cargo.lock", "");
    write_file(tmp.path(), "rust-app/src/main.rs", "fn main() {}");
    write_file(tmp.path(), "node-app/package-lock.json", "");
    write_file(tmp.path(), "node-app/index.js", "console.log('hi')");

    let config_path = create_multi_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    disk_cleaner_search::run(
        &scanner,
        &["rust".to_string(), "node".to_string()],
        &config,
        None,
    );

    assert_eq!(scanner.total_projects.load(Ordering::Relaxed), 2);
}

/// @covers: search does not modify filesystem
#[test]
fn test_e2e_search_does_not_modify_files() {
    let tmp = tempfile::tempdir().unwrap();

    write_file(tmp.path(), "app/package-lock.json", "");
    write_file(tmp.path(), "app/node_modules/dep.js", "module.exports = {}");

    let config_path = create_multi_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    disk_cleaner_search::run(&scanner, &["node".to_string()], &config, Some("module"));

    // Files still exist
    assert!(tmp.path().join("app/node_modules/dep.js").exists());
    assert!(tmp.path().join("app/package-lock.json").exists());
}
