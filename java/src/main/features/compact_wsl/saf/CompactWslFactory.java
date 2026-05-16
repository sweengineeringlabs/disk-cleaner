package main.features.compact_wsl.saf;

import main.features.compact_wsl.core.DefaultWslCompactor;
import main.features.config.core.DefaultProjectScanner;

/** Factory entry point for the compact-wsl feature. */
public class CompactWslFactory {
    public static void run(DefaultProjectScanner ctx, boolean dryRun) {
        var compactor = new DefaultWslCompactor();
        compactor.run(ctx, dryRun);
    }
}
