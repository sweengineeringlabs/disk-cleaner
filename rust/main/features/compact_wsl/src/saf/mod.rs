use disk_cleaner_config::core::context::DefaultProjectScanner;

use crate::api::WslCompactor;
use crate::core::DefaultWslCompactor;

/// Create and run the compact-wsl feature.
pub fn run(ctx: &DefaultProjectScanner, dry_run: bool) {
    let compactor = DefaultWslCompactor;
    compactor.run(ctx, dry_run);
}
