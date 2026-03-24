use std::path::Path;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::time::Instant;

use disk_cleaner_config::api::{CleanProfile, ConfigProvider, ProjectScanner};
use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::{dir_size_bytes, format_size, load_profile};

use crate::api::Analyzer;

pub struct DefaultAnalyzer;

/// Result of benchmarking a single project build.
#[allow(dead_code)]
struct BenchmarkResult {
    project: String,
    duration_ms: u128,
    success: bool,
}

impl Analyzer for DefaultAnalyzer {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        benchmark: bool,
    ) {
        let count = profile_keys.len();

        if benchmark {
            println!("disk-cleaner analyze -Benchmark - Build time analysis");
        } else {
            println!("disk-cleaner analyze - Disk space report");
        }
        println!("Path: {}", ctx.search_path.display());

        for (i, key) in profile_keys.iter().enumerate() {
            if ctx.is_cancelled() {
                break;
            }
            let profile = load_profile(key, config);
            if benchmark {
                self.benchmark_profile(ctx, &profile, i + 1, count);
            } else {
                self.analyze_profile(ctx, &profile, i + 1, count);
            }
        }

        println!();
        println!("{}", "=".repeat(50));
        if benchmark {
            println!("Benchmark complete!");
        } else {
            let total_bytes = ctx.total_size_bytes.load(Ordering::Relaxed) as u64;
            println!("Analysis complete!");
            println!("  Total artifact space: {}", format_size(total_bytes));
        }
    }
}

impl DefaultAnalyzer {
    fn benchmark_profile(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        index: usize,
        count: usize,
    ) {
        if profile.build_command.is_empty() {
            println!();
            println!("--- {} [{index}/{count}] ---", profile.name);
            println!("No build_command configured for {}, skipping benchmark.", profile.name);
            return;
        }

        println!();
        println!("--- {} Benchmark [{index}/{count}] ---", profile.name);
        println!("Build command: {}", profile.build_command);

        let found = ctx.scan_for_projects(&profile.all_markers());
        let (to_benchmark, _skipped) = ctx.filter_projects(&found);

        ctx.total_projects
            .fetch_add(to_benchmark.len() as u32, Ordering::Relaxed);

        println!();
        println!(
            "Benchmarking {} {} projects...",
            to_benchmark.len(),
            profile.name
        );
        println!();

        let mut results: Vec<BenchmarkResult> = Vec::new();

        for (i, dir) in to_benchmark.iter().enumerate() {
            if ctx.is_cancelled() {
                break;
            }
            let rel = ctx.relative_path(dir);
            let project_name = rel.display().to_string();
            let project_index = i + 1;
            let total = to_benchmark.len();

            let now = Instant::now();
            let success = run_build_command(&profile.build_command, dir.to_str().unwrap_or("."));
            let elapsed = now.elapsed();
            let duration_ms = elapsed.as_millis();

            let duration_str = format_duration(duration_ms);
            let status = if success { "" } else { " FAILED" };
            println!("  [{project_index}/{total}] {project_name} — {duration_str}{status}");

            results.push(BenchmarkResult {
                project: project_name,
                duration_ms,
                success,
            });
        }

        let success_results: Vec<&BenchmarkResult> =
            results.iter().filter(|r| r.success).collect();

        if !success_results.is_empty() {
            let min_ms = success_results.iter().map(|r| r.duration_ms).min().unwrap();
            let max_ms = success_results.iter().map(|r| r.duration_ms).max().unwrap();
            let avg_ms = success_results.iter().map(|r| r.duration_ms).sum::<u128>()
                / success_results.len() as u128;
            let total_ms: u128 = success_results.iter().map(|r| r.duration_ms).sum();

            println!();
            println!(
                "{} benchmark: {} projects",
                profile.name,
                success_results.len()
            );
            println!("    Fastest:  {}", format_duration(min_ms));
            println!("    Slowest:  {}", format_duration(max_ms));
            println!("    Average:  {}", format_duration(avg_ms));
            println!("    Total:    {}", format_duration(total_ms));
        }
    }

    fn analyze_profile(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        index: usize,
        count: usize,
    ) {
        println!();
        println!("--- {} [{index}/{count}] ---", profile.name);

        let found = ctx.scan_for_projects(&profile.all_markers());
        let (to_analyze, _skipped) = ctx.filter_projects(&found);

        ctx.total_projects.fetch_add(to_analyze.len() as u32, Ordering::Relaxed);

        let mut profile_bytes: u64 = 0;

        for dir in &to_analyze {
            if ctx.is_cancelled() {
                break;
            }
            let rel = ctx.relative_path(dir);
            let size = measure_artifacts(profile, dir);
            profile_bytes += size;

            if size > 0 {
                println!("  {} — {}", rel.display(), format_size(size));
            }
        }

        ctx.total_size_bytes.fetch_add(profile_bytes as i64, Ordering::Relaxed);
        println!();
        println!(
            "{}: {} total across {} projects",
            profile.name,
            format_size(profile_bytes),
            to_analyze.len()
        );
    }
}

/// Run a build command in the given directory, returning true on success.
fn run_build_command(build_command: &str, working_dir: &str) -> bool {
    let parts: Vec<&str> = build_command.split_whitespace().collect();
    if parts.is_empty() {
        return false;
    }

    let program = parts[0];
    let args = &parts[1..];

    match Command::new(program)
        .args(args)
        .current_dir(working_dir)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
    {
        Ok(status) => status.success(),
        Err(_) => false,
    }
}

/// Format milliseconds into a human-readable duration string.
fn format_duration(ms: u128) -> String {
    if ms >= 60_000 {
        let min = ms / 60_000;
        let sec = (ms % 60_000) as f64 / 1000.0;
        format!("{min}m {sec:.1}s")
    } else if ms >= 1_000 {
        let sec = ms as f64 / 1000.0;
        format!("{sec:.2}s")
    } else {
        format!("{ms}ms")
    }
}

fn measure_artifacts(profile: &CleanProfile, dir: &Path) -> u64 {
    match profile.profile_type.as_str() {
        "command" if !profile.clean_dir.is_empty() => {
            dir_size_bytes(&dir.join(&profile.clean_dir))
        }
        "remove" => {
            let mut total: u64 = 0;
            for t in profile.targets.iter().chain(profile.optional_targets.iter()) {
                total += dir_size_bytes(&dir.join(t));
            }
            for t in &profile.recursive_targets {
                for entry in walkdir::WalkDir::new(dir)
                    .into_iter()
                    .filter_map(|e| e.ok())
                    .filter(|e| {
                        e.file_type().is_dir()
                            && e.file_name().to_string_lossy() == t.as_str()
                    })
                {
                    total += dir_size_bytes(entry.path());
                }
            }
            total
        }
        _ => 0,
    }
}
