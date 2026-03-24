use crate::api::{CleanProfile, ConfigProvider};

/// Load a CleanProfile from config by key.
pub fn load_profile(key: &str, config: &dyn ConfigProvider) -> CleanProfile {
    let prefix = format!("profiles.{key}");
    let get = |field: &str| config.get_value(&format!("{prefix}.{field}"));
    let get_arr = |field: &str| config.get_array(&format!("{prefix}.{field}"));

    CleanProfile {
        key: key.to_string(),
        name: get("name"),
        marker: get("marker"),
        alt_markers: get_arr("alt_markers"),
        profile_type: get("type"),
        command: get("command"),
        wrapper: get("wrapper"),
        wrapper_windows: get_arr("wrapper_windows").into_iter().next().unwrap_or_default(),
        clean_dir: get("clean_dir"),
        targets: get_arr("targets"),
        optional_targets: get_arr("optional_targets"),
        recursive_targets: get_arr("recursive_targets"),
        source_extensions: get_arr("source_extensions"),
        search_exclude: get_arr("search_exclude"),
        build_command: get("build_command"),
        output_pattern: get("output_pattern"),
    }
}
