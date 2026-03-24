package model;

import java.io.File;

/**
 * Shared state for disk-cleaner operations.
 */
class CleanerContext {
    String searchPath;
    String[] excludePatterns;
    String[] includePatterns;
    boolean cleanAll;
    boolean jsonOutput;
    volatile boolean cancelled;

    // Grand totals
    int totalProjects;
    int totalCleaned;
    int totalSkipped;
    long totalSizeBytes;

    CleanerContext(String searchPath, String[] exclude, String[] include, boolean cleanAll, boolean jsonOutput) {
        this.searchPath = searchPath;
        this.excludePatterns = exclude;
        this.includePatterns = include;
        this.cleanAll = cleanAll;
        this.jsonOutput = jsonOutput;
        this.cancelled = false;
        this.totalProjects = 0;
        this.totalCleaned = 0;
        this.totalSkipped = 0;
        this.totalSizeBytes = 0;
    }

    /** Convert absolute path to relative path from search root. */
    String relativePath(String fullPath) {
        if (searchPath != null && fullPath.startsWith(searchPath)) {
            var rel = fullPath.substring(searchPath.length());
            if (rel.startsWith("/") || rel.startsWith("\\")) {
                rel = rel.substring(1);
            }
            return rel;
        }
        return fullPath;
    }

    /** Check if a project should be processed based on filters. */
    boolean shouldClean(String projectPath) {
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

    /** Recursively scan for projects matching a profile's marker files. */
    String[] scanForProjects(CleanProfile profile) {
        var found = new String[0];
        var markers = profile.allMarkers();

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

    /** Split found directories into to-process and skipped. */
    String[][] filterProjects(String[] found) {
        var toProcess = new String[0];
        var skipped = new String[0];

        for (int i = 0; i < found.length; i++) {
            if (shouldClean(found[i])) {
                toProcess = appendStr(toProcess, found[i]);
            } else {
                skipped = appendStr(skipped, found[i]);
            }
        }

        return new String[][] { toProcess, skipped };
    }

    /** Calculate total size of a directory in bytes. */
    static long dirSizeBytes(String path) {
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
            if (files[i].isFile()) {
                total = total + files[i].length();
            } else if (files[i].isDirectory()) {
                total = total + dirSizeRecursive(files[i]);
            }
        }
        return total;
    }

    /** Format bytes into human-readable size string. */
    static String formatSize(long bytes) {
        long GIB = 1024L * 1024L * 1024L;
        long MIB = 1024L * 1024L;
        long KIB = 1024L;

        if (bytes >= GIB) {
            return String.format("%.2f GiB", (double) bytes / GIB);
        } else if (bytes >= MIB) {
            return String.format("%.2f MiB", (double) bytes / MIB);
        } else if (bytes >= KIB) {
            return String.format("%.2f KiB", (double) bytes / KIB);
        }
        return bytes + " B";
    }

    // Array helpers (no ArrayList — justc compatible)

    static boolean contains(String[] arr, String item) {
        for (int i = 0; i < arr.length; i++) {
            if (arr[i].equals(item)) return true;
        }
        return false;
    }

    static String[] appendStr(String[] arr, String item) {
        var result = new String[arr.length + 1];
        for (int i = 0; i < arr.length; i++) result[i] = arr[i];
        result[arr.length] = item;
        return result;
    }
}
