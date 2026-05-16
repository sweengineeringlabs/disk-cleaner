package main.features.analyze.core;

import main.features.analyze.api.DiskUsageScanner;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.saf.ConfigFactory;

import java.io.File;

/** Default implementation of disk usage scanning. */
public class DefaultDiskUsageScanner implements DiskUsageScanner {

    public void run(DefaultProjectScanner ctx, int depth) {
        System.out.println("disk-cleaner analyze - Disk usage scan");
        System.out.println("Path: " + ctx.searchPath);
        System.out.println("Depth: " + depth);
        System.out.println();

        var root = new File(ctx.searchPath);
        var entries = root.listFiles();
        if (entries == null) {
            System.err.println("Error reading: " + ctx.searchPath);
            return;
        }

        var names = new String[entries.length];
        var sizes = new long[entries.length];
        long total = 0;

        for (int i = 0; i < entries.length; i++) {
            if (ctx.isCancelled()) break;
            names[i] = entries[i].getName();
            sizes[i] = entries[i].isDirectory()
                    ? ConfigFactory.dirSizeBytes(entries[i].getAbsolutePath())
                    : entries[i].length();
            total += sizes[i];
        }

        // Sort descending by size
        for (int i = 0; i < names.length - 1; i++) {
            for (int j = 0; j < names.length - i - 1; j++) {
                if (sizes[j] < sizes[j + 1]) {
                    long ts = sizes[j]; sizes[j] = sizes[j + 1]; sizes[j + 1] = ts;
                    String tn = names[j]; names[j] = names[j + 1]; names[j + 1] = tn;
                }
            }
        }

        for (int i = 0; i < names.length; i++) {
            if (sizes[i] > 0) {
                double pct = total > 0 ? ((double) sizes[i] / total) * 100.0 : 0.0;
                System.out.printf(java.util.Locale.US, "  %10s  %5.1f%%  %s%n", ConfigFactory.formatSize(sizes[i]), pct, names[i]);
            }
        }

        System.out.println();
        System.out.println("Total: " + ConfigFactory.formatSize(total));
    }
}
