use std::path::Path;

use crate::api::{CleanProfile, ConfigProvider};
use crate::core::{DefaultConfigProvider, DefaultProjectScanner};

/// Load config from a TOML file path.
pub fn load_config(path: &Path) -> Result<DefaultConfigProvider, String> {
    DefaultConfigProvider::load(path)
}

/// Load a profile by key from a config provider.
pub fn load_profile(key: &str, config: &dyn ConfigProvider) -> CleanProfile {
    crate::core::load_profile(key, config)
}

/// Create a new project scanner with the given parameters.
pub fn create_scanner(
    search_path: std::path::PathBuf,
    exclude: Vec<String>,
    include: Vec<String>,
    clean_all: bool,
    json_output: bool,
) -> DefaultProjectScanner {
    DefaultProjectScanner::new(search_path, exclude, include, clean_all, json_output)
}

// Re-export utilities
pub use crate::core::context::{dir_size_bytes, format_size};
