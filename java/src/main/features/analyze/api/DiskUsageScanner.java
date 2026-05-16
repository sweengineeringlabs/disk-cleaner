package main.features.analyze.api;

import main.features.config.core.DefaultProjectScanner;

/** Scans any path for generic disk usage. */
public interface DiskUsageScanner {
    void run(DefaultProjectScanner ctx, int depth);
}
