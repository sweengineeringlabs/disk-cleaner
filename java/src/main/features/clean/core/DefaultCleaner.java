package main.features.clean.core;

import main.features.clean.api.Cleaner;
import main.features.config.api.CleanProfile;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.core.ProfileLoader;
import main.features.config.saf.ConfigFactory;

import java.io.File;
import java.io.IOException;
import java.nio.file.Path;

/** Default implementation of the Cleaner interface. */
public class DefaultCleaner implements Cleaner {

    public void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config,
                    boolean dryRun, boolean parallel) {
        int count = profileKeys.length;
        System.out.println("disk-cleaner clean - Build artifact cleaner");
        System.out.println("Path: " + ctx.searchPath);
        System.out.println("Profiles: " + String.join(", ", profileKeys));

        for (int i = 0; i < count; i++) {
            if (ctx.isCancelled()) break;
            var profile = ConfigFactory.loadProfile(profileKeys[i], config);
            cleanProfile(ctx, profile, i + 1, count, dryRun, parallel);
        }

        printSummary(ctx, profileKeys);
    }

    private void cleanProfile(DefaultProjectScanner ctx, CleanProfile profile,
                               int index, int count, boolean dryRun, boolean parallel) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");
        System.out.println("Scanning for " + profile.name + " projects in: " + ctx.searchPath);

        var found = ctx.scanForProjects(profile.allMarkers());
        var filtered = ctx.filterProjects(found);
        var toClean = filtered[0];
        var skipped = filtered[1];

        System.out.println();
        System.out.println("Found " + found.length + " " + profile.name + " projects");
        System.out.println("  To clean: " + toClean.length);
        System.out.println("  Skipped:  " + skipped.length);

        ctx.totalProjects += found.length;
        ctx.totalCleaned += toClean.length;
        ctx.totalSkipped += skipped.length;

        if (toClean.length == 0 || ctx.isCancelled()) return;

        if (dryRun) {
            System.out.println();
            System.out.println("[DRY RUN] Would clean:");
            for (int i = 0; i < toClean.length; i++) {
                var rel = ctx.relativePath(toClean[i]);
                System.out.println("  - " + rel);
                printDryRunDetails(profile, toClean[i]);
            }
            return;
        }

        System.out.println();
        System.out.println("Cleaning " + profile.name + " projects...");
        System.out.println();

        boolean useParallel = parallel && profile.profileType.equals("command") && toClean.length > 1;

        long profileBytes;
        if (useParallel) {
            profileBytes = cleanProjectsParallel(ctx, profile, toClean);
        } else {
            profileBytes = cleanProjectsSequential(ctx, profile, toClean);
        }

        ctx.totalSizeBytes += profileBytes;
        System.out.println();
        System.out.println(profile.name + " complete: " + ConfigFactory.formatSize(profileBytes) + " freed");
    }

    private long cleanProjectsSequential(DefaultProjectScanner ctx, CleanProfile profile, String[] toClean) {
        long profileBytes = 0;
        for (int i = 0; i < toClean.length; i++) {
            if (ctx.isCancelled()) break;
            var rel = ctx.relativePath(toClean[i]);
            long freed = cleanProject(profile, toClean[i]);
            profileBytes += freed;
            System.out.println("[" + (i + 1) + "/" + toClean.length + "] Cleaning: " + rel
                    + " | freed: " + ConfigFactory.formatSize(freed)
                    + " | total: " + ConfigFactory.formatSize(profileBytes));
        }
        return profileBytes;
    }

    private long cleanProjectsParallel(DefaultProjectScanner ctx, CleanProfile profile, String[] toClean) {
        // Pre-measure sizes
        var preSizes = new long[toClean.length];
        for (int i = 0; i < toClean.length; i++) {
            if (!profile.cleanDir.isEmpty()) {
                preSizes[i] = ConfigFactory.dirSizeBytes(Path.of(toClean[i], profile.cleanDir).toString());
            }
        }

        // Launch threads
        var threads = new Thread[toClean.length];
        var results = new boolean[toClean.length];
        for (int i = 0; i < toClean.length; i++) {
            final int idx = i;
            final String dir = toClean[i];
            threads[i] = new Thread(() -> {
                if (!ctx.isCancelled()) {
                    var cmd = resolveCommand(profile, dir);
                    try {
                        var proc = Runtime.getRuntime().exec(cmd.split(" "), null, new File(dir));
                        proc.waitFor();
                        results[idx] = true;
                    } catch (Exception e) {
                        results[idx] = false;
                    }
                }
            });
            threads[i].start();
        }

        // Wait for all
        for (int i = 0; i < threads.length; i++) {
            try { threads[i].join(); } catch (InterruptedException e) { /* cancelled */ }
        }

        // Report results sequentially
        long profileBytes = 0;
        for (int i = 0; i < toClean.length; i++) {
            var rel = ctx.relativePath(toClean[i]);
            profileBytes += preSizes[i];
            System.out.println("[" + (i + 1) + "/" + toClean.length + "] Cleaned: " + rel
                    + " | freed: " + ConfigFactory.formatSize(preSizes[i]));
        }
        return profileBytes;
    }

    public long cleanProject(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command")) return cleanCommandProject(profile, dir);
        if (profile.profileType.equals("remove")) return cleanRemoveProject(profile, dir);
        return 0;
    }

    private long cleanCommandProject(CleanProfile profile, String dir) {
        long sizeBefore = 0;
        if (!profile.cleanDir.isEmpty()) {
            sizeBefore = ConfigFactory.dirSizeBytes(Path.of(dir, profile.cleanDir).toString());
        }

        var cmd = resolveCommand(profile, dir);
        try {
            var proc = Runtime.getRuntime().exec(cmd.split(" "), null, new File(dir));
            proc.waitFor();
        } catch (IOException e) {
            System.err.println("  Error running: " + cmd + " — " + e.getMessage());
        } catch (InterruptedException e) { /* cancelled */ }

        return sizeBefore;
    }

    private long cleanRemoveProject(CleanProfile profile, String dir) {
        long freed = 0;
        for (int i = 0; i < profile.targets.length; i++) {
            freed += removeDir(Path.of(dir, profile.targets[i]).toString());
        }
        for (int i = 0; i < profile.optionalTargets.length; i++) {
            freed += removeDir(Path.of(dir, profile.optionalTargets[i]).toString());
        }
        for (int i = 0; i < profile.recursiveTargets.length; i++) {
            freed += removeRecursive(new File(dir), profile.recursiveTargets[i]);
        }
        return freed;
    }

    private long removeDir(String path) {
        var file = new File(path);
        if (!file.exists()) return 0;
        long size = ConfigFactory.dirSizeBytes(path);
        deleteRecursive(file);
        return size;
    }

    private long removeRecursive(File root, String targetName) {
        long freed = 0;
        var files = root.listFiles();
        if (files == null) return 0;
        for (int i = 0; i < files.length; i++) {
            if (files[i].isDirectory()) {
                if (files[i].getName().equals(targetName)) {
                    freed += ConfigFactory.dirSizeBytes(files[i].getAbsolutePath());
                    deleteRecursive(files[i]);
                } else {
                    freed += removeRecursive(files[i], targetName);
                }
            }
        }
        return freed;
    }

    private void deleteRecursive(File file) {
        if (file.isDirectory()) {
            var children = file.listFiles();
            if (children != null) {
                for (int i = 0; i < children.length; i++) deleteRecursive(children[i]);
            }
        }
        file.delete();
    }

    private String resolveCommand(CleanProfile profile, String dir) {
        if (!profile.wrapper.isEmpty()) {
            if (Path.of(dir, profile.wrapper).toFile().exists()) {
                return profile.wrapper + " clean";
            }
        }
        return profile.command;
    }

    private void printDryRunDetails(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command")) {
            System.out.println("    would run: " + resolveCommand(profile, dir));
            if (!profile.cleanDir.isEmpty()) {
                var cd = Path.of(dir, profile.cleanDir).toString();
                if (new File(cd).exists()) {
                    System.out.println("    " + profile.cleanDir + "/ size: "
                            + ConfigFactory.formatSize(ConfigFactory.dirSizeBytes(cd)));
                }
            }
        } else if (profile.profileType.equals("remove")) {
            for (int i = 0; i < profile.targets.length; i++) {
                var tp = Path.of(dir, profile.targets[i]).toString();
                if (new File(tp).exists()) {
                    System.out.println("    remove: " + profile.targets[i] + " ("
                            + ConfigFactory.formatSize(ConfigFactory.dirSizeBytes(tp)) + ")");
                }
            }
        }
    }

    private void printSummary(DefaultProjectScanner ctx, String[] profileKeys) {
        System.out.println();
        System.out.println("==================================================");
        System.out.println("Cleaning complete!");
        System.out.println("  Profiles run:       " + profileKeys.length + " (" + String.join(", ", profileKeys) + ")");
        System.out.println("  Projects found:     " + ctx.totalProjects);
        System.out.println("  Projects cleaned:   " + ctx.totalCleaned);
        System.out.println("  Projects skipped:   " + ctx.totalSkipped);
        System.out.println("  Total space freed:  " + ConfigFactory.formatSize(ctx.totalSizeBytes));
    }
}
