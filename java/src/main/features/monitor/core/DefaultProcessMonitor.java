package main.features.monitor.core;

import main.features.monitor.api.BuildProcessInfo;
import main.features.monitor.api.ProcessMonitor;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.saf.ConfigFactory;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.IOException;
import java.lang.management.ManagementFactory;

/** Default implementation — uses tasklist on Windows for process scanning. */
public class DefaultProcessMonitor implements ProcessMonitor {

    private static final String[] BUILD_PROCESS_NAMES = {
        "cargo", "rustc", "rustup", "clippy-driver", "rust-analyzer",
        "node", "npm", "npx", "yarn", "pnpm", "bun", "deno", "tsc", "esbuild", "vite",
        "java", "javac", "mvn", "gradle", "gradlew", "kotlin",
        "python", "python3", "pip", "pip3", "pytest", "mypy", "ruff",
        "cc", "gcc", "g++", "clang", "clang++", "make", "cmake", "ninja",
        "dotnet", "msbuild", "go", "zig"
    };

    private static final long HIGH_MEMORY_THRESHOLD = 512L * 1024L * 1024L;

    public void run(DefaultProjectScanner ctx, String configDir, boolean historyOnly) {
        if (!historyOnly) {
            System.out.println("disk-cleaner monitor - Resource & history report");
            System.out.println();
            showSystemMemory();
            showBuildProcesses();
        }

        showRunHistory(configDir);

        System.out.println();
        System.out.println("==================================================");
        System.out.println("Monitor complete!");
    }

    private void showSystemMemory() {
        var osBean = (com.sun.management.OperatingSystemMXBean)
                ManagementFactory.getOperatingSystemMXBean();
        long total = osBean.getTotalMemorySize();
        long free  = osBean.getFreeMemorySize();
        long used  = total - free;
        double usedPct = total > 0 ? ((double) used / total) * 100.0 : 0;

        System.out.println("--- System Memory ---");
        System.out.println("  Total:  " + ConfigFactory.formatSize(total));
        System.out.println("  Used:   " + ConfigFactory.formatSize(used) + " (" + String.format(java.util.Locale.US, "%.1f", usedPct) + "%)");
        System.out.println("  Free:   " + ConfigFactory.formatSize(free));
        System.out.println();
    }

    private void showBuildProcesses() {
        System.out.println("--- Active Build Processes ---");

        var processes = new BuildProcessInfo[0];

        try {
            // Use tasklist on Windows, ps on Unix
            var os = System.getProperty("os.name").toLowerCase();
            Process proc;
            if (os.contains("win")) {
                proc = Runtime.getRuntime().exec(new String[]{"tasklist", "/FO", "CSV", "/NH"});
            } else {
                proc = Runtime.getRuntime().exec(new String[]{"ps", "-eo", "pid,comm,rss", "--no-headers"});
            }

            var reader = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) {
                if (os.contains("win")) {
                    processes = parseTasklistLine(line, processes);
                } else {
                    processes = parsePsLine(line, processes);
                }
            }
            reader.close();
            proc.waitFor();
        } catch (IOException e) {
            System.out.println("  Could not list processes: " + e.getMessage());
        } catch (InterruptedException e) { /* cancelled */ }

        if (processes.length == 0) {
            System.out.println("  No active build processes found.");
        } else {
            // Sort by memory descending
            for (int i = 0; i < processes.length - 1; i++) {
                for (int j = 0; j < processes.length - i - 1; j++) {
                    if (processes[j].memoryBytes < processes[j + 1].memoryBytes) {
                        var tmp = processes[j];
                        processes[j] = processes[j + 1];
                        processes[j + 1] = tmp;
                    }
                }
            }

            System.out.printf("  %-8s %-20s %14s%n", "PID", "Process", "Memory");
            System.out.println("  " + "-".repeat(46));

            long totalMem = 0;
            for (int i = 0; i < processes.length; i++) {
                totalMem += processes[i].memoryBytes;
                System.out.printf("  %-8d %-20s %14s%n",
                        processes[i].pid, processes[i].name,
                        ConfigFactory.formatSize(processes[i].memoryBytes));
            }

            System.out.println();
            System.out.println("  Total build process memory: " + ConfigFactory.formatSize(totalMem));

            // High resource alerts
            boolean hasAlert = false;
            for (int i = 0; i < processes.length; i++) {
                if (processes[i].memoryBytes >= HIGH_MEMORY_THRESHOLD) {
                    if (!hasAlert) {
                        System.out.println();
                        System.out.println("--- High Resource Alerts ---");
                        hasAlert = true;
                    }
                    System.out.println("  ! " + processes[i].name + " (PID " + processes[i].pid
                            + ") using " + ConfigFactory.formatSize(processes[i].memoryBytes) + " RAM");
                }
            }
        }

        System.out.println();
    }

    /** Parse Windows tasklist CSV line: "name.exe","PID","Session","Num","Mem Usage" */
    private BuildProcessInfo[] parseTasklistLine(String line, BuildProcessInfo[] acc) {
        var parts = line.split("\",\"");
        if (parts.length < 5) return acc;

        var name = parts[0].replace("\"", "").replace(".exe", "");
        boolean isBuild = false;
        for (int i = 0; i < BUILD_PROCESS_NAMES.length; i++) {
            if (name.equalsIgnoreCase(BUILD_PROCESS_NAMES[i])) { isBuild = true; break; }
        }
        if (!isBuild) return acc;

        var info = new BuildProcessInfo();
        info.name = name;
        try { info.pid = Integer.parseInt(parts[1].replace("\"", "").trim()); } catch (NumberFormatException e) {}

        // Memory field: "123,456 K"
        var memStr = parts[4].replace("\"", "").replace(",", "").replace(" K", "").trim();
        try { info.memoryBytes = Long.parseLong(memStr) * 1024; } catch (NumberFormatException e) {}

        var result = new BuildProcessInfo[acc.length + 1];
        for (int i = 0; i < acc.length; i++) result[i] = acc[i];
        result[acc.length] = info;
        return result;
    }

    /** Parse Unix ps line: "PID COMMAND RSS" */
    private BuildProcessInfo[] parsePsLine(String line, BuildProcessInfo[] acc) {
        var parts = line.trim().split("\\s+");
        if (parts.length < 3) return acc;

        var name = parts[1];
        // Strip path
        int slash = name.lastIndexOf('/');
        if (slash >= 0) name = name.substring(slash + 1);

        boolean isBuild = false;
        for (int i = 0; i < BUILD_PROCESS_NAMES.length; i++) {
            if (name.equals(BUILD_PROCESS_NAMES[i])) { isBuild = true; break; }
        }
        if (!isBuild) return acc;

        var info = new BuildProcessInfo();
        info.name = name;
        try { info.pid = Integer.parseInt(parts[0]); } catch (NumberFormatException e) {}
        try { info.memoryBytes = Long.parseLong(parts[2]) * 1024; } catch (NumberFormatException e) {}

        var result = new BuildProcessInfo[acc.length + 1];
        for (int i = 0; i < acc.length; i++) result[i] = acc[i];
        result[acc.length] = info;
        return result;
    }

    private void showRunHistory(String configDir) {
        var store = new DefaultHistoryStore(configDir);
        var entries = store.load();

        System.out.println("--- Run History ---");

        if (entries.length == 0) {
            System.out.println("  No history recorded yet. Run clean or analyze to build history.");
            return;
        }

        int start = entries.length > 10 ? entries.length - 10 : 0;

        System.out.printf("  %-22s %-10s %-12s %10s %16s%n", "Date", "Command", "Profiles", "Projects", "Size");
        System.out.println("  " + "-".repeat(75));

        for (int i = start; i < entries.length; i++) {
            var e = entries[i];
            var dateStr = e.timestamp.length() > 16 ? e.timestamp.substring(0, 16) : e.timestamp;
            System.out.printf("  %-22s %-10s %-12s %10d %16s%n",
                    dateStr, e.command, e.profiles, e.projects,
                    e.sizeFormatted != null ? e.sizeFormatted : "-");
        }
    }
}
