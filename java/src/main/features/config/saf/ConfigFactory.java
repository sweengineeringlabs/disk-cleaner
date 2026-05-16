package main.features.config.saf;

import main.features.config.api.CleanProfile;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultConfigProvider;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.core.ProfileLoader;

/** Factory methods for config components. */
public class ConfigFactory {

    public static DefaultConfigProvider loadConfig(String path) {
        return DefaultConfigProvider.load(path);
    }

    public static CleanProfile loadProfile(String key, ConfigProvider config) {
        return ProfileLoader.load(key, config);
    }

    public static DefaultProjectScanner createScanner(String searchPath, String[] exclude,
                                                String[] include, boolean cleanAll,
                                                boolean jsonOutput) {
        return new DefaultProjectScanner(searchPath, exclude, include, cleanAll, jsonOutput);
    }

    public static long dirSizeBytes(String path) {
        return DefaultProjectScanner.dirSizeBytesStatic(path);
    }

    public static String formatSize(long bytes) {
        return DefaultProjectScanner.formatSizeStatic(bytes);
    }
}
