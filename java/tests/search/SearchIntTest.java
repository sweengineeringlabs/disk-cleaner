package tests.search;

import main.features.config.saf.ConfigFactory;
import main.features.search.saf.SearchFactory;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

/** Integration tests for search feature. */
public class SearchIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Search Integration Tests ===");
        System.out.println();

        testSearchFindsProjects();
        testSearchRespectsExclude();
        testSearchDoesNotModifyFiles();
        testSearchWithTextDoesNotCrash();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() { var d = System.getProperty("java.io.tmpdir") + File.separator + "dc-search-" + System.nanoTime(); new File(d).mkdirs(); return d; }
    static void writeFile(String root, String rel, String content) { var f = new File(root + File.separator + rel); f.getParentFile().mkdirs(); try { var w = new FileWriter(f); w.write(content); w.close(); } catch (IOException e) { throw new RuntimeException(e); } }
    static void deleteRecursive(File f) { if (f.isDirectory()) { var ch = f.listFiles(); if (ch != null) for (var c : ch) deleteRecursive(c); } f.delete(); }
    static void check(String name, boolean cond) { if (cond) { passed++; System.out.println("  PASS  " + name); } else { failed++; System.out.println("  FAIL  " + name); } }

    static String writeConfig(String dir) {
        writeFile(dir, "profiles.toml", "[settings]\ndefault_profiles = [\"rust\"]\n\n[profiles.rust]\nname = \"Rust\"\nmarker = \"Cargo.lock\"\ntype = \"command\"\ncommand = \"cargo clean\"\nclean_dir = \"target\"\nsource_extensions = [\".rs\"]\nsearch_exclude = [\"target\"]\n");
        return dir + File.separator + "profiles.toml";
    }

    static void testSearchFindsProjects() {
        var dir = createTempDir();
        try {
            writeFile(dir, "proj-a/Cargo.lock", "");
            writeFile(dir, "proj-b/Cargo.lock", "");
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            SearchFactory.run(scanner, new String[]{"rust"}, config, null);
            check("test_search_finds_projects", scanner.totalProjects == 2);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testSearchRespectsExclude() {
        var dir = createTempDir();
        try {
            writeFile(dir, "proj-a/Cargo.lock", "");
            writeFile(dir, "proj-b/Cargo.lock", "");
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[]{"proj-b"}, new String[0], false, false);
            SearchFactory.run(scanner, new String[]{"rust"}, config, null);
            check("test_search_respects_exclude", scanner.totalProjects == 1);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testSearchDoesNotModifyFiles() {
        var dir = createTempDir();
        try {
            writeFile(dir, "app/Cargo.lock", "");
            writeFile(dir, "app/src/main.rs", "fn main() {}");
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            SearchFactory.run(scanner, new String[]{"rust"}, config, "main");
            check("test_search_does_not_modify_files",
                    new File(dir, "app/src/main.rs").exists() && new File(dir, "app/Cargo.lock").exists());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testSearchWithTextDoesNotCrash() {
        var dir = createTempDir();
        try {
            writeFile(dir, "proj/Cargo.lock", "");
            writeFile(dir, "proj/src/main.rs", "fn main() {\n    unsafe { }\n}");
            var config = ConfigFactory.loadConfig(writeConfig(dir));
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            SearchFactory.run(scanner, new String[]{"rust"}, config, "unsafe");
            check("test_search_with_text_does_not_crash", true);
        } finally { deleteRecursive(new File(dir)); }
    }
}
