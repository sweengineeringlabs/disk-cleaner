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
}
