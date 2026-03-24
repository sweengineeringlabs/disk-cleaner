use disk_cleaner_config::api::{CleanProfile, ConfigProvider};
use disk_cleaner_config::core::context::DefaultProjectScanner;

/// Cleans build artifacts for a set of profiles.
pub trait Cleaner {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        dry_run: bool,
        parallel: bool,
    );
}

/// Cleans a single project directory for a given profile.
pub trait ProjectCleaner {
    fn clean_project(&self, profile: &CleanProfile, dir: &std::path::Path) -> u64;
}
