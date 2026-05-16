use disk_cleaner_config::core::context::DefaultProjectScanner;

/// Discovers and compacts WSL virtual disks.
pub trait WslCompactor {
    fn run(&self, ctx: &DefaultProjectScanner, dry_run: bool);
}

/// Info about a discovered VHDX file.
#[derive(Debug)]
pub struct VhdxEntry {
    pub distro: String,
    pub path: String,
    pub size_bytes: u64,
    /// Bytes used inside the ext4 filesystem (queried via `df -B1`). None if WSL query failed.
    pub inner_used_bytes: Option<u64>,
    /// Bytes reclaimable by compaction (size_bytes - inner_used_bytes). None if query failed.
    pub reclaimable_bytes: Option<u64>,
}
