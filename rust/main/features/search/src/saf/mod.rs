use disk_cleaner_config::api::ConfigProvider;
use disk_cleaner_config::core::context::DefaultProjectScanner;

use crate::api::Searcher;
use crate::core::DefaultSearcher;

/// Create and run the search feature.
pub fn run(
    ctx: &DefaultProjectScanner,
    profile_keys: &[String],
    config: &dyn ConfigProvider,
    text: Option<&str>,
) {
    let searcher = DefaultSearcher;
    searcher.run(ctx, profile_keys, config, text);
}
