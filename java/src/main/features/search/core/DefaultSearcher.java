package main.features.search.core;

import main.features.search.api.Searcher;
import main.features.config.api.CleanProfile;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.saf.ConfigFactory;

import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.nio.file.Path;

/** Default implementation of the Searcher interface. */
public class DefaultSearcher implements Searcher {

    public void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, String text) {
        int count = profileKeys.length;
        System.out.println("disk-cleaner search - Project finder");
        System.out.println("Path: " + ctx.searchPath);
        System.out.println("Profiles: " + String.join(", ", profileKeys));

        for (int i = 0; i < count; i++) {
            if (ctx.isCancelled()) break;
            var profile = ConfigFactory.loadProfile(profileKeys[i], config);
            searchProfile(ctx, profile, i + 1, count, text);
        }

        System.out.println();
        System.out.println("==================================================");
        System.out.println("Search complete! Found " + ctx.totalProjects + " projects across " + count + " profiles.");
    }

    private void searchProfile(DefaultProjectScanner ctx, CleanProfile profile,
                                int index, int count, String text) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");

        var found = ctx.scanForProjects(profile.allMarkers());
        var filtered = ctx.filterProjects(found);
        var toProcess = filtered[0];

        ctx.totalProjects += toProcess.length;

        System.out.println("Found " + found.length + " " + profile.name + " projects (" + toProcess.length + " filtered)");

        for (int i = 0; i < toProcess.length; i++) {
            if (ctx.isCancelled()) break;
            var rel = ctx.relativePath(toProcess[i]);
            long size = estimateArtifactSize(profile, toProcess[i]);
            System.out.println("  " + rel + " (artifacts: " + ConfigFactory.formatSize(size) + ")");

            if (text != null && !text.isEmpty()) {
                searchTextInProject(profile, new File(toProcess[i]), toProcess[i], text);
            }
        }
    }

    private long estimateArtifactSize(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command") && !profile.cleanDir.isEmpty()) {
            return ConfigFactory.dirSizeBytes(Path.of(dir, profile.cleanDir).toString());
        } else if (profile.profileType.equals("remove")) {
            long total = 0;
            for (int i = 0; i < profile.targets.length; i++)
                total += ConfigFactory.dirSizeBytes(Path.of(dir, profile.targets[i]).toString());
            for (int i = 0; i < profile.optionalTargets.length; i++)
                total += ConfigFactory.dirSizeBytes(Path.of(dir, profile.optionalTargets[i]).toString());
            return total;
        }
        return 0;
    }

    private void searchTextInProject(CleanProfile profile, File current, String rootDir, String pattern) {
        var files = current.listFiles();
        if (files == null) return;

        for (int i = 0; i < files.length; i++) {
            if (files[i].isDirectory()) {
                boolean excluded = false;
                for (int j = 0; j < profile.searchExclude.length; j++) {
                    if (files[i].getName().equals(profile.searchExclude[j])) { excluded = true; break; }
                }
                if (!excluded) searchTextInProject(profile, files[i], rootDir, pattern);
            } else if (files[i].isFile()) {
                var name = files[i].getName();
                int dot = name.lastIndexOf('.');
                if (dot < 0) continue;
                var ext = name.substring(dot);
                boolean matched = false;
                for (int j = 0; j < profile.sourceExtensions.length; j++) {
                    if (ext.equals(profile.sourceExtensions[j])) { matched = true; break; }
                }
                if (!matched) continue;

                try {
                    var reader = new BufferedReader(new FileReader(files[i]));
                    String line;
                    int lineNum = 0;
                    while ((line = reader.readLine()) != null) {
                        lineNum++;
                        if (line.contains(pattern)) {
                            var relPath = files[i].getAbsolutePath().substring(rootDir.length() + 1);
                            System.out.println("    " + relPath + ":" + lineNum + ": " + line.trim());
                        }
                    }
                    reader.close();
                } catch (IOException e) { /* skip unreadable */ }
            }
        }
    }
}
