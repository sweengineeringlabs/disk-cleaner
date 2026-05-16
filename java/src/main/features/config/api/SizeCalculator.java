package main.features.config.api;

/** Utility interface for directory size calculation and formatting. */
public interface SizeCalculator {
    static long dirSizeBytes(String path) {
        return main.features.config.core.DefaultProjectScanner.dirSizeBytesStatic(path);
    }

    static String formatSize(long bytes) {
        return main.features.config.core.DefaultProjectScanner.formatSizeStatic(bytes);
    }
}
