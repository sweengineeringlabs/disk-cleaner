package main.features.analyze.saf;

import main.features.analyze.core.DefaultAnalyzer;
import main.features.analyze.core.DefaultDiskUsageScanner;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;

/** Factory entry point for the analyze feature. */
public class AnalyzeFactory {
    public static void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, boolean benchmark) {
        var analyzer = new DefaultAnalyzer();
        analyzer.run(ctx, profileKeys, config, benchmark);
    }

    public static void runDiskUsage(DefaultProjectScanner ctx, int depth) {
        var scanner = new DefaultDiskUsageScanner();
        scanner.run(ctx, depth);
    }
}
