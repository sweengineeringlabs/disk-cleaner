//! Integration tests for disk-cleaner-config crate.
//! Tests TomlConfig loading, profile creation, and project scanning.

use std::fs;
use std::io::Write;
use std::path::Path;

use disk_cleaner_config::api::{ConfigProvider, ProjectScanner};
use disk_cleaner_config::{create_scanner, dir_size_bytes, format_size, load_config, load_profile};

// ─── Helpers ─────────────────────────────────────────────────────────────────

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
default_path = ""
default_profiles = ["rust"]

[profiles.rust]
name = "Rust (Cargo)"
marker = "Cargo.lock"
type = "command"
command = "cargo clean"
clean_dir = "target"
output_pattern = 'Removed (\d+) files'
source_extensions = [".rs", ".toml"]
search_exclude = ["target"]

[profiles.node]
name = "Node.js"
marker = "package-lock.json"
alt_markers = ["yarn.lock", "pnpm-lock.yaml"]
type = "remove"
targets = ["node_modules"]
optional_targets = [".next", "dist"]
source_extensions = [".js", ".ts"]
search_exclude = ["node_modules", ".next"]
"#,
    )
    .unwrap();
    config_path
}

// ─── TomlConfig Integration ─────────────────────────────────────────────────

/// @covers: DefaultConfigProvider::load
#[test]
fn test_load_config_reads_all_profiles() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());

    let config = load_config(&config_path).unwrap();
    assert_eq!(config.profile_keys().len(), 2);
    assert!(config.profile_keys().contains(&"rust".to_string()));
    assert!(config.profile_keys().contains(&"node".to_string()));
}

/// @covers: DefaultConfigProvider::get_value
#[test]
fn test_get_value_returns_unquoted_string() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());

    let config = load_config(&config_path).unwrap();
    assert_eq!(config.get_value("profiles.rust.name"), "Rust (Cargo)");
    assert_eq!(config.get_value("profiles.rust.marker"), "Cargo.lock");
    assert_eq!(config.get_value("profiles.rust.type"), "command");
}

/// @covers: DefaultConfigProvider::get_value
#[test]
fn test_get_value_missing_key_returns_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());

    let config = load_config(&config_path).unwrap();
    assert_eq!(config.get_value("profiles.nonexistent.name"), "");
}

/// @covers: DefaultConfigProvider::get_array
#[test]
fn test_get_array_parses_inline_array() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());

    let config = load_config(&config_path).unwrap();
    let arr = config.get_array("profiles.node.alt_markers");
    assert_eq!(arr, vec!["yarn.lock", "pnpm-lock.yaml"]);
}

/// @covers: DefaultConfigProvider::get_array
#[test]
fn test_get_array_missing_key_returns_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());

    let config = load_config(&config_path).unwrap();
    assert!(config.get_array("profiles.rust.nonexistent").is_empty());
}

/// @covers: DefaultConfigProvider::load
#[test]
fn test_load_config_nonexistent_file_returns_error() {
    let result = load_config(Path::new("/nonexistent/path/config.toml"));
    assert!(result.is_err());
}

/// @covers: DefaultConfigProvider::load (comment with hash inside quotes)
#[test]
fn test_load_config_preserves_hash_inside_quotes() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = tmp.path().join("test.toml");
    fs::write(
        &config_path,
        "[profiles.test]\nname = \"Test\"\nmarker = \"test.lock\"\ntype = \"command\"\npattern = 'Removed #(\\d+) files'\n",
    )
    .unwrap();

    let config = load_config(&config_path).unwrap();
    assert_eq!(
        config.get_value("profiles.test.pattern"),
        r"Removed #(\d+) files"
    );
}

// ─── CleanProfile Integration ───────────────────────────────────────────────

/// @covers: load_profile
#[test]
fn test_load_profile_command_type_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let p = load_profile("rust", &config);
    assert_eq!(p.key, "rust");
    assert_eq!(p.name, "Rust (Cargo)");
    assert_eq!(p.marker, "Cargo.lock");
    assert_eq!(p.profile_type, "command");
    assert_eq!(p.command, "cargo clean");
    assert_eq!(p.clean_dir, "target");
}

/// @covers: load_profile
#[test]
fn test_load_profile_remove_type_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let p = load_profile("node", &config);
    assert_eq!(p.profile_type, "remove");
    assert!(p.targets.contains(&"node_modules".to_string()));
    assert!(p.optional_targets.contains(&".next".to_string()));
}

/// @covers: CleanProfile::all_markers
#[test]
fn test_all_markers_includes_primary_and_alternates() {
    let tmp = tempfile::tempdir().unwrap();
    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();

    let p = load_profile("node", &config);
    let markers = p.all_markers();
    assert!(markers.contains(&"package-lock.json"));
    assert!(markers.contains(&"yarn.lock"));
    assert!(markers.contains(&"pnpm-lock.yaml"));
}

// ─── ProjectScanner Integration ─────────────────────────────────────────────

/// @covers: DefaultProjectScanner::scan_for_projects
#[test]
fn test_scan_for_projects_finds_all_by_marker() {
    let tmp = tempfile::tempdir().unwrap();

    // Create 3 node projects
    for name in &["app-web", "app-api", "lib-shared"] {
        write_file(tmp.path(), &format!("{name}/package-lock.json"), "");
        write_file(tmp.path(), &format!("{name}/node_modules/dep.js"), "module");
    }

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    let found = scanner.scan_for_projects(&profile.all_markers());
    assert_eq!(found.len(), 3);
}

/// @covers: DefaultProjectScanner::scan_for_projects
#[test]
fn test_scan_for_projects_returns_empty_for_no_matches() {
    let tmp = tempfile::tempdir().unwrap();
    write_file(tmp.path(), "something.txt", "hello");

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("rust", &config);

    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);
    let found = scanner.scan_for_projects(&profile.all_markers());
    assert_eq!(found.len(), 0);
}

/// @covers: DefaultProjectScanner::filter_projects
#[test]
fn test_filter_projects_applies_exclude_patterns() {
    let tmp = tempfile::tempdir().unwrap();

    for name in &["app-web", "app-api", "lib-shared"] {
        write_file(tmp.path(), &format!("{name}/package-lock.json"), "");
    }

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let scanner = create_scanner(
        tmp.path().to_path_buf(),
        vec!["lib-shared".to_string()],
        vec![],
        false,
        false,
    );
    let found = scanner.scan_for_projects(&profile.all_markers());
    let (to_process, skipped) = scanner.filter_projects(&found);

    assert_eq!(to_process.len(), 2);
    assert_eq!(skipped.len(), 1);
}

/// @covers: DefaultProjectScanner::filter_projects
#[test]
fn test_filter_projects_applies_include_patterns() {
    let tmp = tempfile::tempdir().unwrap();

    for name in &["app-web", "app-api", "lib-shared"] {
        write_file(tmp.path(), &format!("{name}/package-lock.json"), "");
    }

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let scanner = create_scanner(
        tmp.path().to_path_buf(),
        vec![],
        vec!["app-web".to_string()],
        false,
        false,
    );
    let found = scanner.scan_for_projects(&profile.all_markers());
    let (to_process, skipped) = scanner.filter_projects(&found);

    assert_eq!(to_process.len(), 1);
    assert_eq!(skipped.len(), 2);
}

/// @covers: DefaultProjectScanner::filter_projects
#[test]
fn test_filter_projects_clean_all_ignores_exclude() {
    let tmp = tempfile::tempdir().unwrap();

    for name in &["app-web", "app-api", "lib-shared"] {
        write_file(tmp.path(), &format!("{name}/package-lock.json"), "");
    }

    let config_path = create_test_config(tmp.path());
    let config = load_config(&config_path).unwrap();
    let profile = load_profile("node", &config);

    let scanner = create_scanner(
        tmp.path().to_path_buf(),
        vec!["lib-shared".to_string()],
        vec![],
        true, // clean_all
        false,
    );
    let found = scanner.scan_for_projects(&profile.all_markers());
    let (to_process, skipped) = scanner.filter_projects(&found);

    assert_eq!(to_process.len(), 3);
    assert_eq!(skipped.len(), 0);
}

// ─── Utility Functions ──────────────────────────────────────────────────────

/// @covers: format_size
#[test]
fn test_format_size_bytes() {
    assert_eq!(format_size(0), "0 B");
    assert_eq!(format_size(512), "512 B");
}

/// @covers: format_size
#[test]
fn test_format_size_kib() {
    assert_eq!(format_size(1024), "1.00 KiB");
    assert_eq!(format_size(1536), "1.50 KiB");
}

/// @covers: format_size
#[test]
fn test_format_size_mib() {
    assert_eq!(format_size(1024 * 1024), "1.00 MiB");
}

/// @covers: format_size
#[test]
fn test_format_size_gib() {
    assert_eq!(format_size(1024 * 1024 * 1024), "1.00 GiB");
}

/// @covers: dir_size_bytes
#[test]
fn test_dir_size_bytes_nonexistent_returns_zero() {
    assert_eq!(dir_size_bytes(Path::new("/nonexistent/path/12345")), 0);
}

/// @covers: dir_size_bytes
#[test]
fn test_dir_size_bytes_measures_directory_content() {
    let tmp = tempfile::tempdir().unwrap();
    let data = vec![0u8; 4096];
    let file_path = tmp.path().join("data.bin");
    {
        let mut f = fs::File::create(&file_path).unwrap();
        f.write_all(&data).unwrap();
        // f drops here, flushing and closing the file handle
    }

    let size = dir_size_bytes(tmp.path());
    assert_eq!(size, 4096);
}

/// @covers: DefaultProjectScanner::relative_path
#[test]
fn test_relative_path_strips_search_root() {
    let tmp = tempfile::tempdir().unwrap();
    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    let full = tmp.path().join("app-web");
    let rel = scanner.relative_path(&full);
    assert_eq!(rel.to_string_lossy(), "app-web");
}
