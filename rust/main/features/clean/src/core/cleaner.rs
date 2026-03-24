use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use rayon::prelude::*;

use disk_cleaner_config::api::{CleanProfile, ConfigProvider, ProjectScanner};
use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::{dir_size_bytes, format_size, load_profile};

use crate::api::{Cleaner, ProjectCleaner};

pub struct DefaultCleaner;

impl Cleaner for DefaultCleaner {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        dry_run: bool,
        parallel: bool,
    ) {
        let count = profile_keys.len();

        println!("disk-cleaner clean - Build artifact cleaner");
        println!("Path: {}", ctx.search_path.display());
        println!("Profiles: {}", profile_keys.join(", "));

        for (i, key) in profile_keys.iter().enumerate() {
            if ctx.is_cancelled() {
                break;
            }
            let profile = load_profile(key, config);
            self.clean_profile(ctx, &profile, i + 1, count, dry_run, parallel);
        }

        print_summary(ctx, profile_keys);
    }
}

impl DefaultCleaner {
    fn clean_profile(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        index: usize,
        count: usize,
        dry_run: bool,
        parallel: bool,
    ) {
        println!();
        println!("--- {} [{index}/{count}] ---", profile.name);
        println!("Scanning for {} projects in: {}", profile.name, ctx.search_path.display());

        let found = ctx.scan_for_projects(&profile.all_markers());
        let (to_clean, skipped) = ctx.filter_projects(&found);

        println!();
        println!("Found {} {} projects", found.len(), profile.name);
        println!("  To clean: {}", to_clean.len());
        println!("  Skipped:  {}", skipped.len());

        ctx.total_projects.fetch_add(found.len() as u32, Ordering::Relaxed);
        ctx.total_cleaned.fetch_add(to_clean.len() as u32, Ordering::Relaxed);
        ctx.total_skipped.fetch_add(skipped.len() as u32, Ordering::Relaxed);

        if to_clean.is_empty() || ctx.is_cancelled() {
            return;
        }

        if dry_run {
            println!();
            println!("[DRY RUN] Would clean:");
            for dir in &to_clean {
                let rel = ctx.relative_path(dir);
                println!("  - {}", rel.display());
                print_dry_run_details(profile, dir);
            }
            return;
        }

        println!();
        println!("Cleaning {} projects...", profile.name);
        println!();

        let use_parallel = parallel
            && profile.profile_type == "command"
            && to_clean.len() > 1;

        if use_parallel {
            self.clean_projects_parallel(ctx, profile, &to_clean);
        } else {
            self.clean_projects_sequential(ctx, profile, &to_clean);
        }
    }

    fn clean_projects_sequential(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        to_clean: &[PathBuf],
    ) {
        let mut profile_bytes: u64 = 0;

        for (i, dir) in to_clean.iter().enumerate() {
            if ctx.is_cancelled() {
                break;
            }
            let rel = ctx.relative_path(dir);
            let freed = self.clean_project(profile, dir);
            profile_bytes += freed;

            println!(
                "[{}/{}] Cleaning: {} | freed: {} | total: {}",
                i + 1,
                to_clean.len(),
                rel.display(),
                format_size(freed),
                format_size(profile_bytes),
            );
        }

        ctx.total_size_bytes.fetch_add(profile_bytes as i64, Ordering::Relaxed);
        println!();
        println!("{} complete: {} freed", profile.name, format_size(profile_bytes));
    }

    fn clean_projects_parallel(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        to_clean: &[PathBuf],
    ) {
        let profile_bytes = AtomicU64::new(0);

        let results: Vec<(PathBuf, u64)> = to_clean
            .par_iter()
            .filter(|_| !ctx.is_cancelled())
            .map(|dir| {
                let freed = self.clean_project(profile, dir);
                profile_bytes.fetch_add(freed, Ordering::Relaxed);
                (dir.clone(), freed)
            })
            .collect();

        // Print results after all parallel jobs complete to avoid interleaved output
        for (i, (dir, freed)) in results.iter().enumerate() {
            let rel = ctx.relative_path(dir);
            println!(
                "[{}/{}] Cleaned: {} | freed: {}",
                i + 1,
                results.len(),
                rel.display(),
                format_size(*freed),
            );
        }

        let total = profile_bytes.load(Ordering::Relaxed);
        ctx.total_size_bytes.fetch_add(total as i64, Ordering::Relaxed);
        println!();
        println!("{} complete: {} freed", profile.name, format_size(total));
    }
}

impl ProjectCleaner for DefaultCleaner {
    fn clean_project(&self, profile: &CleanProfile, dir: &Path) -> u64 {
        match profile.profile_type.as_str() {
            "command" => {
                let size_before = if !profile.clean_dir.is_empty() {
                    dir_size_bytes(&dir.join(&profile.clean_dir))
                } else {
                    0
                };

                let cmd = resolve_command(profile, dir);
                let parts: Vec<&str> = cmd.split_whitespace().collect();
                if let Some((program, args)) = parts.split_first() {
                    let _ = Command::new(program).args(args).current_dir(dir).output();
                }

                size_before
            }
            "remove" => {
                let mut freed: u64 = 0;

                for target in profile.targets.iter().chain(profile.optional_targets.iter()) {
                    let tp = dir.join(target);
                    if tp.exists() {
                        freed += dir_size_bytes(&tp);
                        let _ = fs::remove_dir_all(&tp);
                    }
                }

                for target in &profile.recursive_targets {
                    for entry in walkdir::WalkDir::new(dir)
                        .into_iter()
                        .filter_map(|e| e.ok())
                        .filter(|e| {
                            e.file_type().is_dir()
                                && e.file_name().to_string_lossy() == target.as_str()
                        })
                    {
                        freed += dir_size_bytes(entry.path());
                        let _ = fs::remove_dir_all(entry.path());
                    }
                }

                freed
            }
            _ => 0,
        }
    }
}

fn resolve_command(profile: &CleanProfile, dir: &Path) -> String {
    if !profile.wrapper.is_empty() && dir.join(&profile.wrapper).exists() {
        format!("{} clean", profile.wrapper)
    } else {
        profile.command.clone()
    }
}

fn print_dry_run_details(profile: &CleanProfile, dir: &Path) {
    match profile.profile_type.as_str() {
        "command" => {
            let cmd = resolve_command(profile, dir);
            println!("    would run: {cmd}");
            if !profile.clean_dir.is_empty() {
                let cd = dir.join(&profile.clean_dir);
                if cd.exists() {
                    println!("    {}/ size: {}", profile.clean_dir, format_size(dir_size_bytes(&cd)));
                }
            }
        }
        "remove" => {
            for t in profile.targets.iter().chain(profile.optional_targets.iter()) {
                let tp = dir.join(t);
                if tp.exists() {
                    println!("    remove: {t} ({})", format_size(dir_size_bytes(&tp)));
                }
            }
        }
        _ => {}
    }
}

fn print_summary(ctx: &DefaultProjectScanner, profile_keys: &[String]) {
    let total_projects = ctx.total_projects.load(Ordering::Relaxed);
    let total_cleaned = ctx.total_cleaned.load(Ordering::Relaxed);
    let total_skipped = ctx.total_skipped.load(Ordering::Relaxed);
    let total_bytes = ctx.total_size_bytes.load(Ordering::Relaxed) as u64;

    println!();
    println!("{}", "=".repeat(50));
    println!("Cleaning complete!");
    println!("  Profiles run:       {} ({})", profile_keys.len(), profile_keys.join(", "));
    println!("  Projects found:     {total_projects}");
    println!("  Projects cleaned:   {total_cleaned}");
    println!("  Projects skipped:   {total_skipped}");
    println!("  Total space freed:  {}", format_size(total_bytes));
}
