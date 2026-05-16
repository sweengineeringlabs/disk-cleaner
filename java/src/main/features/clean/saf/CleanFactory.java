package main.features.clean.saf;

import main.features.clean.core.DefaultCleaner;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Factory entry point for the clean feature. */
public class CleanFactory {
    public static void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config,
                    boolean dryRun, boolean parallel) {
        var cleaner = new DefaultCleaner();
        cleaner.run(ctx, profileKeys, config, dryRun, parallel);
    }
}
