package features;

import config.TomlConfig;
import model.CleanProfile;
import model.CleanerContext;

import java.io.File;
import java.io.IOException;

/** Clean feature: removes build artifacts from detected projects. */
class Clean {

    static void run(CleanerContext ctx, String[] profileKeys, TomlConfig toml, boolean dryRun, boolean parallel) {
        int count = profileKeys.length;

        System.out.println("disk-cleaner clean - Build artifact cleaner");
        System.out.println("Path: " + ctx.searchPath);
        System.out.println("Profiles: " + String.join(", ", profileKeys));

        for (int i = 0; i < count; i++) {
            if (ctx.cancelled) break;
            var profile = CleanProfile.fromToml(profileKeys[i], toml);
            cleanProfile(ctx, profile, i + 1, count, dryRun);
        }

        printSummary(ctx, profileKeys);
    }

    private static void cleanProfile(CleanerContext ctx, CleanProfile profile, int index, int count, boolean dryRun) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");
        System.out.println("Scanning for " + profile.name + " projects in: " + ctx.searchPath);

        var found = ctx.scanForProjects(profile);
        var filtered = ctx.filterProjects(found);
        var toClean = filtered[0];
        var skipped = filtered[1];

        System.out.println();
        System.out.println("Found " + found.length + " " + profile.name + " projects");
        System.out.println("  To clean: " + toClean.length);
        System.out.println("  Skipped:  " + skipped.length);

        ctx.totalProjects = ctx.totalProjects + found.length;
        ctx.totalCleaned = ctx.totalCleaned + toClean.length;
        ctx.totalSkipped = ctx.totalSkipped + skipped.length;

        if (toClean.length == 0 || ctx.cancelled) return;

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

        long profileBytes = 0;
        for (int i = 0; i < toClean.length; i++) {
            if (ctx.cancelled) break;
            var rel = ctx.relativePath(toClean[i]);
            long freed = cleanProject(profile, toClean[i]);
            profileBytes = profileBytes + freed;

            System.out.println("[" + (i + 1) + "/" + toClean.length + "] Cleaning: " + rel
                    + " | freed: " + CleanerContext.formatSize(freed)
                    + " | total: " + CleanerContext.formatSize(profileBytes));
        }

        ctx.totalSizeBytes = ctx.totalSizeBytes + profileBytes;
        System.out.println();
        System.out.println(profile.name + " complete: " + CleanerContext.formatSize(profileBytes) + " freed");
    }

    private static long cleanProject(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command")) {
            return cleanCommandProject(profile, dir);
        } else if (profile.profileType.equals("remove")) {
            return cleanRemoveProject(profile, dir);
        }
        return 0;
    }

    private static long cleanCommandProject(CleanProfile profile, String dir) {
        long sizeBefore = 0;
        if (!profile.cleanDir.isEmpty()) {
            var cd = dir + File.separator + profile.cleanDir;
            sizeBefore = CleanerContext.dirSizeBytes(cd);
        }

        var cmd = resolveCommand(profile, dir);
        try {
            var proc = Runtime.getRuntime().exec(cmd.split(" "), null, new File(dir));
            proc.waitFor();
        } catch (IOException e) {
            System.err.println("  Error running: " + cmd + " — " + e.getMessage());
        } catch (InterruptedException e) {
            // cancelled
        }

        return sizeBefore;
    }

    private static long cleanRemoveProject(CleanProfile profile, String dir) {
        long freed = 0;

        // Targets + optional targets
        for (int i = 0; i < profile.targets.length; i++) {
            freed = freed + removeDir(dir + File.separator + profile.targets[i]);
        }
        for (int i = 0; i < profile.optionalTargets.length; i++) {
            freed = freed + removeDir(dir + File.separator + profile.optionalTargets[i]);
        }

        // Recursive targets
        for (int i = 0; i < profile.recursiveTargets.length; i++) {
            freed = freed + removeRecursive(new File(dir), profile.recursiveTargets[i]);
        }

        return freed;
    }

    private static long removeDir(String path) {
        var file = new File(path);
        if (!file.exists()) return 0;
        long size = CleanerContext.dirSizeBytes(path);
        deleteRecursive(file);
        return size;
    }

    private static long removeRecursive(File root, String targetName) {
        long freed = 0;
        var files = root.listFiles();
        if (files == null) return 0;

        for (int i = 0; i < files.length; i++) {
            if (files[i].isDirectory()) {
                if (files[i].getName().equals(targetName)) {
                    freed = freed + CleanerContext.dirSizeBytes(files[i].getAbsolutePath());
                    deleteRecursive(files[i]);
                } else {
                    freed = freed + removeRecursive(files[i], targetName);
                }
            }
        }
        return freed;
    }

    private static void deleteRecursive(File file) {
        if (file.isDirectory()) {
            var children = file.listFiles();
            if (children != null) {
                for (int i = 0; i < children.length; i++) {
                    deleteRecursive(children[i]);
                }
            }
        }
        file.delete();
    }

    private static String resolveCommand(CleanProfile profile, String dir) {
        if (!profile.wrapper.isEmpty()) {
            var wrapperFile = new File(dir + File.separator + profile.wrapper);
            if (wrapperFile.exists()) {
                return profile.wrapper + " clean";
            }
        }
        return profile.command;
    }

    private static void printDryRunDetails(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command")) {
            var cmd = resolveCommand(profile, dir);
            System.out.println("    would run: " + cmd);
            if (!profile.cleanDir.isEmpty()) {
                var cd = dir + File.separator + profile.cleanDir;
                var cdFile = new File(cd);
                if (cdFile.exists()) {
                    System.out.println("    " + profile.cleanDir + "/ size: " + CleanerContext.formatSize(CleanerContext.dirSizeBytes(cd)));
                }
            }
        } else if (profile.profileType.equals("remove")) {
            for (int i = 0; i < profile.targets.length; i++) {
                var tp = dir + File.separator + profile.targets[i];
                if (new File(tp).exists()) {
                    System.out.println("    remove: " + profile.targets[i] + " (" + CleanerContext.formatSize(CleanerContext.dirSizeBytes(tp)) + ")");
                }
            }
            for (int i = 0; i < profile.optionalTargets.length; i++) {
                var tp = dir + File.separator + profile.optionalTargets[i];
                if (new File(tp).exists()) {
                    System.out.println("    remove: " + profile.optionalTargets[i] + " (" + CleanerContext.formatSize(CleanerContext.dirSizeBytes(tp)) + ")");
                }
            }
        }
    }

    private static void printSummary(CleanerContext ctx, String[] profileKeys) {
        System.out.println();
        System.out.println("==================================================");
        System.out.println("Cleaning complete!");
        System.out.println("  Profiles run:       " + profileKeys.length + " (" + String.join(", ", profileKeys) + ")");
        System.out.println("  Projects found:     " + ctx.totalProjects);
        System.out.println("  Projects cleaned:   " + ctx.totalCleaned);
        System.out.println("  Projects skipped:   " + ctx.totalSkipped);
        System.out.println("  Total space freed:  " + CleanerContext.formatSize(ctx.totalSizeBytes));
    }
}
