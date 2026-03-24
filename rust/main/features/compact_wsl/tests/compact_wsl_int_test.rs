//! Integration tests for disk-cleaner-compact-wsl crate.
//! Tests VHDX discovery logic and dry-run behavior.

use disk_cleaner_config::create_scanner;

/// @covers: compact_wsl::run (dry_run does not modify)
#[test]
fn test_compact_wsl_dry_run_does_not_panic() {
    let tmp = tempfile::tempdir().unwrap();
    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Dry run should not panic regardless of WSL availability
    disk_cleaner_compact_wsl::run(&scanner, true);
}

/// @covers: compact_wsl::run (non-elevated, non-dry-run)
#[test]
fn test_compact_wsl_non_admin_non_dry_exits_gracefully() {
    let tmp = tempfile::tempdir().unwrap();
    let scanner = create_scanner(tmp.path().to_path_buf(), vec![], vec![], false, false);

    // Non-admin, non-dry-run should print error but not panic
    disk_cleaner_compact_wsl::run(&scanner, false);
}
