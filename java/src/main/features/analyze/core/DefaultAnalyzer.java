package main.features.analyze.core;

import main.features.analyze.api.Analyzer;
import main.features.config.api.CleanProfile;
import main.features.config.api.ConfigProvider;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.saf.ConfigFactory;

import java.io.IOException;
import java.nio.file.Path;

/** Default implementation of the Analyzer interface. */
public class DefaultAnalyzer implements Analyzer {

    public void run(DefaultProjectScanner ctx, String[] profileKeys, ConfigProvider config, boolean benchmark) {
        int count = profileKeys.length;
        if (benchmark) {
            System.out.println("disk-cleaner analyze -Benchmark - Build time analysis");
        } else {
            System.out.println("disk-cleaner analyze - Disk space report");
        }
        System.out.println("Path: " + ctx.searchPath);

        for (int i = 0; i < count; i++) {
            if (ctx.isCancelled()) break;
            var profile = ConfigFactory.loadProfile(profileKeys[i], config);
            if (benchmark) {
                benchmarkProfile(ctx, profile, i + 1, count);
            } else {
                analyzeProfile(ctx, profile, i + 1, count);
            }
        }

        System.out.println();
        System.out.println("==================================================");
        if (benchmark) {
            System.out.println("Benchmark complete!");
        } else {
            System.out.println("Analysis complete!");
            System.out.println("  Total artifact space: " + ConfigFactory.formatSize(ctx.totalSizeBytes));
        }
    }

    private void analyzeProfile(DefaultProjectScanner ctx, CleanProfile profile, int index, int count) {
        System.out.println();
        System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");

        var found = ctx.scanForProjects(profile.allMarkers());
        var filtered = ctx.filterProjects(found);
        var toAnalyze = filtered[0];
        ctx.totalProjects += toAnalyze.length;

        long profileBytes = 0;
        for (int i = 0; i < toAnalyze.length; i++) {
            if (ctx.isCancelled()) break;
            var rel = ctx.relativePath(toAnalyze[i]);
            long size = measureArtifacts(profile, toAnalyze[i]);
            profileBytes += size;
            if (size > 0) {
                System.out.println("  " + rel + " — " + ConfigFactory.formatSize(size));
            }
        }

        ctx.totalSizeBytes += profileBytes;
        System.out.println();
        System.out.println(profile.name + ": " + ConfigFactory.formatSize(profileBytes)
                + " total across " + toAnalyze.length + " projects");
    }

    private void benchmarkProfile(DefaultProjectScanner ctx, CleanProfile profile, int index, int count) {
        if (profile.buildCommand.isEmpty()) {
            System.out.println();
            System.out.println("--- " + profile.name + " [" + index + "/" + count + "] ---");
            System.out.println("No build_command configured for " + profile.name + ", skipping benchmark.");
            return;
        }

        System.out.println();
        System.out.println("--- " + profile.name + " Benchmark [" + index + "/" + count + "] ---");
        System.out.println("Build command: " + profile.buildCommand);

        var found = ctx.scanForProjects(profile.allMarkers());
        var filtered = ctx.filterProjects(found);
        var toBenchmark = filtered[0];
        ctx.totalProjects += toBenchmark.length;

        System.out.println();
        System.out.println("Benchmarking " + toBenchmark.length + " " + profile.name + " projects...");
        System.out.println();

        long[] durations = new long[toBenchmark.length];
        boolean[] successes = new boolean[toBenchmark.length];
        int successCount = 0;

        for (int i = 0; i < toBenchmark.length; i++) {
            if (ctx.isCancelled()) break;
            var rel = ctx.relativePath(toBenchmark[i]);
            long start = System.currentTimeMillis();
            boolean ok = runBuildCommand(profile.buildCommand, toBenchmark[i]);
            long elapsed = System.currentTimeMillis() - start;
            durations[i] = elapsed;
            successes[i] = ok;
            if (ok) successCount++;

            var status = ok ? "" : " FAILED";
            System.out.println("  [" + (i + 1) + "/" + toBenchmark.length + "] " + rel
                    + " — " + formatDuration(elapsed) + status);
        }

        if (successCount > 0) {
            long min = Long.MAX_VALUE, max = 0, sum = 0;
            for (int i = 0; i < durations.length; i++) {
                if (successes[i]) {
                    if (durations[i] < min) min = durations[i];
                    if (durations[i] > max) max = durations[i];
                    sum += durations[i];
                }
            }
            System.out.println();
            System.out.println(profile.name + " benchmark: " + successCount + " projects");
            System.out.println("    Fastest:  " + formatDuration(min));
            System.out.println("    Slowest:  " + formatDuration(max));
            System.out.println("    Average:  " + formatDuration(sum / successCount));
            System.out.println("    Total:    " + formatDuration(sum));
        }
    }

    private long measureArtifacts(CleanProfile profile, String dir) {
        if (profile.profileType.equals("command") && !profile.cleanDir.isEmpty()) {
            return ConfigFactory.dirSizeBytes(Path.of(dir, profile.cleanDir).toString());
        } else if (profile.profileType.equals("remove")) {
            long total = 0;
            for (int i = 0; i < profile.targets.length; i++)
                total += ConfigFactory.dirSizeBytes(Path.of(dir, profile.targets[i]).toString());
            for (int i = 0; i < profile.optionalTargets.length; i++)
                total += ConfigFactory.dirSizeBytes(Path.of(dir, profile.optionalTargets[i]).toString());
            return total;
        }
        return 0;
    }

    private boolean runBuildCommand(String cmd, String workingDir) {
        var parts = cmd.split(" ");
        try {
            var proc = new ProcessBuilder(parts)
                    .directory(new File(workingDir))
                    .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                    .redirectError(ProcessBuilder.Redirect.DISCARD)
                    .start();
            return proc.waitFor() == 0;
        } catch (IOException e) { return false; }
        catch (InterruptedException e) { return false; }
    }

    private String formatDuration(long ms) {
        if (ms >= 60000) return (ms / 60000) + "m " + String.format(java.util.Locale.US, "%.1f", (ms % 60000) / 1000.0) + "s";
        if (ms >= 1000) return String.format(java.util.Locale.US, "%.2f", ms / 1000.0) + "s";
        return ms + "ms";
    }
}
