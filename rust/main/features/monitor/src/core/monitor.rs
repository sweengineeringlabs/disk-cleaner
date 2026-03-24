use std::path::Path;

use sysinfo::System;

use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::format_size;

use crate::api::{BuildProcessInfo, HistoryStore, ProcessMonitor};
use crate::core::history::DefaultHistoryStore;

const BUILD_PROCESS_NAMES: &[&str] = &[
    "cargo", "rustc", "rustup", "clippy-driver", "rust-analyzer",
    "node", "npm", "npx", "yarn", "pnpm", "bun", "deno", "tsc", "esbuild", "vite",
    "java", "javac", "mvn", "gradle", "gradlew", "kotlin",
    "python", "python3", "pip", "pip3", "pytest", "mypy", "ruff",
    "cc", "gcc", "g++", "clang", "clang++", "make", "cmake", "ninja",
    "dotnet", "msbuild",
    "go", "zig",
];

const HIGH_MEMORY_THRESHOLD: u64 = 512 * 1024 * 1024; // 512 MiB

pub struct DefaultProcessMonitor;

impl ProcessMonitor for DefaultProcessMonitor {
    fn run(&self, _ctx: &DefaultProjectScanner, config_dir: &Path, history_only: bool) {
        if !history_only {
            println!("disk-cleaner monitor - Resource & history report");
            println!();

            show_system_memory();
            show_build_processes();
        }

        show_run_history(config_dir);

        println!();
        println!("{}", "=".repeat(50));
        println!("Monitor complete!");
    }
}

fn show_system_memory() {
    let mut sys = System::new();
    sys.refresh_memory();

    let total = sys.total_memory();
    let used = sys.used_memory();
    let free = total.saturating_sub(used);
    let used_pct = if total > 0 {
        (used as f64 / total as f64) * 100.0
    } else {
        0.0
    };

    println!("--- System Memory ---");
    println!("  Total:  {}", format_size(total));
    println!("  Used:   {} ({:.1}%)", format_size(used), used_pct);
    println!("  Free:   {}", format_size(free));
    println!();
}

fn show_build_processes() {
    let mut sys = System::new();
    sys.refresh_processes(sysinfo::ProcessesToUpdate::All, true);

    let mut processes: Vec<BuildProcessInfo> = Vec::new();

    for (_pid, process) in sys.processes() {
        let name = process.name().to_string_lossy().to_string();
        // Strip extension for matching (e.g. "cargo.exe" -> "cargo")
        let base_name = name.strip_suffix(".exe").unwrap_or(&name);

        if BUILD_PROCESS_NAMES.iter().any(|&bp| bp == base_name) {
            processes.push(BuildProcessInfo {
                pid: process.pid().as_u32(),
                name: base_name.to_string(),
                cpu_seconds: process.cpu_usage() as f64,
                memory_bytes: process.memory(),
            });
        }
    }

    processes.sort_by(|a, b| b.memory_bytes.cmp(&a.memory_bytes));

    println!("--- Active Build Processes ---");

    if processes.is_empty() {
        println!("  No active build processes found.");
    } else {
        println!(
            "  {:<8} {:<20} {:>12} {:>14}",
            "PID", "Process", "CPU (%)", "Memory"
        );
        println!("  {}", "-".repeat(58));

        let mut total_mem: u64 = 0;
        for p in &processes {
            total_mem += p.memory_bytes;
            println!(
                "  {:<8} {:<20} {:>12.1} {:>14}",
                p.pid,
                p.name,
                p.cpu_seconds,
                format_size(p.memory_bytes),
            );
        }

        println!();
        println!("  Total build process memory: {}", format_size(total_mem));

        // High resource alerts
        let alerts: Vec<&BuildProcessInfo> = processes
            .iter()
            .filter(|p| p.memory_bytes >= HIGH_MEMORY_THRESHOLD)
            .collect();

        if !alerts.is_empty() {
            println!();
            println!("--- High Resource Alerts ---");
            for a in &alerts {
                println!(
                    "  ! {} (PID {}) using {} RAM",
                    a.name,
                    a.pid,
                    format_size(a.memory_bytes),
                );
            }
        }
    }

    println!();
}

fn show_run_history(config_dir: &Path) {
    let store = DefaultHistoryStore::new(config_dir);
    let entries = store.load();

    println!("--- Run History ---");

    if entries.is_empty() {
        println!("  No history recorded yet. Run clean or analyze to build history.");
        return;
    }

    // Show last 10
    let start = if entries.len() > 10 {
        entries.len() - 10
    } else {
        0
    };
    let recent = &entries[start..];

    println!(
        "  {:<22} {:<10} {:<12} {:>10} {:>16}",
        "Date", "Command", "Profiles", "Projects", "Size"
    );
    println!("  {}", "-".repeat(75));

    for e in recent {
        let date_str = if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&e.timestamp) {
            dt.format("%Y-%m-%d %H:%M").to_string()
        } else {
            e.timestamp.clone()
        };

        println!(
            "  {:<22} {:<10} {:<12} {:>10} {:>16}",
            date_str,
            e.command,
            e.profiles,
            e.projects,
            e.size_formatted,
        );
    }

    // Trend analysis
    let cleans: Vec<&crate::api::HistoryEntry> = entries
        .iter()
        .filter(|e| e.command == "clean" && e.size_bytes > 0)
        .collect();

    if cleans.len() >= 2 {
        let first = cleans[0].size_bytes as f64;
        let last = cleans[cleans.len() - 1].size_bytes as f64;
        if first > 0.0 {
            let change_pct = ((last - first) / first) * 100.0;
            let arrow = if change_pct < 0.0 { "\u{2193}" } else { "\u{2191}" };
            println!();
            println!(
                "  Trend: artifacts {} {:.1}% since first recorded clean",
                arrow,
                change_pct.abs()
            );
        }
    }
}
