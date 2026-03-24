use std::collections::HashMap;
use std::path::Path;

use crate::api::ConfigProvider;

/// Pure-Rust TOML config parser. Supports single-line key=value and inline arrays.
pub struct DefaultConfigProvider {
    data: HashMap<String, String>,
    profiles: Vec<String>,
}

impl DefaultConfigProvider {
    pub fn load(path: &Path) -> Result<Self, String> {
        let content = std::fs::read_to_string(path)
            .map_err(|e| format!("Config file not found: {}: {e}", path.display()))?;

        let mut data = HashMap::new();
        let mut profiles = Vec::new();
        let mut current_section = String::new();

        for raw_line in content.lines() {
            let line = strip_comment(raw_line).trim().to_string();
            if line.is_empty() {
                continue;
            }

            if line.starts_with('[') && line.ends_with(']') {
                current_section = line[1..line.len() - 1].to_string();
                if let Some(profile_key) = current_section.strip_prefix("profiles.") {
                    profiles.push(profile_key.to_string());
                }
                continue;
            }

            if let Some(eq_pos) = line.find('=') {
                let key = line[..eq_pos].trim().to_string();
                let value = line[eq_pos + 1..].trim().to_string();
                let full_key = if current_section.is_empty() {
                    key
                } else {
                    format!("{}.{}", current_section, key)
                };
                data.insert(full_key, value);
            }
        }

        Ok(Self { data, profiles })
    }
}

impl ConfigProvider for DefaultConfigProvider {
    fn get_value(&self, key: &str) -> String {
        match self.data.get(key) {
            Some(raw) => strip_quotes(raw),
            None => String::new(),
        }
    }

    fn get_array(&self, key: &str) -> Vec<String> {
        let raw = match self.data.get(key) {
            Some(r) => r.clone(),
            None => return Vec::new(),
        };

        let raw = raw.trim_start_matches('[').trim_end_matches(']');
        if raw.trim().is_empty() {
            return Vec::new();
        }

        raw.split(',')
            .map(|item| item.trim().trim_matches('"').trim_matches('\'').to_string())
            .filter(|s| !s.is_empty())
            .collect()
    }

    fn profile_keys(&self) -> &[String] {
        &self.profiles
    }
}

/// Strip inline comments, respecting quoted strings.
fn strip_comment(line: &str) -> &str {
    let mut in_single = false;
    let mut in_double = false;

    for (i, ch) in line.char_indices() {
        match ch {
            '\'' if !in_double => in_single = !in_single,
            '"' if !in_single => in_double = !in_double,
            '#' if !in_single && !in_double => return &line[..i],
            _ => {}
        }
    }
    line
}

fn strip_quotes(s: &str) -> String {
    let s = s.trim();
    if (s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')) {
        s[1..s.len() - 1].to_string()
    } else {
        s.to_string()
    }
}
