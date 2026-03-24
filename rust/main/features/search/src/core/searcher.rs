use std::path::Path;
use std::sync::atomic::Ordering;

use disk_cleaner_config::api::{CleanProfile, ConfigProvider, ProjectScanner};
use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::{dir_size_bytes, format_size, load_profile};

use crate::api::Searcher;

pub struct DefaultSearcher;

impl Searcher for DefaultSearcher {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        text: Option<&str>,
    ) {
        let count = profile_keys.len();

        println!("disk-cleaner search - Project finder");
        println!("Path: {}", ctx.search_path.display());
        println!("Profiles: {}", profile_keys.join(", "));

        for (i, key) in profile_keys.iter().enumerate() {
            if ctx.is_cancelled() {
                break;
            }
            let profile = load_profile(key, config);
            self.search_profile(ctx, &profile, i + 1, count, text);
        }

        let total = ctx.total_projects.load(Ordering::Relaxed);
        println!();
        println!("{}", "=".repeat(50));
        println!("Search complete! Found {total} projects across {count} profiles.");
    }
}

impl DefaultSearcher {
    fn search_profile(
        &self,
        ctx: &DefaultProjectScanner,
        profile: &CleanProfile,
        index: usize,
        count: usize,
        text: Option<&str>,
    ) {
        println!();
        println!("--- {} [{index}/{count}] ---", profile.name);
        println!("Scanning for {} projects in: {}", profile.name, ctx.search_path.display());

        let found = ctx.scan_for_projects(&profile.all_markers());
        let (to_process, skipped) = ctx.filter_projects(&found);

        ctx.total_projects.fetch_add(to_process.len() as u32, Ordering::Relaxed);
        ctx.total_skipped.fetch_add(skipped.len() as u32, Ordering::Relaxed);

        println!();
        println!("Found {} {} projects ({} filtered)", found.len(), profile.name, to_process.len());

        for dir in &to_process {
            if ctx.is_cancelled() {
                break;
            }
            let rel = ctx.relative_path(dir);
            let size = estimate_artifact_size(profile, dir);
            println!("  {} (artifacts: {})", rel.display(), format_size(size));

            if let Some(pattern) = text {
                search_text_in_project(profile, dir, pattern);
            }
        }
    }
}

fn estimate_artifact_size(profile: &CleanProfile, dir: &Path) -> u64 {
    match profile.profile_type.as_str() {
        "command" if !profile.clean_dir.is_empty() => {
            dir_size_bytes(&dir.join(&profile.clean_dir))
        }
        "remove" => {
            profile.targets.iter()
                .chain(profile.optional_targets.iter())
                .map(|t| dir_size_bytes(&dir.join(t)))
                .sum()
        }
        _ => 0,
    }
}

fn search_text_in_project(profile: &CleanProfile, dir: &Path, pattern: &str) {
    for entry in walkdir::WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
    {
        let path = entry.path();
        let path_str = path.to_string_lossy();
        if profile.search_exclude.iter().any(|ex| path_str.contains(ex)) {
            continue;
        }

        let ext = path.extension()
            .map(|e| format!(".{}", e.to_string_lossy()))
            .unwrap_or_default();
        if !profile.source_extensions.is_empty() && !profile.source_extensions.contains(&ext) {
            continue;
        }

        if let Ok(content) = std::fs::read_to_string(path) {
            for (line_num, line) in content.lines().enumerate() {
                if line.contains(pattern) {
                    let rel = path.strip_prefix(dir).unwrap_or(path);
                    println!("    {}:{}: {}", rel.display(), line_num + 1, line.trim());
                }
            }
        }
    }
}
