/// Represents a language profile loaded from TOML config.
#[derive(Debug, Clone)]
pub struct CleanProfile {
    pub key: String,
    pub name: String,
    pub marker: String,
    pub alt_markers: Vec<String>,
    pub profile_type: String,
    pub command: String,
    pub wrapper: String,
    pub wrapper_windows: String,
    pub clean_dir: String,
    pub targets: Vec<String>,
    pub optional_targets: Vec<String>,
    pub recursive_targets: Vec<String>,
    pub source_extensions: Vec<String>,
    pub search_exclude: Vec<String>,
    pub build_command: String,
    pub output_pattern: String,
}

impl CleanProfile {
    /// All marker files: primary + alternates.
    pub fn all_markers(&self) -> Vec<&str> {
        let mut markers = vec![self.marker.as_str()];
        for m in &self.alt_markers {
            markers.push(m.as_str());
        }
        markers
    }
}
