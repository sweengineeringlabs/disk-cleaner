package tests.clean;

import main.features.config.saf.ConfigFactory;
import main.features.clean.saf.CleanFactory;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;

/**
 * Integration tests for clean feature.
 * Tests remove-type cleaning, dry-run, filtering, parallel mode.
 */
public class CleanIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Clean Integration Tests ===");
        System.out.println();

        testCleanRemoveTypeDeletesTargets();
        testCleanRemoveTypeSkipsMissingOptional();
        testCleanDryRunDoesNotRemove();
        testCleanPipelineRespectsExclude();
        testCleanPipelineScansAndCleans();
        testCleanParallelModeCleans();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() {
        var dir = System.getProperty("java.io.tmpdir") + File.separator + "dc-clean-" + System.nanoTime();
        new File(dir).mkdirs();
        return dir;
    }

    static void writeFile(String root, String relative, String content) {
        var f = new File(root + File.separator + relative);
        f.getParentFile().mkdirs();
        try { var w = new FileWriter(f); w.write(content); w.close(); } catch (IOException e) { throw new RuntimeException(e); }
    }

    static void writeBinary(String root, String relative, int size) {
        var f = new File(root + File.separator + relative);
        f.getParentFile().mkdirs();
        try { var out = new FileOutputStream(f); out.write(new byte[size]); out.close(); } catch (IOException e) { throw new RuntimeException(e); }
    }

    static void deleteRecursive(File f) {
        if (f.isDirectory()) { var ch = f.listFiles(); if (ch != null) for (var c : ch) deleteRecursive(c); }
        f.delete();
    }

    static String writeNodeConfig(String dir) {
        writeFile(dir, "profiles.toml",
            "[settings]\ndefault_profiles = [\"node\"]\n\n"
            + "[profiles.node]\nname = \"Node.js\"\nmarker = \"package-lock.json\"\n"
            + "alt_markers = [\"yarn.lock\"]\ntype = \"remove\"\n"
            + "targets = [\"node_modules\"]\noptional_targets = [\".next\"]\n");
        return dir + File.separator + "profiles.toml";
    }

    static void createNodeProject(String root, String name, int nmSize, int nextSize) {
        writeFile(root, name + "/package-lock.json", "");
        writeBinary(root, name + "/node_modules/dep.bin", nmSize);
        if (nextSize > 0) writeBinary(root, name + "/.next/cache.bin", nextSize);
    }

    static void check(String name, boolean condition) {
        if (condition) { passed++; System.out.println("  PASS  " + name); }
        else { failed++; System.out.println("  FAIL  " + name); }
    }

    static void testCleanRemoveTypeDeletesTargets() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "test-app", 2048, 1024);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, false);
            check("test_clean_remove_type_deletes_targets",
                    !new File(dir, "test-app/node_modules").exists()
                    && !new File(dir, "test-app/.next").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCleanRemoveTypeSkipsMissingOptional() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "test-app", 2048, 0);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, false);
            check("test_clean_remove_type_skips_missing_optional",
                    !new File(dir, "test-app/node_modules").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCleanDryRunDoesNotRemove() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "test-app", 2048, 1024);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, true, false);
            check("test_clean_dry_run_does_not_remove",
                    new File(dir, "test-app/node_modules").exists()
                    && new File(dir, "test-app/.next").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCleanPipelineRespectsExclude() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "app-web", 1024, 0);
            createNodeProject(dir, "app-api", 1024, 0);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[]{"app-api"}, new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, false);
            check("test_clean_pipeline_respects_exclude",
                    !new File(dir, "app-web/node_modules").exists()
                    && new File(dir, "app-api/node_modules").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCleanPipelineScansAndCleans() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "proj-a", 1024, 0);
            createNodeProject(dir, "proj-b", 1024, 0);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, false);
            check("test_clean_pipeline_scans_and_cleans",
                    !new File(dir, "proj-a/node_modules").exists()
                    && !new File(dir, "proj-b/node_modules").exists()
                    && scanner.totalCleaned >= 2);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCleanParallelModeCleans() {
        var dir = createTempDir();
        try {
            createNodeProject(dir, "proj-a", 1024, 0);
            createNodeProject(dir, "proj-b", 1024, 0);
            createNodeProject(dir, "proj-c", 1024, 0);
            var config = ConfigFactory.loadConfig(writeNodeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, true);
            check("test_clean_parallel_mode_cleans",
                    !new File(dir, "proj-a/node_modules").exists()
                    && !new File(dir, "proj-b/node_modules").exists()
                    && !new File(dir, "proj-c/node_modules").exists());
        } finally { deleteRecursive(new File(dir)); }
    }
}
