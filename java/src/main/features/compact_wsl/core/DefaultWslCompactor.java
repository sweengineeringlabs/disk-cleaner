package main.features.compact_wsl.core;

import main.features.compact_wsl.api.VhdxEntry;
import main.features.compact_wsl.api.WslCompactor;
import main.features.config.core.DefaultProjectScanner;
import main.features.config.saf.ConfigFactory;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.io.IOException;
import java.nio.file.Path;

/** Default implementation — VHDX discovery, admin check, diskpart compaction. */
public class DefaultWslCompactor implements WslCompactor {

    public void run(DefaultProjectScanner ctx, boolean dryRun) {
        System.out.println("disk-cleaner compact-wsl - WSL disk compaction");
        System.out.println();

        var os = System.getProperty("os.name").toLowerCase();
        if (!os.contains("win")) {
            System.err.println("Error: compact-wsl is only available on Windows.");
            return;
        }

        // Check WSL availability
        try {
            Runtime.getRuntime().exec(new String[]{"wsl", "--version"}).waitFor();
        } catch (Exception e) {
            System.err.println("Error: WSL is not installed.");
            return;
        }

        // Admin check
        if (!dryRun && !isAdmin()) {
            System.err.println("compact-wsl requires administrator privileges (for diskpart).");
            System.err.println("Re-run in an elevated terminal, or use --dry-run to preview.");
            return;
        }

        // Discover distros
        var distros = discoverDistros();
        if (distros.length == 0) {
            System.out.println("No WSL distributions found.");
            return;
        }

        // Find VHDX files
        var entries = findVhdxFiles(distros);
        if (entries.length == 0) {
            System.out.println("No WSL virtual disk files found.");
            return;
        }

        var modeLabel = dryRun ? " (dry run)" : "";
        System.out.println("--- WSL VHDX Compaction" + modeLabel + " ---");
        System.out.println("Found " + entries.length + " virtual disk(s):");
        System.out.println();

        // Query inner usage for each distro
        for (int i = 0; i < entries.length; i++) {
            long inner = queryInnerUsage(entries[i].distro);
            if (inner >= 0) {
                entries[i].innerUsedBytes = inner;
                entries[i].reclaimableBytes = Math.max(0, entries[i].sizeBytes - inner);
            }
        }

        long totalBefore = 0;
        for (int i = 0; i < entries.length; i++) {
            System.out.println("  " + entries[i].distro);
            System.out.println("    vhdx (outer): " + ConfigFactory.formatSize(entries[i].sizeBytes));
            if (entries[i].innerUsedBytes >= 0) {
                System.out.println("    inner used:   " + ConfigFactory.formatSize(entries[i].innerUsedBytes));
                System.out.println("    reclaimable:  " + ConfigFactory.formatSize(entries[i].reclaimableBytes));
            } else {
                System.out.println("    inner used:   (unavailable — WSL may be stopped)");
            }
            System.out.println("    " + entries[i].path);
            totalBefore += entries[i].sizeBytes;
        }
        System.out.println();
        System.out.println("Total vhdx size: " + ConfigFactory.formatSize(totalBefore));

        if (dryRun) {
            System.out.println();
            System.out.println("Would perform:");
            System.out.println("  1. wsl --shutdown (terminates all running WSL processes)");
            System.out.println("  2. diskpart compact on " + entries.length + " vhdx file(s)");
            System.out.println("  3. Report space reclaimed");
            System.out.println();
            System.out.println("Run without --dry-run to execute (requires Administrator).");
            return;
        }

        // Shutdown WSL
        System.out.println();
        System.out.println("Shutting down WSL...");
        try {
            var proc = Runtime.getRuntime().exec(new String[]{"wsl", "--shutdown"});
            proc.waitFor();
            Thread.sleep(2000);
            System.out.println("WSL shut down.");
        } catch (Exception e) {
            System.err.println("Failed to shut down WSL.");
            return;
        }

        // Compact each VHDX
        long totalReclaimed = 0;
        for (int i = 0; i < entries.length; i++) {
            if (ctx.isCancelled()) break;

            System.out.println();
            System.out.println("Compacting " + entries[i].distro + "...");
            System.out.println("  " + entries[i].path);

            long beforeSize = new File(entries[i].path).length();
            boolean success = compactVhdx(entries[i].path);

            if (success) {
                long afterSize = new File(entries[i].path).length();
                long reclaimed = beforeSize - afterSize;
                System.out.println("  Before:    " + ConfigFactory.formatSize(beforeSize));
                System.out.println("  After:     " + ConfigFactory.formatSize(afterSize));
                if (reclaimed > 0) {
                    System.out.println("  Reclaimed: " + ConfigFactory.formatSize(reclaimed));
                    totalReclaimed += reclaimed;
                } else {
                    System.out.println("  Reclaimed: 0 B (already compact)");
                }
            } else {
                System.err.println("  Failed to compact.");
            }
        }

        System.out.println();
        System.out.println("==================================================");
        if (totalReclaimed > 0) {
            System.out.println("Total reclaimed: " + ConfigFactory.formatSize(totalReclaimed));
        } else {
            System.out.println("No space reclaimed. Virtual disks were already compact.");
        }
    }

    private String[] discoverDistros() {
        try {
            var proc = Runtime.getRuntime().exec(new String[]{"wsl", "--list", "--quiet"});
            var reader = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            var distros = new String[0];
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim().replace("\0", "");
                if (!line.isEmpty()) {
                    var tmp = new String[distros.length + 1];
                    for (int i = 0; i < distros.length; i++) tmp[i] = distros[i];
                    tmp[distros.length] = line;
                    distros = tmp;
                }
            }
            reader.close();
            proc.waitFor();
            return distros;
        } catch (Exception e) {
            return new String[0];
        }
    }

    private VhdxEntry[] findVhdxFiles(String[] distros) {
        var entries = new VhdxEntry[0];
        var localApp = System.getenv("LOCALAPPDATA");
        if (localApp == null) return entries;

        // Modern WSL location
        var wslRoot = new File(localApp + "\\wsl");
        var allVhdx = new String[0];
        if (wslRoot.exists()) {
            allVhdx = collectVhdxFiles(wslRoot, 3, allVhdx);
        }

        // Legacy Packages location
        var packagesRoot = new File(localApp + "\\Packages");
        if (packagesRoot.exists()) {
            var pkgDirs = packagesRoot.listFiles();
            if (pkgDirs != null) {
                for (int d = 0; d < distros.length; d++) {
                    for (int p = 0; p < pkgDirs.length; p++) {
                        var name = pkgDirs[p].getName();
                        if (name.contains("CanonicalGroupLimited") && name.contains(distros[d])) {
                            var vhdx = new File(pkgDirs[p], "LocalState\\ext4.vhdx");
                            if (vhdx.exists() && vhdx.length() > 0) {
                                allVhdx = appendStr(allVhdx, vhdx.getAbsolutePath());
                            }
                        }
                    }
                }
            }
        }

        // Assign to distros
        int vIdx = 0;
        for (int d = 0; d < distros.length && vIdx < allVhdx.length; d++) {
            var entry = new VhdxEntry();
            entry.distro = distros[d];
            entry.path = allVhdx[vIdx];
            entry.sizeBytes = new File(allVhdx[vIdx]).length();
            entries = appendEntry(entries, entry);
            vIdx++;
        }

        return entries;
    }

    private String[] collectVhdxFiles(File dir, int maxDepth, String[] results) {
        if (maxDepth == 0) return results;
        var files = dir.listFiles();
        if (files == null) return results;
        for (int i = 0; i < files.length; i++) {
            if (files[i].isFile() && files[i].getName().equals("ext4.vhdx") && files[i].length() > 0) {
                results = appendStr(results, files[i].getAbsolutePath());
            } else if (files[i].isDirectory()) {
                results = collectVhdxFiles(files[i], maxDepth - 1, results);
            }
        }
        return results;
    }

    private boolean compactVhdx(String vhdxPath) {
        String tempPath = null;
        try {
            var scriptContent = "select vdisk file=\"" + vhdxPath + "\"\n"
                    + "attach vdisk readonly\ncompact vdisk\ndetach vdisk\nexit\n";

            tempPath = Path.of(System.getProperty("java.io.tmpdir"), "dc_compact.txt").toString();
            var writer = new FileWriter(tempPath);
            writer.write(scriptContent);
            writer.close();

            System.out.println("  Running diskpart (this may take several minutes)...");
            var proc = Runtime.getRuntime().exec(new String[]{"diskpart", "/s", tempPath});
            var reader = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            var sb = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) sb.append(line);
            reader.close();
            int exitCode = proc.waitFor();

            var output = sb.toString();
            return exitCode == 0 && !output.contains("error") && !output.contains("failed");
        } catch (Exception e) {
            return false;
        } finally {
            if (tempPath != null) new File(tempPath).delete();
        }
    }

    private long queryInnerUsage(String distro) {
        try {
            var proc = Runtime.getRuntime().exec(new String[]{
                "wsl", "-d", distro, "--", "bash", "-c",
                "df -B1 / 2>/dev/null | awk 'NR==2{print $3}'"
            });
            var reader = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            var line = reader.readLine();
            reader.close();
            proc.waitFor();
            if (line != null && !line.isBlank()) return Long.parseLong(line.trim());
        } catch (Exception ignored) {}
        return -1;
    }

    private boolean isAdmin() {
        try {
            var proc = Runtime.getRuntime().exec(new String[]{"net", "session"});
            int exitCode = proc.waitFor();
            return exitCode == 0;
        } catch (Exception e) {
            return false;
        }
    }

    private String[] appendStr(String[] arr, String item) {
        var result = new String[arr.length + 1];
        for (int i = 0; i < arr.length; i++) result[i] = arr[i];
        result[arr.length] = item;
        return result;
    }

    private VhdxEntry[] appendEntry(VhdxEntry[] arr, VhdxEntry item) {
        var result = new VhdxEntry[arr.length + 1];
        for (int i = 0; i < arr.length; i++) result[i] = arr[i];
        result[arr.length] = item;
        return result;
    }
}
