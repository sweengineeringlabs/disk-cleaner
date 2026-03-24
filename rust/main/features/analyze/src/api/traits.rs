use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::core::context::DefaultProjectScanner;

/// Analyzes disk space consumed by build artifacts.
pub trait Analyzer {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        benchmark: bool,
    );
}

/// Scans any path for generic disk usage.
pub trait DiskUsageScanner {
    fn run(&self, ctx: &DefaultProjectScanner, depth: usize);
}
