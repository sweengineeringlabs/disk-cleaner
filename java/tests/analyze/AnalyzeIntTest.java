package tests.analyze;

import main.features.config.saf.ConfigFactory;
import main.features.analyze.saf.AnalyzeFactory;

import java.io.File;
import java.io.FileOutputStream;
import java.io.FileWriter;
import java.io.IOException;

/** Integration tests for analyze feature. */
public class AnalyzeIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Analyze Integration Tests ===");
        System.out.println();

        testAnalyzeMeasuresArtifactSizes();
        testAnalyzeDoesNotModifyFilesystem();
        testAnalyzeDiskUsageScansDirectory();
        testAnalyzeBenchmarkEmptyCommandDoesNotPanic();
        testAnalyzeEmptyDirectoryReportsZero();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() { var d = System.getProperty("java.io.tmpdir") + File.separator + "dc-analyze-" + System.nanoTime(); new File(d).mkdirs(); return d; }
    static void writeFile(String root, String rel, String content) { var f = new File(root + File.separator + rel); f.getParentFile().mkdirs(); try { var w = new FileWriter(f); w.write(content); w.close(); } catch (IOException e) { throw new RuntimeException(e); } }
    static void writeBinary(String root, String rel, int size) { var f = new File(root + File.separator + rel); f.getParentFile().mkdirs(); try { var o = new FileOutputStream(f); o.write(new byte[size]); o.close(); } catch (IOException e) { throw new RuntimeException(e); } }
    static void deleteRecursive(File f) { if (f.isDirectory()) { var ch = f.listFiles(); if (ch != null) for (var c : ch) deleteRecursive(c); } f.delete(); }
    static void check(String name, boolean cond) { if (cond) { passed++; System.out.println("  PASS  " + name); } else { failed++; System.out.println("  FAIL  " + name); } }

    static String writeConfig(String dir) {
        writeFile(dir, "profiles.toml", "[settings]\ndefault_profiles = [\"node\"]\n\n[profiles.node]\nname = \"Node.js\"\nmarker = \"package-lock.json\"\ntype = \"remove\"\ntargets = [\"node_modules\"]\noptional_targets = [\".next\"]\n");
        return dir + File.separator + "profiles.toml";
    }

    static void testAnalyzeMeasuresArtifactSizes() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "app/package-lock.json", 0);
            writeBinary(dir, "app/node_modules/dep.bin", 4096);
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            AnalyzeFactory.run(scanner, new String[]{"node"}, config, false);
            check("test_analyze_measures_artifact_sizes", scanner.totalSizeBytes >= 4096);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testAnalyzeDoesNotModifyFilesystem() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "app/package-lock.json", 0);
            writeBinary(dir, "app/node_modules/dep.bin", 1024);
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            AnalyzeFactory.run(scanner, new String[]{"node"}, config, false);
            check("test_analyze_does_not_modify_filesystem", new File(dir, "app/node_modules/dep.bin").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testAnalyzeDiskUsageScansDirectory() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "docs/readme.txt", 512);
            writeBinary(dir, "data/big.bin", 8192);
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            AnalyzeFactory.runDiskUsage(scanner, 2);
            check("test_analyze_disk_usage_scans_directory", true);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testAnalyzeBenchmarkEmptyCommandDoesNotPanic() {
        var dir = createTempDir();
        try {
            writeBinary(dir, "app/package-lock.json", 0);
            writeBinary(dir, "app/node_modules/dep.bin", 1024);
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            AnalyzeFactory.run(scanner, new String[]{"node"}, config, true);
            check("test_analyze_benchmark_empty_command_does_not_panic",
                    new File(dir, "app/node_modules/dep.bin").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testAnalyzeEmptyDirectoryReportsZero() {
        var dir = createTempDir();
        try {
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            AnalyzeFactory.run(scanner, new String[]{"node"}, config, false);
            check("test_analyze_empty_directory_reports_zero", scanner.totalSizeBytes == 0);
        } finally { deleteRecursive(new File(dir)); }
    }
}
