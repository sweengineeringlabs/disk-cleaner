use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::core::context::DefaultProjectScanner;

/// Searches for projects and optionally scans source files for text.
pub trait Searcher {
    fn run(
        &self,
        ctx: &DefaultProjectScanner,
        profile_keys: &[String],
        config: &dyn ConfigProvider,
        text: Option<&str>,
    );
}
