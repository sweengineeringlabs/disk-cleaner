package tests.monitor;

import main.features.config.saf.ConfigFactory;
import main.features.monitor.saf.MonitorFactory;
import main.features.monitor.api.HistoryEntry;
import main.features.monitor.core.DefaultHistoryStore;

import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

/** Integration tests for monitor feature. */
public class MonitorIntTest {

    static int passed = 0;
    static int failed = 0;

    public static void main(String[] args) {
        System.out.println("=== Monitor Integration Tests ===");
        System.out.println();

        testHistoryRecordAndLoad();
        testHistoryAppendsEntries();
        testHistoryKeepsMax100();
        testHistoryLoadEmptyReturnsEmpty();
        testHistoryLoadCorruptReturnsEmpty();
        testHistoryAutoTimestamps();
        testMonitorRunHistoryOnlyDoesNotPanic();
        testMonitorRunFullDoesNotPanic();

        System.out.println();
        System.out.println("Results: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }

    static String createTempDir() { var d = System.getProperty("java.io.tmpdir") + File.separator + "dc-mon-" + System.nanoTime(); new File(d).mkdirs(); return d; }
    static void deleteRecursive(File f) { if (f.isDirectory()) { var ch = f.listFiles(); if (ch != null) for (var c : ch) deleteRecursive(c); } f.delete(); }
    static void check(String name, boolean cond) { if (cond) { passed++; System.out.println("  PASS  " + name); } else { failed++; System.out.println("  FAIL  " + name); } }

    static void testHistoryRecordAndLoad() {
        var dir = createTempDir();
        try {
            var store = new DefaultHistoryStore(dir);
            var entry = new HistoryEntry();
            entry.timestamp = "2026-03-24T10:00:00+00:00";
            entry.command = "clean";
            entry.profiles = "rust";
            entry.projects = 5;
            entry.sizeBytes = 1048576;
            entry.sizeFormatted = "1.00 MiB";
            entry.path = "/projects";
            store.record(entry);
            var entries = store.load();
            check("test_history_record_and_load",
                    entries.length == 1 && entries[0].command.equals("clean") && entries[0].projects == 5);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testHistoryAppendsEntries() {
        var dir = createTempDir();
        try {
            var store = new DefaultHistoryStore(dir);
            for (int i = 0; i < 5; i++) {
                var e = new HistoryEntry();
                e.timestamp = ""; e.command = "clean"; e.profiles = "rust";
                e.projects = i; e.sizeBytes = i * 1024; e.sizeFormatted = i + " B"; e.path = "/p";
                store.record(e);
            }
            var entries = store.load();
            check("test_history_appends_entries", entries.length == 5 && entries[4].projects == 4);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testHistoryKeepsMax100() {
        var dir = createTempDir();
        try {
            var store = new DefaultHistoryStore(dir);
            for (int i = 0; i < 110; i++) {
                var e = new HistoryEntry();
                e.timestamp = ""; e.command = "clean"; e.profiles = "rust";
                e.projects = i; e.sizeBytes = 0; e.sizeFormatted = "0 B"; e.path = "/p";
                store.record(e);
            }
            var entries = store.load();
            check("test_history_keeps_max_100", entries.length == 100 && entries[0].projects == 10);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testHistoryLoadEmptyReturnsEmpty() {
        var dir = createTempDir();
        try {
            var store = new DefaultHistoryStore(dir);
            check("test_history_load_empty_returns_empty", store.load().length == 0);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testHistoryLoadCorruptReturnsEmpty() {
        var dir = createTempDir();
        try {
            var w = new FileWriter(dir + File.separator + "history.json");
            w.write("not valid json{{{");
            w.close();
            var store = new DefaultHistoryStore(dir);
            check("test_history_load_corrupt_returns_empty", store.load().length == 0);
        } catch (IOException e) { check("test_history_load_corrupt_returns_empty", false); }
        finally { deleteRecursive(new File(dir)); }
    }

    static void testHistoryAutoTimestamps() {
        var dir = createTempDir();
        try {
            var store = new DefaultHistoryStore(dir);
            var e = new HistoryEntry();
            e.timestamp = ""; e.command = "analyze"; e.profiles = "node";
            e.projects = 3; e.sizeBytes = 2048; e.sizeFormatted = "2.00 KiB"; e.path = "/data";
            store.record(e);
            var entries = store.load();
            check("test_history_auto_timestamps",
                    entries.length == 1 && !entries[0].timestamp.isEmpty());
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testMonitorRunHistoryOnlyDoesNotPanic() {
        var dir = createTempDir();
        try {
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            MonitorFactory.run(scanner, dir, true);
            check("test_monitor_run_history_only_does_not_panic", true);
        } finally { deleteRecursive(new File(dir)); }
    }

    static void testMonitorRunFullDoesNotPanic() {
        var dir = createTempDir();
        try {
            var scanner = ConfigFactory.createScanner(dir, new String[0], new String[0], false, false);
            MonitorFactory.run(scanner, dir, false);
            check("test_monitor_run_full_does_not_panic", true);
        } finally { deleteRecursive(new File(dir)); }
    }
}
