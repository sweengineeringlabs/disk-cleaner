package features;

import model.CleanerContext;

/** Monitor feature: shows build processes and run history. */
class Monitor {

    private static final String[] BUILD_PROCESSES = {
            "cargo", "rustc", "node", "npm", "npx", "yarn", "pnpm", "bun",
            "javac", "java", "mvn", "mvnw", "gradle", "gradlew",
            "python", "python3", "pip", "pip3",
            "gcc", "g++", "clang", "clang++", "make", "cmake", "ninja",
            "dotnet", "msbuild", "go", "swift", "swiftc"
    };

    static void run(CleanerContext ctx, boolean historyOnly) {
        if (!historyOnly) {
            System.out.println("disk-cleaner monitor - Build process tracker");
            System.out.println();
            showBuildProcesses();
        }

        System.out.println();
        showRunHistory(ctx);
    }

    private static void showBuildProcesses() {
        System.out.println("Active build processes:");
        System.out.println("  (Process monitoring requires platform-specific APIs)");
        System.out.println("  Known build processes watched: " + String.join(", ", BUILD_PROCESSES));
        System.out.println();
        System.out.println("  [stub] Process monitoring not yet implemented in Java.");
        System.out.println("  Use PowerShell implementation for full process tracking.");
    }

    private static void showRunHistory(CleanerContext ctx) {
        System.out.println("Run history:");
        System.out.println("  [stub] History persistence not yet implemented in Java.");
        System.out.println("  Use PowerShell implementation for run history.");
    }
}
