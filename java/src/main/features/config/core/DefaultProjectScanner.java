package main.features.config.core;

import main.features.config.api.CleanProfile;
import main.features.config.api.ProjectScanner;

import java.io.File;

/** Shared state for disk-cleaner operations. Implements scanning and filtering. */
public class DefaultProjectScanner implements ProjectScanner {

    public String searchPath;
    public String[] excludePatterns;
    public String[] includePatterns;
    public boolean cleanAll;
    public boolean jsonOutput;
    public volatile boolean cancelled;

    public int totalProjects;
    public int totalCleaned;
    public int totalSkipped;
    public long totalSizeBytes;

    public DefaultProjectScanner(String searchPath, String[] exclude, String[] include,
                          boolean cleanAll, boolean jsonOutput) {
        this.searchPath = searchPath;
        this.excludePatterns = exclude;
        this.includePatterns = include;
        this.cleanAll = cleanAll;
        this.jsonOutput = jsonOutput;
        this.cancelled = false;
    }

    public String relativePath(String fullPath) {
        if (searchPath != null && fullPath.startsWith(searchPath)) {
            var rel = fullPath.substring(searchPath.length());
            if (rel.startsWith("/") || rel.startsWith("\\")) rel = rel.substring(1);
            return rel;
        }
        return fullPath;
    }

    public boolean isCancelled() {
        return cancelled;
    }

    boolean shouldInclude(String projectPath) {
        if (cleanAll) return true;
        var rel = relativePath(projectPath);

        for (int i = 0; i < excludePatterns.length; i++) {
            if (rel.contains(excludePatterns[i])) return false;
        }

        if (includePatterns.length > 0) {
            for (int i = 0; i < includePatterns.length; i++) {
                if (rel.contains(includePatterns[i])) return true;
            }
            return false;
        }

        return true;
    }

    public String[] scanForProjects(String[] markers) {
        var found = new String[0];
        for (int m = 0; m < markers.length; m++) {
            if (cancelled) break;
            found = scanDir(new File(searchPath), markers[m], found);
        }
        return found;
    }

    private String[] scanDir(File dir, String marker, String[] found) {
        if (cancelled || dir == null || !dir.isDirectory()) return found;
        var files = dir.listFiles();
        if (files == null) return found;

        for (int i = 0; i < files.length; i++) {
            if (cancelled) break;
            if (files[i].isFile() && files[i].getName().equals(marker)) {
                var parent = files[i].getParent();
                if (!contains(found, parent)) {
                    found = appendStr(found, parent);
                }
            } else if (files[i].isDirectory()) {
                found = scanDir(files[i], marker, found);
            }
        }
        return found;
    }

    public String[][] filterProjects(String[] found) {
        var toProcess = new String[0];
        var skipped = new String[0];
        for (int i = 0; i < found.length; i++) {
            if (shouldInclude(found[i])) {
                toProcess = appendStr(toProcess, found[i]);
            } else {
                skipped = appendStr(skipped, found[i]);
            }
        }
        return new String[][] { toProcess, skipped };
    }

    // ─── Static utilities ───────────────────────────────────────────────────

    public static long dirSizeBytesStatic(String path) {
        var file = new File(path);
        if (!file.exists()) return 0;
        return dirSizeRecursive(file);
    }

    private static long dirSizeRecursive(File dir) {
        long total = 0;
        if (dir.isFile()) return dir.length();
        var files = dir.listFiles();
        if (files == null) return 0;
        for (int i = 0; i < files.length; i++) {
            if (files[i].isFile()) total += files[i].length();
            else if (files[i].isDirectory()) total += dirSizeRecursive(files[i]);
        }
        return total;
    }

    public static String formatSizeStatic(long bytes) {
        long GIB = 1024L * 1024L * 1024L;
        long MIB = 1024L * 1024L;
        long KIB = 1024L;
        if (bytes >= GIB) return String.format(java.util.Locale.US, "%.2f GiB", (double) bytes / GIB);
        if (bytes >= MIB) return String.format(java.util.Locale.US, "%.2f MiB", (double) bytes / MIB);
        if (bytes >= KIB) return String.format(java.util.Locale.US, "%.2f KiB", (double) bytes / KIB);
        return bytes + " B";
    }

    // ─── Array helpers ──────────────────────────────────────────────────────

    public static boolean contains(String[] arr, String item) {
        for (int i = 0; i < arr.length; i++) {
            if (arr[i].equals(item)) return true;
        }
        return false;
    }

    public static String[] appendStr(String[] arr, String item) {
        var result = new String[arr.length + 1];
        for (int i = 0; i < arr.length; i++) result[i] = arr[i];
        result[arr.length] = item;
        return result;
    }
}
