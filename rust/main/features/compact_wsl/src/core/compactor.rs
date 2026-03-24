use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::format_size;

use crate::api::{VhdxEntry, WslCompactor};

pub struct DefaultWslCompactor;

impl WslCompactor for DefaultWslCompactor {
    fn run(&self, ctx: &DefaultProjectScanner, dry_run: bool) {
        println!("disk-cleaner compact-wsl - WSL disk compaction");
        println!();

        if !cfg!(target_os = "windows") {
            eprintln!("Error: compact-wsl is only available on Windows.");
            return;
        }

        // Check WSL availability
        let wsl_check = Command::new("wsl").arg("--version").output();
        if wsl_check.is_err() {
            eprintln!("Error: WSL is not installed.");
            return;
        }

        // Admin check (only needed for actual compaction)
        if !dry_run && !is_admin() {
            eprintln!("compact-wsl requires administrator privileges (for diskpart).");
            eprintln!("Re-run in an elevated terminal, or use --dry-run to preview.");
            return;
        }

        // Discover distros
        let distros = discover_distros();
        if distros.is_empty() {
            println!("No WSL distributions found.");
            return;
        }

        // Find VHDX files
        let entries = find_vhdx_files(&distros);
        if entries.is_empty() {
            println!("No WSL virtual disk files found.");
            return;
        }

        // Display findings
        let mode_label = if dry_run { " (dry run)" } else { "" };
        println!("--- WSL VHDX Compaction{mode_label} ---");
        println!("Found {} virtual disk(s):", entries.len());
        println!();

        let mut total_before: u64 = 0;
        for entry in &entries {
            println!("  {}", entry.distro);
            println!("    vhdx: {}", format_size(entry.size_bytes));
            println!("    {}", entry.path);
            total_before += entry.size_bytes;
        }

        println!();
        println!("Total vhdx size: {}", format_size(total_before));

        // Dry run — show what would happen
        if dry_run {
            println!();
            println!("Would perform:");
            println!("  1. wsl --shutdown (terminates all running WSL processes)");
            println!("  2. diskpart compact on {} vhdx file(s)", entries.len());
            println!("  3. Report space reclaimed");
            println!();
            println!("Run without --dry-run to execute (requires Administrator).");
            return;
        }

        // Shutdown WSL
        println!();
        println!("Shutting down WSL...");
        let shutdown = Command::new("wsl").arg("--shutdown").output();
        match shutdown {
            Ok(out) if out.status.success() => {
                std::thread::sleep(std::time::Duration::from_secs(2));
                println!("WSL shut down.");
            }
            _ => {
                eprintln!("Failed to shut down WSL.");
                return;
            }
        }

        // Compact each VHDX
        let mut total_reclaimed: u64 = 0;

        for entry in &entries {
            if ctx.is_cancelled() {
                break;
            }

            println!();
            println!("Compacting {}...", entry.distro);
            println!("  {}", entry.path);

            let before_size = std::fs::metadata(&entry.path)
                .map(|m| m.len())
                .unwrap_or(entry.size_bytes);

            let success = compact_vhdx(&entry.path);

            if success {
                let after_size = std::fs::metadata(&entry.path)
                    .map(|m| m.len())
                    .unwrap_or(before_size);
                let reclaimed = before_size.saturating_sub(after_size);

                println!("  Before:    {}", format_size(before_size));
                println!("  After:     {}", format_size(after_size));
                if reclaimed > 0 {
                    println!("  Reclaimed: {}", format_size(reclaimed));
                    total_reclaimed += reclaimed;
                } else {
                    println!("  Reclaimed: 0 B (already compact)");
                }
            } else {
                eprintln!("  Failed to compact.");
            }
        }

        // Summary
        println!();
        println!("{}", "=".repeat(50));
        if total_reclaimed > 0 {
            println!("Total reclaimed: {}", format_size(total_reclaimed));
        } else {
            println!("No space reclaimed. Virtual disks were already compact.");
        }
    }
}

/// Discover WSL distro names via `wsl --list --quiet`.
fn discover_distros() -> Vec<String> {
    let output = Command::new("wsl")
        .args(["--list", "--quiet"])
        .output();

    match output {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            stdout
                .lines()
                .map(|l| l.trim().replace('\0', ""))
                .filter(|l| !l.is_empty())
                .collect()
        }
        Err(_) => Vec::new(),
    }
}

/// Find ext4.vhdx files for discovered distros.
fn find_vhdx_files(distros: &[String]) -> Vec<VhdxEntry> {
    let mut entries = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut all_vhdx: Vec<PathBuf> = Vec::new();

    // Check modern WSL location: %LOCALAPPDATA%\wsl\
    if let Ok(local_app) = std::env::var("LOCALAPPDATA") {
        let wsl_root = PathBuf::from(&local_app).join("wsl");
        if wsl_root.exists() {
            collect_vhdx_files(&wsl_root, 3, &mut all_vhdx);
        }

        // Check legacy Packages location
        let packages_root = PathBuf::from(&local_app).join("Packages");
        if packages_root.exists() {
            for distro in distros {
                if let Ok(read_dir) = std::fs::read_dir(&packages_root) {
                    for entry in read_dir.filter_map(|e| e.ok()) {
                        let name = entry.file_name().to_string_lossy().to_string();
                        if name.contains("CanonicalGroupLimited") && name.contains(distro) {
                            let local_state = entry.path().join("LocalState").join("ext4.vhdx");
                            if local_state.exists() {
                                if let Ok(meta) = std::fs::metadata(&local_state) {
                                    if meta.len() > 0 {
                                        all_vhdx.push(local_state);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Assign VHDX files to distros
    let mut vhdx_idx = 0;
    for distro in distros {
        if vhdx_idx >= all_vhdx.len() {
            break;
        }
        let vf = &all_vhdx[vhdx_idx];
        let path_str = vf.to_string_lossy().to_string();
        if !seen.contains(&path_str) {
            let size = std::fs::metadata(vf).map(|m| m.len()).unwrap_or(0);
            entries.push(VhdxEntry {
                distro: distro.clone(),
                path: path_str.clone(),
                size_bytes: size,
            });
            seen.insert(path_str);
            vhdx_idx += 1;
        }
    }

    entries
}

/// Recursively find ext4.vhdx files up to a given depth.
fn collect_vhdx_files(dir: &Path, max_depth: usize, results: &mut Vec<PathBuf>) {
    if max_depth == 0 {
        return;
    }
    if let Ok(read_dir) = std::fs::read_dir(dir) {
        for entry in read_dir.filter_map(|e| e.ok()) {
            let path = entry.path();
            if path.is_file() {
                if let Some(name) = path.file_name() {
                    if name == "ext4.vhdx" {
                        if let Ok(meta) = std::fs::metadata(&path) {
                            if meta.len() > 0 {
                                results.push(path);
                            }
                        }
                    }
                }
            } else if path.is_dir() {
                collect_vhdx_files(&path, max_depth - 1, results);
            }
        }
    }
}

/// Compact a VHDX file using diskpart.
fn compact_vhdx(vhdx_path: &str) -> bool {
    let script_content = format!(
        "select vdisk file=\"{}\"\nattach vdisk readonly\ncompact vdisk\ndetach vdisk\nexit\n",
        vhdx_path
    );

    // Write diskpart script to temp file
    let temp_path = std::env::temp_dir().join(format!("dc_compact_{}.txt", std::process::id()));
    match std::fs::File::create(&temp_path) {
        Ok(mut f) => {
            if f.write_all(script_content.as_bytes()).is_err() {
                return false;
            }
        }
        Err(_) => return false,
    }

    println!("  Running diskpart (this may take several minutes)...");

    let result = Command::new("diskpart")
        .arg("/s")
        .arg(&temp_path)
        .output();

    // Cleanup temp file
    let _ = std::fs::remove_file(&temp_path);

    match result {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            out.status.success() && !stdout.contains("error") && !stdout.contains("failed")
        }
        Err(_) => false,
    }
}

/// Check if running with administrator privileges (Windows).
fn is_admin() -> bool {
    // Try running a command that requires admin
    Command::new("net")
        .args(["session"])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}
