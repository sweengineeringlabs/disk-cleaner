package features;

import model.CleanerContext;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.IOException;

/** CompactWsl feature: compact WSL virtual disks to reclaim space. */
class CompactWsl {

    static void run(CleanerContext ctx, boolean dryRun) {
        System.out.println("disk-cleaner compact-wsl - WSL disk compaction");
        System.out.println();

        var os = System.getProperty("os.name").toLowerCase();
        if (!os.contains("win")) {
            System.err.println("Error: compact-wsl is only available on Windows.");
            return;
        }

        if (dryRun) {
            System.out.println("[DRY RUN] Would discover and compact WSL virtual disks.");
        }

        discoverWslDistros(dryRun);
    }

    private static void discoverWslDistros(boolean dryRun) {
        try {
            var proc = Runtime.getRuntime().exec(new String[]{"wsl", "--list", "--verbose"});
            var reader = new BufferedReader(new InputStreamReader(proc.getInputStream()));
            String line;
            boolean first = true;

            System.out.println("WSL distributions:");
            while ((line = reader.readLine()) != null) {
                if (first) { first = false; continue; } // skip header
                line = line.trim();
                if (!line.isEmpty()) {
                    System.out.println("  " + line);
                }
            }
            reader.close();
            proc.waitFor();

            if (dryRun) {
                System.out.println();
                System.out.println("[DRY RUN] Would compact VHDX files for each distribution.");
                System.out.println("Run without --dry-run from an elevated terminal to compact.");
            } else {
                System.out.println();
                System.out.println("[stub] VHDX compaction requires elevated privileges and diskpart.");
                System.out.println("Use PowerShell implementation for full WSL compaction.");
            }
        } catch (IOException e) {
            System.err.println("Error: could not run 'wsl --list': " + e.getMessage());
            System.err.println("Ensure WSL is installed.");
        } catch (InterruptedException e) {
            // cancelled
        }
    }
}
