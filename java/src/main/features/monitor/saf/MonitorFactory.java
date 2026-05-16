package main.features.monitor.saf;

import main.features.monitor.core.DefaultHistoryStore;
import main.features.monitor.core.DefaultProcessMonitor;
import main.features.monitor.api.HistoryEntry;
import main.features.config.core.DefaultProjectScanner;

/** Factory entry point for the monitor feature. */
public class MonitorFactory {

    public static void run(DefaultProjectScanner ctx, String configDir, boolean historyOnly) {
        var monitor = new DefaultProcessMonitor();
        monitor.run(ctx, configDir, historyOnly);
    }

    /** Record a history entry (called by clean/analyze after completion). */
    public static void saveHistory(String configDir, String command, String profiles,
                            int projects, long sizeBytes, String sizeFormatted, String path) {
        var store = new DefaultHistoryStore(configDir);
        var entry = new HistoryEntry();
        entry.timestamp = "";
        entry.command = command;
        entry.profiles = profiles;
        entry.projects = projects;
        entry.sizeBytes = sizeBytes;
        entry.sizeFormatted = sizeFormatted;
        entry.path = path;
        store.record(entry);
    }
}
