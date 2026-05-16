package tests.clean;

import main.features.config.saf.ConfigFactory;
import main.features.clean.saf.CleanFactory;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;

/**
 * End-to-end tests for clean feature.
 * Tests multi-profile cleaning and alt-marker detection.
 */
public class CleanE2eTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Clean E2E Tests ===");
        System.out.println();

        testE2eMultiProfileCleansAll();
        testE2eScanDoesNotInterfereWithClean();
        testE2eDetectsViaAltMarker();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() {
        var dir = System.getProperty("java.io.tmpdir") + File.separator + "dc-e2e-" + System.nanoTime();
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

    static String writeMultiConfig(String dir) {
        writeFile(dir, "profiles.toml",
            "[settings]\ndefault_profiles = [\"node\"]\n\n"
            + "[profiles.node]\nname = \"Node.js\"\nmarker = \"package-lock.json\"\n"
            + "alt_markers = [\"yarn.lock\"]\ntype = \"remove\"\ntargets = [\"node_modules\"]\n"
            + "optional_targets = [\".next\"]\n\n"
            + "[profiles.python]\nname = \"Python\"\nmarker = \"pyproject.toml\"\n"
            + "type = \"remove\"\ntargets = [\".venv\"]\nrecursive_targets = [\"__pycache__\"]\n");
        return dir + File.separator + "profiles.toml";
    }

    static void check(String name, boolean condition) {
        if (condition) { passed++; System.out.println("  PASS  " + name); }
        else { failed++; System.out.println("  FAIL  " + name); }
    }

    static void testE2eMultiProfileCleansAll() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "web/package-lock.json", 0);
            writeBinary(dir, "web/node_modules/react.js", 1024);
            writeBinary(dir, "web/.next/build.js", 512);
            writeFile(dir, "ml/pyproject.toml", "[project]\nname = \"ml\"");
            writeBinary(dir, "ml/.venv/lib/pkg.py", 2048);
            writeBinary(dir, "ml/src/__pycache__/main.pyc", 256);

            var config = ConfigFactory.loadConfig(writeMultiConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node", "python"}, config, false, false);

            check("test_e2e_multi_profile_cleans_all",
                    !new File(dir, "web/node_modules").exists()
                    && !new File(dir, "web/.next").exists()
                    && !new File(dir, "ml/.venv").exists()
                    && !new File(dir, "ml/src/__pycache__").exists()
                    && new File(dir, "web/package-lock.json").exists()
                    && new File(dir, "ml/pyproject.toml").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testE2eScanDoesNotInterfereWithClean() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "app/package-lock.json", 0);
            writeBinary(dir, "app/node_modules/lib.bin", 512);

            var config = ConfigFactory.loadConfig(writeMultiConfig(dir));
            var profile = ConfigFactory.loadProfile("node", config);

            // Scan first
            var scanCtx = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            var found = scanCtx.scanForProjects(profile.allMarkers());
            boolean foundOne = found.length == 1;
            boolean stillExists = new File(dir, "app/node_modules").exists();

            // Then clean
            var cleanCtx = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(cleanCtx, new String[]{"node"}, config, false, false);

            check("test_e2e_scan_does_not_interfere_with_clean",
                    foundOne && stillExists && !new File(dir, "app/node_modules").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testE2eDetectsViaAltMarker() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "app/yarn.lock", 0);
            writeBinary(dir, "app/node_modules/dep.js", 1024);

            var config = ConfigFactory.loadConfig(writeMultiConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CleanFactory.run(scanner, new String[]{"node"}, config, false, false);

            check("test_e2e_detects_via_alt_marker",
                    !new File(dir, "app/node_modules").exists() && scanner.totalCleaned == 1);
        } finally { deleteRecursive(new File(dir)); }
    }
}
