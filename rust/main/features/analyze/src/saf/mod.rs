use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::core::context::DefaultProjectScanner;

use crate::api::{Analyzer, DiskUsageScanner};
use crate::core::{DefaultAnalyzer, DefaultDiskUsageScanner};

/// Run artifact analysis across profiles.
pub fn run(
    ctx: &DefaultProjectScanner,
    profile_keys: &[String],
    config: &dyn ConfigProvider,
    benchmark: bool,
) {
    let analyzer = DefaultAnalyzer;
    analyzer.run(ctx, profile_keys, config, benchmark);
}

/// Run generic disk usage analysis.
pub fn run_disk_usage(ctx: &DefaultProjectScanner, depth: usize) {
    let scanner = DefaultDiskUsageScanner;
    scanner.run(ctx, depth);
}
