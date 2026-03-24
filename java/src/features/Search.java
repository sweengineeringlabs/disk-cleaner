package features;

import config.TomlConfig;
import model.CleanProfile;
import model.CleanerContext;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.io.IOException;

/** Search feature: finds and reports projects with optional text search. */
class Search {

    static void run(CleanerContext ctx, String[] profileKeys, TomlConfig toml, String text) {
        int count = profileKeys.length;

        System.out.println("disk-cleaner search - Project finder");
        System.out.println("Path: " + ctx.searchPath);
        System.out.println("Profiles: " + String.join(", ", profileKeys));

        for (int i = 0; i < count; i++) {
            if (ctx.cancelled) break;
            var profile = CleanProfile.fromToml(profileKeys[i], toml);
            searchProfile(ctx, profile, i + 1, count, text);
        }

        System.out.println();
        System.out.println("==================================================");
        System.out.println("Search complete! Found " + ctx.totalProjects + " projects across " + count + " profiles.");
    }

    private static void searchProfile(CleanerContext ctx, CleanProfile profile, int index, int count, String text) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");

        var found = ctx.scanForProjects(profile);
        var filtered = ctx.filterProjects(found);
        var toProcess = filtered[0];

        ctx.totalProjects = ctx.totalProjects + toProcess.length;

        System.out.println("Found " + found.length + " " + profile.name + " projects (" + toProcess.length + " filtered)");

        for (int i = 0; i < toProcess.length; i++) {
            if (ctx.cancelled) break;
            var rel = ctx.relativePath(toProcess[i]);
            long size = estimateArtifactSize(profile, toProcess[i]);
            System.out.println("  " + rel + " (artifacts: " + CleanerContext.formatSize(size) + ")");

            if (text != null && !text.isEmpty()) {
                searchTextInProject(profile, toProcess[i], text);
            }
        }
    }

    private static long estimateArtifactSize(CleanProfile profile, String dir) {
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

    private static void searchTextInProject(CleanProfile profile, String dir, String pattern) {
        searchInDir(new File(dir), dir, profile, pattern);
    }

    private static void searchInDir(File current, String rootDir, CleanProfile profile, String pattern) {
        var files = current.listFiles();
        if (files == null) return;

        for (int i = 0; i < files.length; i++) {
            if (files[i].isDirectory()) {
                // Skip excluded directories
                boolean excluded = false;
                for (int j = 0; j < profile.searchExclude.length; j++) {
                    if (files[i].getName().equals(profile.searchExclude[j])) {
                        excluded = true;
                        break;
                    }
                }
                if (!excluded) {
                    searchInDir(files[i], rootDir, profile, pattern);
                }
            } else if (files[i].isFile()) {
                // Check extension
                var name = files[i].getName();
                int dot = name.lastIndexOf('.');
                if (dot < 0) continue;
                var ext = name.substring(dot);
                boolean matched = false;
                for (int j = 0; j < profile.sourceExtensions.length; j++) {
                    if (ext.equals(profile.sourceExtensions[j])) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;

                searchInFile(files[i], rootDir, pattern);
            }
        }
    }

    private static void searchInFile(File file, String rootDir, String pattern) {
        try {
            var reader = new BufferedReader(new FileReader(file));
            String line;
            int lineNum = 0;
            while ((line = reader.readLine()) != null) {
                lineNum++;
                if (line.contains(pattern)) {
                    var relPath = file.getAbsolutePath().substring(rootDir.length() + 1);
                    System.out.println("    " + relPath + ":" + lineNum + ": " + line.trim());
                }
            }
            reader.close();
        } catch (IOException e) {
            // skip unreadable files
        }
    }
}
