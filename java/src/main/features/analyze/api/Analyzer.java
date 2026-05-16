package main.features.analyze.api;

import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Analyzes disk space consumed by build artifacts. */
public interface Analyzer {
    void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, boolean benchmark);
}
