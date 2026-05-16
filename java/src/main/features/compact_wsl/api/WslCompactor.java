package main.features.compact_wsl.api;

import main.features.config.core.DefaultProjectScanner;

/** Discovers and compacts WSL virtual disks. */
public interface WslCompactor {
    void run(DefaultProjectScanner ctx, boolean dryRun);
}
