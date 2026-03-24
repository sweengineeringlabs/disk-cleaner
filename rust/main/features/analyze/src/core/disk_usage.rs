use disk_cleaner_config::core::context::DefaultProjectScanner;
use disk_cleaner_config::{dir_size_bytes, format_size};

use crate::api::DiskUsageScanner;

pub struct DefaultDiskUsageScanner;

impl DiskUsageScanner for DefaultDiskUsageScanner {
    fn run(&self, ctx: &DefaultProjectScanner, depth: usize) {
        println!("disk-cleaner analyze - Disk usage scan");
        println!("Path: {}", ctx.search_path.display());
        println!("Depth: {depth}");
        println!();

        let mut entries: Vec<(String, u64)> = Vec::new();
        let mut total: u64 = 0;

        let read_dir = match std::fs::read_dir(&ctx.search_path) {
            Ok(rd) => rd,
            Err(e) => {
                eprintln!("Error reading {}: {e}", ctx.search_path.display());
                return;
            }
        };

        for entry in read_dir.filter_map(|e| e.ok()) {
            if ctx.is_cancelled() {
                break;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            let size = if path.is_dir() {
                dir_size_bytes(&path)
            } else {
                entry.metadata().map(|m| m.len()).unwrap_or(0)
            };
            total += size;
            entries.push((name, size));
        }

        entries.sort_by(|a, b| b.1.cmp(&a.1));

        for (name, size) in &entries {
            if *size > 0 {
                let pct = if total > 0 {
                    (*size as f64 / total as f64) * 100.0
                } else {
                    0.0
                };
                println!("  {:>10}  {:5.1}%  {name}", format_size(*size), pct);
            }
        }

        println!();
        println!("Total: {}", format_size(total));
    }
}
