package tests.compact_wsl;

import main.features.config.saf.ConfigFactory;
import main.features.compact_wsl.saf.CompactWslFactory;

import java.io.File;

/** Integration tests for compact-wsl feature. */
public class CompactWslIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Compact-WSL Integration Tests ===");
        System.out.println();

        testCompactWslDryRunDoesNotPanic();
        testCompactWslNonAdminExitsGracefully();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() { var d = System.getProperty("java.io.tmpdir") + File.separator + "dc-wsl-" + System.nanoTime(); new File(d).mkdirs(); return d; }
    static void deleteRecursive(File f) { if (f.isDirectory()) { var ch = f.listFiles(); if (ch != null) for (var c : ch) deleteRecursive(c); } f.delete(); }
    static void check(String name, boolean cond) { if (cond) { passed++; System.out.println("  PASS  " + name); } else { failed++; System.out.println("  FAIL  " + name); } }

    static void testCompactWslDryRunDoesNotPanic() {
        var dir = createTempDir();
        try {
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CompactWslFactory.run(scanner, true);
            check("test_compact_wsl_dry_run_does_not_panic", true);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testCompactWslNonAdminExitsGracefully() {
        var dir = createTempDir();
        try {
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            CompactWslFactory.run(scanner, false);
            check("test_compact_wsl_non_admin_exits_gracefully", true);
        } finally { deleteRecursive(new File(dir)); }
    }
}
