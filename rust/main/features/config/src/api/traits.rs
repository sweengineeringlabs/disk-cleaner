use std::path::Path;

/// Provides access to TOML configuration values.
pub trait ConfigProvider {
    fn get_value(&self, key: &str) -> String;
    fn get_array(&self, key: &str) -> Vec<String>;
    fn profile_keys(&self) -> &[String];
}

/// Scans filesystem for projects matching marker files.
pub trait ProjectScanner {
    fn scan_for_projects(&self, markers: &[&str]) -> Vec<std::path::PathBuf>;
    fn filter_projects(&self, found: &[std::path::PathBuf]) -> (Vec<std::path::PathBuf>, Vec<std::path::PathBuf>);
}

/// Calculates directory sizes and formats bytes.
pub trait SizeCalculator {
    fn dir_size_bytes(path: &Path) -> u64;
    fn format_size(bytes: u64) -> String;
}
