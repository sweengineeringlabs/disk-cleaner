import config.TomlConfig;
import model.CleanerContext;
import model.CleanProfile;
import features.Clean;
import features.Search;
import features.Analyze;
import features.Monitor;
import features.CompactWsl;

/**
 * disk-cleaner — Multi-language build artifact cleaner.
 * Java implementation compiled with justc.
 */
class DiskCleaner {

    public static void main(String[] args) {
        var cli = parseArgs(args);

        var configPath = cli.config != null ? cli.config : "profiles.toml";
        var toml = TomlConfig.load(configPath);
        if (toml == null) {
            System.err.println("Error: could not load config: " + configPath);
            System.exit(1);
        }

        var searchPath = cli.path != null ? cli.path : toml.getValue("settings.default_path");
        if (searchPath.isEmpty()) {
            searchPath = System.getProperty("user.dir");
        }

        var lang = cli.lang;
        if (lang.length == 0) {
            lang = toml.getArray("settings.default_profiles");
        }

        var command = cli.command != null ? cli.command : "clean";

        if (command.equals("list-profiles")) {
            listProfiles(toml);
            return;
        }

        if (command.equals("help")) {
            showHelp();
            return;
        }

        var profileKeys = resolveProfiles(lang, toml);
        if (profileKeys == null) {
            System.exit(1);
        }

        var ctx = new CleanerContext(searchPath, cli.exclude, cli.include, cli.all, cli.jsonOutput);

        switch (command) {
            case "clean":
                Clean.run(ctx, profileKeys, toml, cli.dryRun, cli.parallel);
                break;
            case "search":
                Search.run(ctx, profileKeys, toml, cli.text);
                break;
            case "analyze":
                if (cli.diskUsage) {
                    Analyze.runDiskUsage(ctx, cli.depth);
                } else {
                    Analyze.run(ctx, profileKeys, toml, cli.benchmark);
                }
                break;
            case "monitor":
                Monitor.run(ctx, cli.history);
                break;
            case "compact-wsl":
                CompactWsl.run(ctx, cli.dryRun);
                break;
            default:
                System.err.println("Unknown command: " + command);
                showHelp();
                System.exit(1);
        }
    }

    static void listProfiles(TomlConfig toml) {
        System.out.println("Available profiles:");
        System.out.println();
        var keys = toml.profileKeys();
        for (int i = 0; i < keys.length; i++) {
            var profile = CleanProfile.fromToml(keys[i], toml);
            System.out.println("  " + keys[i] + " - " + profile.name);
            System.out.println("    marker: " + profile.marker + "  |  type: " + profile.profileType);
        }
        System.out.println();
    }

    static String[] resolveProfiles(String[] lang, TomlConfig toml) {
        var resolved = new String[0];

        for (int i = 0; i < lang.length; i++) {
            if (lang[i].equals("all")) {
                return toml.profileKeys();
            }
            var name = toml.getValue("profiles." + lang[i] + ".name");
            if (name.isEmpty()) {
                System.err.println("Unknown profile: " + lang[i]);
                System.err.println("Use list-profiles to see available profiles.");
                return null;
            }
            resolved = appendString(resolved, lang[i]);
        }

        if (resolved.length == 0) {
            System.err.println("No profiles selected. Use --lang or set default_profiles in config.");
            return null;
        }

        return resolved;
    }

    static String[] appendString(String[] arr, String item) {
        var result = new String[arr.length + 1];
        for (int i = 0; i < arr.length; i++) {
            result[i] = arr[i];
        }
        result[arr.length] = item;
        return result;
    }

    static void showHelp() {
        System.out.println("disk-cleaner - Multi-language build artifact cleaner (Java/justc)");
        System.out.println();
        System.out.println("USAGE: disk-cleaner <command> [OPTIONS]");
        System.out.println();
        System.out.println("COMMANDS:");
        System.out.println("  clean           Remove build artifacts (default)");
        System.out.println("  search          Find and report projects");
        System.out.println("  analyze         Report disk space consumption");
        System.out.println("  monitor         Show build processes and run history");
        System.out.println("  compact-wsl     Compact WSL virtual disks (Admin required)");
        System.out.println("  list-profiles   Show available language profiles");
        System.out.println("  help            Show this help message");
        System.out.println();
        System.out.println("OPTIONS:");
        System.out.println("  --lang <profile>   Language profile (repeatable, or 'all')");
        System.out.println("  --path <path>      Root path to search");
        System.out.println("  --config <file>    Path to TOML config");
        System.out.println("  --exclude <pat>    Exclude projects matching pattern");
        System.out.println("  --include <pat>    Include only matching projects");
        System.out.println("  --all              Process all projects, ignoring filters");
        System.out.println("  --json             Emit structured JSON lines");
        System.out.println("  --dry-run          Preview without modifying (clean/compact-wsl)");
        System.out.println("  --parallel         Run clean operations in parallel");
        System.out.println("  --text <pattern>   Search text in source files (search only)");
        System.out.println("  --disk-usage       Generic disk usage scan (analyze only)");
        System.out.println("  --depth <n>        Directory depth for disk-usage (default: 2)");
        System.out.println("  --benchmark        Benchmark build times (analyze only)");
        System.out.println("  --history          Show run history only (monitor only)");
    }

    static CliArgs parseArgs(String[] args) {
        var cli = new CliArgs();
        var langList = new String[0];
        var excludeList = new String[0];
        var includeList = new String[0];

        int i = 0;
        while (i < args.length) {
            var arg = args[i];
            switch (arg) {
                case "--lang": case "-l":
                    i++;
                    if (i < args.length) langList = appendString(langList, args[i]);
                    break;
                case "--path": case "-p":
                    i++;
                    if (i < args.length) cli.path = args[i];
                    break;
                case "--config": case "-c":
                    i++;
                    if (i < args.length) cli.config = args[i];
                    break;
                case "--exclude": case "-e":
                    i++;
                    if (i < args.length) excludeList = appendString(excludeList, args[i]);
                    break;
                case "--include": case "-i":
                    i++;
                    if (i < args.length) includeList = appendString(includeList, args[i]);
                    break;
                case "--all": case "-a":
                    cli.all = true;
                    break;
                case "--json": case "-j":
                    cli.jsonOutput = true;
                    break;
                case "--dry-run": case "-d":
                    cli.dryRun = true;
                    break;
                case "--parallel": case "-P":
                    cli.parallel = true;
                    break;
                case "--text": case "-t":
                    i++;
                    if (i < args.length) cli.text = args[i];
                    break;
                case "--disk-usage":
                    cli.diskUsage = true;
                    break;
                case "--depth":
                    i++;
                    if (i < args.length) cli.depth = Integer.parseInt(args[i]);
                    break;
                case "--benchmark":
                    cli.benchmark = true;
                    break;
                case "--history":
                    cli.history = true;
                    break;
                case "--help": case "-h":
                    cli.command = "help";
                    break;
                default:
                    if (!arg.startsWith("-") && cli.command == null) {
                        cli.command = arg;
                    }
                    break;
            }
            i++;
        }

        cli.lang = langList;
        cli.exclude = excludeList;
        cli.include = includeList;
        return cli;
    }
}

class CliArgs {
    String command;
    String[] lang = new String[0];
    String path;
    String config;
    String[] exclude = new String[0];
    String[] include = new String[0];
    boolean all;
    boolean jsonOutput;
    boolean dryRun;
    boolean parallel;
    String text;
    boolean diskUsage;
    int depth = 2;
    boolean benchmark;
    boolean history;
}
