package features;

import config.TomlConfig;
import model.CleanProfile;
import model.CleanerContext;

import java.io.File;

/** Analyze feature: reports disk space consumption by build artifacts. */
class Analyze {

    static void run(CleanerContext ctx, String[] profileKeys, TomlConfig toml, boolean benchmark) {
        int count = profileKeys.length;

        System.out.println("disk-cleaner analyze - Disk space report");
        System.out.println("Path: " + ctx.searchPath);

        for (int i = 0; i < count; i++) {
            if (ctx.cancelled) break;
            var profile = CleanProfile.fromToml(profileKeys[i], toml);
            analyzeProfile(ctx, profile, i + 1, count);
        }

        System.out.println();
        System.out.println("==================================================");
        System.out.println("Analysis complete!");
        System.out.println("  Total artifact space: " + CleanerContext.formatSize(ctx.totalSizeBytes));
    }

    private static void analyzeProfile(CleanerContext ctx, CleanProfile profile, int index, int count) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");

        var found = ctx.scanForProjects(profile);
        var filtered = ctx.filterProjects(found);
        var toAnalyze = filtered[0];

        ctx.totalProjects = ctx.totalProjects + toAnalyze.length;

        long profileBytes = 0;
        for (int i = 0; i < toAnalyze.length; i++) {
            if (ctx.cancelled) break;
            var rel = ctx.relativePath(toAnalyze[i]);
            long size = measureArtifacts(profile, toAnalyze[i]);
            profileBytes = profileBytes + size;

            if (size > 0) {
                System.out.println("  " + rel + " — " + CleanerContext.formatSize(size));
            }
        }

        ctx.totalSizeBytes = ctx.totalSizeBytes + profileBytes;
        System.out.println();
        System.out.println(profile.name + ": " + CleanerContext.formatSize(profileBytes) + " total across " + toAnalyze.length + " projects");
    }

    private static long measureArtifacts(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command") && !profile.cleanDir.isEmpty()) {
            return CleanerContext.dirSizeBytes(dir + File.separator + profile.cleanDir);
        } else if (profile.profileType.equals("remove")) {
            long total = 0;
            for (int i = 0; i < profile.targets.length; i++) {
                total = total + CleanerContext.dirSizeBytes(dir + File.separator + profile.targets[i]);
            }
            for (int i = 0; i < profile.optionalTargets.length; i++) {
                total = total + CleanerContext.dirSizeBytes(dir + File.separator + profile.optionalTargets[i]);
            }
            return total;
        }
        return 0;
    }

    /** Generic disk usage scan on any path. */
    static void runDiskUsage(CleanerContext ctx, int depth) {
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

        // Collect sizes
        var names = new String[entries.length];
        var sizes = new long[entries.length];
        long total = 0;

        for (int i = 0; i < entries.length; i++) {
            if (ctx.cancelled) break;
            names[i] = entries[i].getName();
            sizes[i] = entries[i].isDirectory()
                    ? CleanerContext.dirSizeBytes(entries[i].getAbsolutePath())
                    : entries[i].length();
            total = total + sizes[i];
        }

        // Sort descending by size (simple bubble sort)
        for (int i = 0; i < names.length - 1; i++) {
            for (int j = 0; j < names.length - i - 1; j++) {
                if (sizes[j] < sizes[j + 1]) {
                    long tmpSize = sizes[j]; sizes[j] = sizes[j + 1]; sizes[j + 1] = tmpSize;
                    String tmpName = names[j]; names[j] = names[j + 1]; names[j + 1] = tmpName;
                }
            }
        }

        for (int i = 0; i < names.length; i++) {
            if (sizes[i] > 0) {
                double pct = total > 0 ? ((double) sizes[i] / total) * 100.0 : 0.0;
                System.out.printf("  %10s  %5.1f%%  %s%n", CleanerContext.formatSize(sizes[i]), pct, names[i]);
            }
        }

        System.out.println();
        System.out.println("Total: " + CleanerContext.formatSize(total));
    }
}
