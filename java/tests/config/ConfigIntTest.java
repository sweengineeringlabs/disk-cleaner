package tests.config;

import main.features.config.saf.ConfigFactory;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;

/**
 * Integration tests for config feature.
 * Tests TOML parsing, profile loading, project scanning, filtering, size utilities.
 */
public class ConfigIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Config Integration Tests ===");
        System.out.println();

        testLoadConfigReadsAllProfiles();
        testGetValueReturnsUnquotedString();
        testGetValueMissingReturnsEmpty();
        testGetArrayParsesInlineArray();
        testGetArrayMissingReturnsEmpty();
        testLoadConfigPreservesHashInsideQuotes();
        testLoadProfileCommandTypeFields();
        testLoadProfileRemoveTypeFields();
        testAllMarkersIncludesPrimaryAndAlternates();
        testScanForProjectsFindsByMarker();
        testScanForProjectsReturnsEmptyForNoMatch();
        testFilterProjectsAppliesExclude();
        testFilterProjectsAppliesInclude();
        testFilterProjectsCleanAllIgnoresExclude();
        testFormatSizeBytes();
        testFormatSizeKib();
        testFormatSizeMib();
        testFormatSizeGib();
        testDirSizeBytesNonexistentReturnsZero();
        testDirSizeBytesMeasuresContent();
        testRelativePathStripsSearchRoot();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    static String createTempDir() {
        var dir = System.getProperty("java.io.tmpdir") + File.separator
                + "dc-test-" + System.nanoTime();
        new File(dir).mkdirs();
        return dir;
    }

    static void writeFile(String root, String relative, String content) {
        var f = new File(root + File.separator + relative);
        f.getParentFile().mkdirs();
        try { var w = new FileWriter(f); w.write(content); w.close(); }
        catch (IOException e) { throw new RuntimeException(e); }
    }

    static void writeBinary(String root, String relative, int size) {
        var f = new File(root + File.separator + relative);
        f.getParentFile().mkdirs();
        try { var out = new FileOutputStream(f); out.write(new byte[size]); out.close(); }
        catch (IOException e) { throw new RuntimeException(e); }
    }

    static void deleteRecursive(File f) {
        if (f.isDirectory()) {
            var children = f.listFiles();
            if (children != null) for (var c : children) deleteRecursive(c);
        }
        f.delete();
    }

    static String writeTestConfig(String dir) {
        var path = dir + File.separator + "profiles.toml";
        writeFile(dir, "profiles.toml",
            "[settings]\ndefault_profiles = [\"rust\"]\n\n"
            + "[profiles.rust]\nname = \"Rust (Cargo)\"\nmarker = \"Cargo.lock\"\n"
            + "type = \"command\"\ncommand = \"cargo clean\"\nclean_dir = \"target\"\n"
            + "source_extensions = [\".rs\", \".toml\"]\nsearch_exclude = [\"target\"]\n\n"
            + "[profiles.node]\nname = \"Node.js\"\nmarker = \"package-lock.json\"\n"
            + "alt_markers = [\"yarn.lock\", \"pnpm-lock.yaml\"]\ntype = \"remove\"\n"
            + "targets = [\"node_modules\"]\noptional_targets = [\".next\", \"dist\"]\n"
            + "source_extensions = [\".js\", \".ts\"]\nsearch_exclude = [\"node_modules\"]\n");
        return path;
    }

    static void check(String name, boolean condition) {
        if (condition) { passed++; System.out.println("  PASS  " + name); }
        else { failed++; System.out.println("  FAIL  " + name); }
    }

    // ─── Tests ──────────────────────────────────────────────────────────────

    static void testLoadConfigReadsAllProfiles() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            check("test_load_config_reads_all_profiles", config.profileKeys().length == 2);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testGetValueReturnsUnquotedString() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            check("test_get_value_returns_unquoted_string",
                    config.getValue("profiles.rust.name").equals("Rust (Cargo)")
                    && config.getValue("profiles.rust.marker").equals("Cargo.lock"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testGetValueMissingReturnsEmpty() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            check("test_get_value_missing_returns_empty",
                    config.getValue("profiles.nonexistent.name").isEmpty());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testGetArrayParsesInlineArray() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var arr = config.getArray("profiles.node.alt_markers");
            check("test_get_array_parses_inline_array",
                    arr.length == 2 && arr[0].equals("yarn.lock") && arr[1].equals("pnpm-lock.yaml"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testGetArrayMissingReturnsEmpty() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            check("test_get_array_missing_returns_empty",
                    config.getArray("profiles.rust.nonexistent").length == 0);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testLoadConfigPreservesHashInsideQuotes() {
        var dir = createTempDir();
        try {
            writeFile(dir, "test.toml",
                    "[profiles.test]\nname = \"Test\"\nmarker = \"test.lock\"\n"
                    + "type = \"command\"\npattern = 'Removed #(\\d+) files'\n");
            var config = ConfigFactory.loadConfig(dir + File.separator + "test.toml");
            check("test_load_config_preserves_hash_inside_quotes",
                    config.getValue("profiles.test.pattern").equals("Removed #(\\d+) files"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testLoadProfileCommandTypeFields() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var p = ConfigFactory.loadProfile("rust", config);
            check("test_load_profile_command_type_fields",
                    p.key.equals("rust") && p.name.equals("Rust (Cargo)")
                    && p.profileType.equals("command") && p.command.equals("cargo clean"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testLoadProfileRemoveTypeFields() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var p = ConfigFactory.loadProfile("node", config);
            check("test_load_profile_remove_type_fields",
                    p.profileType.equals("remove") && p.targets[0].equals("node_modules"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testAllMarkersIncludesPrimaryAndAlternates() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var p = ConfigFactory.loadProfile("node", config);
            var markers = p.allMarkers();
            check("test_all_markers_includes_primary_and_alternates",
                    markers.length == 3 && markers[0].equals("package-lock.json")
                    && markers[1].equals("yarn.lock"));
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testScanForProjectsFindsByMarker() {
        var dir = createTempDir();
        try {
            writeFile(dir, "app-web/package-lock.json", "");
            writeFile(dir, "app-api/package-lock.json", "");
            writeFile(dir, "lib/package-lock.json", "");
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var profile = ConfigFactory.loadProfile("node", config);
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            var found = scanner.scanForProjects(profile.allMarkers());
            check("test_scan_for_projects_finds_by_marker", found.length == 3);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testScanForProjectsReturnsEmptyForNoMatch() {
        var dir = createTempDir();
        try {
            writeFile(dir, "something.txt", "hello");
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var profile = ConfigFactory.loadProfile("rust", config);
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            var found = scanner.scanForProjects(profile.allMarkers());
            check("test_scan_for_projects_returns_empty_for_no_match", found.length == 0);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testFilterProjectsAppliesExclude() {
        var dir = createTempDir();
        try {
            writeFile(dir, "app-web/package-lock.json", "");
            writeFile(dir, "app-api/package-lock.json", "");
            writeFile(dir, "lib-shared/package-lock.json", "");
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var profile = ConfigFactory.loadProfile("node", config);
            var scanner = ConfigFactory.createScanner(dir, new String[]{"lib-shared"}, new String[0], false, false);
            var found = scanner.scanForProjects(profile.allMarkers());
            var filtered = scanner.filterProjects(found);
            check("test_filter_projects_applies_exclude",
                    filtered[0].length == 2 && filtered[1].length == 1);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testFilterProjectsAppliesInclude() {
        var dir = createTempDir();
        try {
            writeFile(dir, "app-web/package-lock.json", "");
            writeFile(dir, "app-api/package-lock.json", "");
            writeFile(dir, "lib-shared/package-lock.json", "");
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var profile = ConfigFactory.loadProfile("node", config);
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[]{"app-web"}, false, false);
            var found = scanner.scanForProjects(profile.allMarkers());
            var filtered = scanner.filterProjects(found);
            check("test_filter_projects_applies_include",
                    filtered[0].length == 1 && filtered[1].length == 2);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testFilterProjectsCleanAllIgnoresExclude() {
        var dir = createTempDir();
        try {
            writeFile(dir, "app-web/package-lock.json", "");
            writeFile(dir, "lib-shared/package-lock.json", "");
            var config = ConfigFactory.loadConfig(writeTestConfig(dir));
            var profile = ConfigFactory.loadProfile("node", config);
            var scanner = ConfigFactory.createScanner(dir, new String[]{"lib-shared"}, new String[0], true, false);
            var found = scanner.scanForProjects(profile.allMarkers());
            var filtered = scanner.filterProjects(found);
            check("test_filter_projects_clean_all_ignores_exclude",
                    filtered[0].length == 2 && filtered[1].length == 0);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testFormatSizeBytes() {
        check("test_format_size_bytes",
                ConfigFactory.formatSize(0).equals("0 B") && ConfigFactory.formatSize(512).equals("512 B"));
    }

    static void testFormatSizeKib() {
        check("test_format_size_kib", ConfigFactory.formatSize(1024).equals("1.00 KiB"));
    }

    static void testFormatSizeMib() {
        check("test_format_size_mib", ConfigFactory.formatSize(1024 * 1024).equals("1.00 MiB"));
    }

    static void testFormatSizeGib() {
        check("test_format_size_gib", ConfigFactory.formatSize(1024L * 1024L * 1024L).equals("1.00 GiB"));
    }

    static void testDirSizeBytesNonexistentReturnsZero() {
        check("test_dir_size_bytes_nonexistent_returns_zero",
                ConfigFactory.dirSizeBytes("/nonexistent/path/12345") == 0);
    }

    static void testDirSizeBytesMeasuresContent() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "data.bin", 4096);
            check("test_dir_size_bytes_measures_content", ConfigFactory.dirSizeBytes(dir) == 4096);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testRelativePathStripsSearchRoot() {
        var dir = createTempDir();
        try {
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            var rel = scanner.relativePath(dir + File.separator + "app-web");
            check("test_relative_path_strips_search_root", rel.equals("app-web"));
        } finally { deleteRecursive(new File(dir)); }
    }
}
