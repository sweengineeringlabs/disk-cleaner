use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::core::context::DefaultProjectScanner;

use crate::api::Cleaner;
use crate::core::DefaultCleaner;

/// Create and run the clean feature.
pub fn run(
    ctx: &DefaultProjectScanner,
    profile_keys: &[String],
    config: &dyn ConfigProvider,
    dry_run: bool,
    parallel: bool,
) {
    let cleaner = DefaultCleaner;
    cleaner.run(ctx, profile_keys, config, dry_run, parallel);
}
