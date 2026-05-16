package main.features.monitor.api;

import main.features.config.core.DefaultProjectScanner;

/** Monitors build processes and displays run history. */
public interface ProcessMonitor {
    void run(DefaultProjectScanner ctx, String configDir, boolean historyOnly);
}
