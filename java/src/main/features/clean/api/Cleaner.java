package main.features.clean.api;

import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Cleans build artifacts for a set of profiles. */
public interface Cleaner {
    void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config,
             boolean dryRun, boolean parallel);
}
